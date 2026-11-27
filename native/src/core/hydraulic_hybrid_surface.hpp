#pragma once
#include "hydraulic_domain.hpp"
#include "hydraulic_surface.hpp"
#include <future>
#include <chrono>
#include <memory>
namespace sandbox::hydraulic::hybrid {
// Experimental renderer input: immutable terrain revision + read-only
// wet state. Material batches own disjoint footprints; no new physics.
struct Wet {
    Id local{},id{};
    std::size_t type{};
    double physical{},visual{};
    auto operator<=>(const Wet&) const=default;
};
// Independent variable-head surface samples. Vertices are shared at
// certified wet edges; the worker sees no mutable solver object.
struct Cell {
    int x{},z{},floor_mm{},ceiling_mm{};
    std::size_t type{};
    double head{};
    std::array<double,4> corners{};
    auto operator<=>(const Cell&)const=default;
};
struct Input {
    core::Region tile;
    std::shared_ptr<const tp::Result> geometry;
    std::vector<Wet> wet;
    int exposed_top{};
    std::vector<Cell> cells{},neighbors{};
    bool same(const Input& o)const{return geometry==o.geometry&&wet==o.wet&&cells==o.cells&&neighbors==o.neighbors;}
};
struct Vertex {double x{},y{},z{},floor{},ceiling{};};
struct Batch {
    Input input;
    std::map<std::size_t,std::vector<Vertex>> materials;
    std::uint64_t build_us{};
    std::size_t fallback_columns{};
};
// B2 control: reuse the certified H14 geometric support and terrain depth
// intersection rather than erode the water to fully open cells. Build
// one material batch per render tile; never weld distinct heads/layers.
// Static support is cached by immutable geometry identity on the worker.
struct CachedTile {
    std::shared_ptr<const tp::Result> geometry;
    int exposed_top{};
    std::map<Id,std::vector<surface::Patch>> patches;
};
inline Batch build(Input input,CachedTile* cached=nullptr) {
    const auto start=std::chrono::steady_clock::now();
    Batch out{std::move(input),{},0,0};
    const auto &g=*out.input.geometry;
    if(!out.input.cells.empty()) {
        constexpr std::array<std::pair<int,int>,4> offsets{{{0,0},{1,0},{1,1},{0,1}}};
        std::map<std::pair<int,int>,std::vector<const Cell*>> columns;
        for(const auto &c:out.input.cells)columns[{c.x,c.z}].push_back(&c);
        for(const auto &c:out.input.neighbors)columns[{c.x,c.z}].push_back(&c);
        auto connected=[](const Cell& a,const Cell& b) {
            return a.type==b.type&&std::abs(a.x-b.x)+std::abs(a.z-b.z)==1&&
                std::min(a.head,b.head)>std::max(a.floor_mm,b.floor_mm)*0.001&&
                std::max(a.head,b.head)<std::min(a.ceiling_mm,b.ceiling_mm)*0.001-0.001;
        };
        // Canonical connected component at each world-space corner. A
        // cell on the opposite tile boundary computes identical values.
        auto corner=[&](const Cell& cell,int x,int z) {
            std::vector<const Cell*> candidates;
            for(int a=x-1;a<=x;++a)for(int b=z-1;b<=z;++b) {
                auto it=columns.find({a,b});if(it==columns.end())continue;
                for(auto c:it->second)if(c->type==cell.type)candidates.push_back(c);
            }
            std::sort(candidates.begin(),candidates.end(),[](const auto *a,const auto *b){
                return std::tie(a->x,a->z,a->floor_mm,a->ceiling_mm)<std::tie(b->x,b->z,b->floor_mm,b->ceiling_mm);
            });
            std::set<std::size_t> members;
            for(std::size_t i=0;i<candidates.size();++i)if(candidates[i]==&cell)members.insert(i);
            bool changed=true;
            while(changed){changed=false;for(std::size_t i=0;i<candidates.size();++i)if(!members.contains(i))for(auto j:members)
                if(connected(*candidates[i],*candidates[j])){members.insert(i);changed=true;break;}}
            double sum=0,lo=-1e9,hi=1e9;
            for(auto i:members){const auto &c=*candidates[i];sum+=c.head;lo=std::max(lo,c.floor_mm*0.001+0.0001);hi=std::min(hi,c.ceiling_mm*0.001-0.002);}
            return members.empty()||lo>hi?cell.head:std::clamp(sum/double(members.size()),lo,hi);
        };
        auto floor_at=[&](int x,int z,double fallback) {
            const int lx=x-g.origin.x,lz=z-g.origin.z;
            if(!g.halo_floor.empty()&&lx>=-1&&lx<=g.nx+1&&lz>=-1&&lz<=g.nz+1)
                return double(g.halo_floor.at(static_cast<std::size_t>((lz+1)*(g.nx+3)+lx+1)));
            if(!g.surface_floor.empty()&&lx>=0&&lx<=g.nx&&lz>=0&&lz<=g.nz)
                return double(g.surface_floor.at(static_cast<std::size_t>(lz*(g.nx+1)+lx)));
            return fallback;
        };
        const int exposed_ceiling=(g.origin.y+out.input.exposed_top)*1000;
        for(const auto &cell:out.input.cells) {
            std::array<Vertex,4> vertices;
            for(std::size_t j=0;j<4;++j) {
                const auto [dx,dz]=offsets[j];
                const double floor=cell.floor_mm*0.001,ceiling=cell.ceiling_mm*0.001;
                const int x=cell.x+dx,z=cell.z+dz;
                const double clip=cell.ceiling_mm==exposed_ceiling?std::min(floor_at(x,z,floor)-1.35,floor-0.35):floor-0.35;
                vertices[j]={double(x),corner(cell,x,z),double(z),clip,ceiling};
            }
            auto &v=out.materials[cell.type];
            v.insert(v.end(),{vertices[0],vertices[1],vertices[2],vertices[0],vertices[2],vertices[3]});
        }
        // SDF slice at the actual free-surface head, not the highest
        // solid-to-air crossing (which may be an unrelated cave roof).
        auto sdf_at=[&](int x,int z,double y) {
            const int p=g.render_pad,w=g.nx+1+2*p;
            const int lx=x-g.origin.x+p,lz=z-g.origin.z+p;
            const double ly=(y-g.origin.y)/g.step;
            if(lx<0||lx>=w||lz<0||lz>=g.nz+1+2*p||ly<0||ly>g.render_ny)return -4.0;
            const int a=static_cast<int>(std::floor(ly)),b=std::min(a+1,g.render_ny);
            const auto idx=static_cast<std::size_t>((lz*w+lx)*(g.render_ny+1));
            return (g.render_sdf[idx+a]*(1-(ly-a))+g.render_sdf[idx+b]*(ly-a))/1024.0;
        };
        // A single canonical donor per known bank column, and only
        // below its first certified higher air interval. This restores
        // the H14 partial-cell shoreline without flooding dry passages.
        const int pad=g.halo_runs.empty()?0:1;
        if(!g.surface_floor.empty())for(int z=-pad;z<g.nz+pad;++z)for(int x=-pad;x<g.nx+pad;++x) {
            const int wx=g.origin.x+x,wz=g.origin.z+z;
            const bool inside=x>=0&&x<g.nx&&z>=0&&z<g.nz;
            const auto &runs=inside?g.column_runs.at(static_cast<std::size_t>(z*g.nx+x)):
                g.halo_runs.at(static_cast<std::size_t>((z+1)*(g.nx+2)+x+1));
            if(!g.render_sdf.empty()) {
                // Only partially obstructed cells. No extension into
                // a certified dry interval or a fully open dry column.
                const Cell* selected=nullptr;
                std::array<double,4> field{};
                std::array<bool,2> keep{};
                constexpr int tris[2][3]={{0,1,2},{0,2,3}};
                for(auto d:{std::pair{-1,0},std::pair{1,0},std::pair{0,-1},std::pair{0,1}}) {
                    auto it=columns.find({wx+d.first,wz+d.second});if(it==columns.end())continue;
                    for(auto c:it->second) {
                        if(c->ceiling_mm!=exposed_ceiling)continue;
                        bool dry_open=false;
                        for(const auto &run:runs) {
                            const double lo=inside?tp::span_floor_mm(g,run)*0.001:double(g.origin.y+run.bottom*g.step);
                            if(lo<=c->head&&c->head<g.origin.y+run.top*g.step){dry_open=true;break;}
                        }
                        if(dry_open)continue;
                        std::array<double,4> q{};
                        for(std::size_t j=0;j<4;++j)q[j]=sdf_at(wx+offsets[j].first,wz+offsets[j].second,c->head);
                        if(*std::min_element(q.begin(),q.end())>=0||*std::max_element(q.begin(),q.end())<=0)continue;
                        const int e0=d.first<0?0:d.first>0?1:d.second<0?0:3;
                        const int e1=d.first<0?3:d.first>0?2:d.second<0?1:2;
                        if(std::max(q[e0],q[e1])<=0)continue;
                        std::array<bool,2> k{};
                        for(int n=0;n<2;++n){
                            bool a=false,b=false;for(int j:tris[n]){a|=j==e0;b|=j==e1;}
                            k[n]=a&&b;
                        }
                        if(std::max(q[0],q[2])>0&&(k[0]||k[1]))k={true,true};
                        if(!selected||std::tie(c->floor_mm,c->x,c->z)<std::tie(selected->floor_mm,selected->x,selected->z)){
                            selected=c;field=q;keep=k;
                        }
                    }
                }
                if(!selected||selected->x<g.origin.x||selected->x>=g.origin.x+g.nx||selected->z<g.origin.z||selected->z>=g.origin.z+g.nz)continue;
                std::array<Vertex,4> verts;
                for(std::size_t j=0;j<4;++j) {
                    const auto [dx,dz]=offsets[j];
                    const int xx=wx+dx,zz=wz+dz;
                    const bool shared=xx>=selected->x&&xx<=selected->x+1&&zz>=selected->z&&zz<=selected->z+1;
                    const double yy=shared?corner(*selected,xx,zz):selected->head;
                    verts[j]={double(xx),yy-0.003,double(zz),std::min(yy-0.01,floor_at(xx,zz,selected->floor_mm*0.001)-1.35),selected->ceiling_mm*0.001};
                }
                auto &dst=out.materials[selected->type];
                for(int n=0;n<2;++n)if(keep[n]) {
                    std::vector<Vertex> poly;
                    for(int j=0;j<3;++j) {
                        const int a=tris[n][j],b=tris[n][(j+1)%3];
                        if(field[a]>=0)poly.push_back(verts[a]);
                        if((field[a]>=0)!=(field[b]>=0)) {
                            const double t=field[a]/(field[a]-field[b]);
                            auto mix=[&](double u,double v){return u+(v-u)*t;};
                            const auto &u=verts[a],&v=verts[b];
                            poly.push_back({mix(u.x,v.x),mix(u.y,v.y),mix(u.z,v.z),mix(u.floor,v.floor),u.ceiling});
                        }
                    }
                    for(std::size_t j=1;j+1<poly.size();++j)dst.insert(dst.end(),{poly[0],poly[j],poly[j+1]});
                }
                continue;
            }
            const Cell* donor=nullptr;int cap=exposed_ceiling;
            for(int dx=-1;dx<=1;++dx)for(int dz=-1;dz<=1;++dz) {
                if(!dx&&!dz)continue;
                auto it=columns.find({wx+dx,wz+dz});if(it==columns.end())continue;
                for(auto c:it->second) {
                    if(c->ceiling_mm!=exposed_ceiling)continue;
                    int candidate_cap=exposed_ceiling;bool open=false;
                    for(const auto &s:runs) {
                        const int low=(g.origin.y+s.bottom)*1000,high=(g.origin.y+s.top)*1000;
                        if(low<=c->floor_mm&&c->floor_mm<high){open=true;break;}
                        if(low>c->floor_mm)candidate_cap=std::min(candidate_cap,low);
                    }
                    if(open||c->head>=candidate_cap*0.001||candidate_cap<=c->floor_mm)continue;
                    if(!donor||std::tie(c->floor_mm,c->x,c->z)<std::tie(donor->floor_mm,donor->x,donor->z)){
                        donor=c;cap=candidate_cap;
                    }
                }
            }
            if(!donor)continue;
            // Only the tile owning the donor may emit this apron, even
            // across a tile edge. Unknown terrain never gets an apron.
            if(donor->x<g.origin.x||donor->x>=g.origin.x+g.nx||donor->z<g.origin.z||donor->z>=g.origin.z+g.nz)continue;
            std::array<Vertex,4> vertices;
            for(std::size_t j=0;j<4;++j){
                const auto [dx,dz]=offsets[j];
                vertices[j]={double(wx+dx),donor->head-0.003,double(wz+dz),
                    floor_at(wx+dx,wz+dz,donor->floor_mm*0.001)-1.35,cap*0.001};
            }
            auto &v=out.materials[donor->type];v.insert(v.end(),{vertices[0],vertices[1],vertices[2],vertices[0],vertices[2],vertices[3]});
        }
        out.build_us=static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count());
        return out;
    }
    CachedTile temporary;
    auto &cache=cached?*cached:temporary;
    if(cache.geometry!=out.input.geometry||cache.exposed_top!=out.input.exposed_top) {
        cache={out.input.geometry,out.input.exposed_top,{}};
    }
    std::map<Id,Wet> wet;
    for(const auto &w:out.input.wet)wet.emplace(w.local,w);
    for(const auto &c:g.compartments) {
        const auto found=wet.find(c.id);if(found==wet.end())continue;
        const auto &w=found->second;
        const bool exposed=std::any_of(c.spans.begin(),c.spans.end(),[&](const auto &span){return span.top==out.input.exposed_top;});
        if(!cache.patches.contains(c.id))cache.patches.emplace(c.id,surface::build(g,c,out.input.exposed_top));
        auto &dst=out.materials[w.type];
        for(const auto &patch:cache.patches.at(c.id)) {
            for(std::size_t i=0;i+2<patch.vertices.size();i+=3) {
                std::array<Vertex,3> tri{};
                bool below=true,above=true;
                for(std::size_t j=0;j<3;++j) {
                    const auto &p=patch.vertices[i+j];
                    // Exact H14 attributes, including bounded bank overlap
                    // and roof cap. All vertices are in world coordinates.
                    const double y=w.visual+p.offset;
                    const double floor=p.floor-(exposed?1.35:0.35);
                    tri[j]={g.origin.x+p.x*g.step,y,g.origin.z+p.z*g.step,floor,double(patch.ceiling)};
                    below=below&&y<floor-0.0001;
                    above=above&&y>double(patch.ceiling)+0.0001;
                }
                // Discard only triangles guaranteed invisible under the
                // existing shader; leave mixed triangles to its exact clip.
                if(!below&&!above)dst.insert(dst.end(),tri.begin(),tri.end());
            }
        }
    }
    out.build_us=static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count());
    return out;
}
inline std::map<core::Region,Input> snapshot(const Domain& domain,int exposed_top) {
    std::set<Id> exposed;
    const auto &graph=domain.graph();
    for(const auto &[k,t]:domain.tiles())if(t.renderable()) {
        (void)k;
        for(const auto &c:t.geometry->compartments) {
            const auto id=t.ids.at(c.id);
            if(graph.volumes().at(id).litres&&std::any_of(c.spans.begin(),c.spans.end(),[&](const auto &s){return s.top==exposed_top;}))exposed.insert(id);
        }
    }
    const auto heads=graph.presentation_heads(exposed,0.15,true);
    std::map<core::Region,Input> inputs;
    for(const auto &[k,t]:domain.tiles())if(t.renderable()) {
        Input in{k,t.geometry,{},exposed_top};
        for(const auto &[local,id]:t.ids) {
            const auto &v=graph.volumes().at(id);if(!v.litres)continue;
            // Head signature at 1mm; retain exact physical head at
            // shallow/dry transitions instead of quantizing away water.
            const double h=v.level(),visual=heads.contains(id)?heads.at(id):h;
            in.wet.push_back({local,id,v.type,h,visual});
        }
        if(!in.wet.empty())inputs.emplace(k,std::move(in));
    }
    return inputs;
}
// Bounded read-only background work. A result from an older terrain
// geometry is never published, even if it finished after an edit.
class Renderer {
    std::map<core::Region,Input> presented_;
    std::optional<core::Region> cursor_;
    std::optional<std::future<std::vector<Batch>>> running_;
    // The async task is sole writer; shared lifetime survives destruction.
    std::shared_ptr<std::map<core::Region,CachedTile>> cache_=std::make_shared<std::map<core::Region,CachedTile>>();
public:
    std::vector<Batch> poll(const std::map<core::Region,Input>& wanted) {
        std::vector<Batch> done;
        if(running_&&running_->wait_for(std::chrono::seconds(0))==std::future_status::ready) {
            auto results=running_->get();running_.reset();
            for(auto &result:results) {
                const auto it=wanted.find(result.input.tile);
                if(it==wanted.end()||it->second.geometry!=result.input.geometry)continue;
                // Drop obsolete wet membership, not merely the changing
                // head: a dry column cannot be resurrected by a worker.
                if(it->second.wet.size()!=result.input.wet.size())continue;
                bool same_members=true;
                for(std::size_t i=0;i<it->second.wet.size();++i) {
                    const auto &a=it->second.wet[i],&b=result.input.wet[i];
                    if(a.id!=b.id||a.type!=b.type){same_members=false;break;}
                }
                if(!same_members)continue;
                auto membership=[](const Cell& a){return std::tuple{a.x,a.z,a.floor_mm,a.ceiling_mm,a.type};};
                std::set<std::tuple<int,int,int,int,std::size_t>> current;
                for(const auto &cell:it->second.cells)current.insert(membership(cell));
                for(const auto &cell:result.input.cells)if(!current.contains(membership(cell))){same_members=false;break;}
                if(!same_members)continue;
                presented_.insert_or_assign(result.input.tile,result.input);
                done.push_back(std::move(result));
            }
        }
        for(auto it=presented_.begin();it!=presented_.end();) {
            if(!wanted.contains(it->first))it=presented_.erase(it);else ++it;
        }
        if(!running_) {
            std::vector<Input> jobs;
            // First missing/revised tiles, then changed heads.
            std::vector<core::Region> order;
            auto first=cursor_?wanted.upper_bound(*cursor_):wanted.begin();
            for(auto it=first;it!=wanted.end();++it)order.push_back(it->first);
            for(auto it=wanted.begin();it!=first;++it)order.push_back(it->first);
            for(int pass=0;pass<2&&jobs.size()<4;++pass)for(const auto &k:order) {
                const auto &in=wanted.at(k);
                auto old=presented_.find(k);
                const bool new_geometry=old==presented_.end()||old->second.geometry!=in.geometry;
                if((pass==0&&!new_geometry)||(pass==1&&new_geometry))continue;
                if(old!=presented_.end()&&old->second.same(in))continue;
                jobs.push_back(in);cursor_=k;if(jobs.size()==4)break;
            }
            // No concurrent task owns the cache here. Evict tiles no
            // longer in the presentation working set, including dry tiles.
            for(auto it=cache_->begin();it!=cache_->end();) {
                if(!wanted.contains(it->first))it=cache_->erase(it);else ++it;
            }
            if(!jobs.empty())running_.emplace(std::async(std::launch::async,[items=std::move(jobs),cache=cache_]() mutable {
                std::vector<Batch> out;
                for(auto &in:items) {
                    const auto k=in.tile;
                    out.push_back(build(std::move(in),&(*cache)[k]));
                }
                return out;
            }));
        }
        return done;
    }
    bool current(const Input& in)const {
        auto it=presented_.find(in.tile);return it!=presented_.end()&&it->second.same(in);
    }
};
}
