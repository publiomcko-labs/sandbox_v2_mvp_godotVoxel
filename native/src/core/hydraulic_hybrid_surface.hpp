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
    bool layered=false;
    std::set<core::Region> adjacent_geometry{};
    bool same(const Input& o)const{return geometry==o.geometry&&exposed_top==o.exposed_top&&wet==o.wet&&cells==o.cells&&neighbors==o.neighbors&&layered==o.layered&&adjacent_geometry==o.adjacent_geometry;}
};
struct Vertex {double x{},y{},z{},floor{},ceiling{}; bool operator==(const Vertex&) const=default;};
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
    if(out.input.layered||!out.input.cells.empty()) {
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
        // Bank patches are disjoint footprints. Resolve each shared
        // vertex against the same wet component, including the second
        // wet halo column needed by the outer corners of bank cells.
        auto touches=[](const Cell& c,int x,int z){
            return x>=c.x&&x<=c.x+1&&z>=c.z&&z<=c.z+1;
        };
        auto bank_corner=[&](const Cell& donor,int x,int z){
            if(touches(donor,x,z))return corner(donor,x,z);
            std::vector<const Cell*> candidates;
            for(int a=x-2;a<=x+1;++a)for(int b=z-2;b<=z+1;++b){
                auto it=columns.find({a,b});if(it==columns.end())continue;
                for(auto c:it->second)if(c->type==donor.type&&c->ceiling_mm==donor.ceiling_mm)candidates.push_back(c);
            }
            std::vector<const Cell*> reach{&donor};
            for(std::size_t i=0;i<reach.size();++i)for(auto c:candidates)
                if(connected(*reach[i],*c)&&std::find(reach.begin(),reach.end(),c)==reach.end())reach.push_back(c);
            auto rank=[&](const Cell* c){
                return std::tuple{!touches(*c,x,z),std::abs(x-std::clamp(x,c->x,c->x+1))+std::abs(z-std::clamp(z,c->z,c->z+1)),c->x,c->z,c->floor_mm,c->ceiling_mm};
            };
            const auto *anchor=*std::min_element(reach.begin(),reach.end(),[&](auto a,auto b){return rank(a)<rank(b);});
            return corner(*anchor,std::clamp(x,anchor->x,anchor->x+1),std::clamp(z,anchor->z,anchor->z+1));
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
            // The known target owns its bank, including a dry tile
            // beside water. A donor owns only a certified halo target
            // for which no separate target mesh exists.
            if(!inside){
                core::Region target=g.origin;
                if(x<0)target.x-=g.nx;else if(x>=g.nx)target.x+=g.nx;
                if(z<0)target.z-=g.nz;else if(z>=g.nz)target.z+=g.nz;
                if(out.input.adjacent_geometry.contains(target))continue;
            }
            const Cell* donor=nullptr;int cap=exposed_ceiling;
            bool slice_only=false;
            for(int dz=-1;dz<=1;++dz)for(int dx=-1;dx<=1;++dx) {
                if(!dx&&!dz)continue;
                auto it=columns.find({wx+dx,wz+dz});if(it==columns.end())continue;
                for(auto c:it->second) {
                    if(c->ceiling_mm!=exposed_ceiling)continue;
                    const int coarse=static_cast<int>(std::ceil(c->floor_mm*0.001))*1000;
                    int candidate_cap=exposed_ceiling;bool open=false,head_open=false;
                    for(const auto &run:runs) {
                        const int low=(g.origin.y+run.bottom*g.step)*1000,high=(g.origin.y+run.top*g.step)*1000;
                        const int actual=inside?tp::span_floor_mm(g,run):low;
                        if(low<=coarse&&coarse<high)open=true;
                        if(low>coarse)candidate_cap=std::min(candidate_cap,low);
                        if(actual<=c->head*1000&&c->head*1000<high)head_open=true;
                    }
                    // Never extend across a certified open dry column.
                    if(head_open)continue;
                    const bool solid_bank=!open&&c->head<candidate_cap*0.001&&candidate_cap>coarse;
                    bool slice=false;
                    if(!solid_bank&&!g.render_sdf.empty()&&std::abs(dx)+std::abs(dz)==1){
                        std::array<double,4> q{};
                        for(std::size_t k=0;k<4;++k)q[k]=sdf_at(wx+offsets[k].first,wz+offsets[k].second,c->head);
                        const int e0=dx<0?0:dx>0?1:dz<0?0:3;
                        const int e1=dx<0?3:dx>0?2:dz<0?1:2;
                        // All positive corners must belong to the
                        // donor-connected component, not a diagonal cave.
                        bool reach[4]={};reach[e0]=q[e0]>0;reach[e1]=q[e1]>0;
                        for(int n=0;n<4;++n)for(int k=0;k<4;++k)
                            if(q[k]>0&&(reach[(k+1)%4]||reach[(k+3)%4]))reach[k]=true;
                        bool disconnected=false;for(int k=0;k<4;++k)if(q[k]>0&&!reach[k])disconnected=true;
                        slice=!disconnected&&std::max(q[e0],q[e1])>0&&*std::min_element(q.begin(),q.end())<0;
                        if(slice){
                            candidate_cap=exposed_ceiling;
                            for(const auto &run:runs){const int low=(g.origin.y+run.bottom*g.step)*1000;if(low>c->head*1000)candidate_cap=std::min(candidate_cap,low);}
                        }
                    }
                    if(!solid_bank&&!slice)continue;
                    if(!donor||std::tuple{slice,c->floor_mm,c->x,c->z}<std::tuple{slice_only,donor->floor_mm,donor->x,donor->z}){
                        donor=c;cap=candidate_cap;slice_only=slice;
                    }
                }
            }
            if(!donor)continue;
            if(!inside&&(donor->x<g.origin.x||donor->x>=g.origin.x+g.nx||donor->z<g.origin.z||donor->z>=g.origin.z+g.nz))continue;
            // Use the certified solid band as support, then let the
            // actual opaque terrain LOD clip it. Exact SDF contour clipping
            // at LOD0 is not equivalent to the rendered terrain boundary.
            std::array<Vertex,4> vertices;
            for(std::size_t k=0;k<4;++k){
                const auto [dx,dz]=offsets[k];const int xx=wx+dx,zz=wz+dz;
                const bool shared=xx>=donor->x&&xx<=donor->x+1&&zz>=donor->z&&zz<=donor->z+1;
                const double y=bank_corner(*donor,xx,zz);
                const double donor_floor=donor->floor_mm*0.001;
                double floor=floor_at(xx,zz,donor_floor)-1.35;
                if(shared)floor=std::min(floor,donor_floor-0.35);
                // No vertical offset along a shared edge: adjacent
                // triangles meet exactly, terrain depth clips the bank.
                vertices[k]={double(xx),y,double(zz),slice_only?std::min(floor,y-0.01):floor,cap*0.001};
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
// Dry target ownership is needed only within one column of an exposed
// donor. Covered layers cannot create bank aprons.
inline bool bank_has_donor(const Input& wet,const core::Region& target) {
    const auto &g=*wet.geometry;
    const int ceiling=(g.origin.y+wet.exposed_top)*1000;
    return std::any_of(wet.cells.begin(),wet.cells.end(),[&](const Cell& c){
        return c.ceiling_mm==ceiling&&c.x>=target.x-1&&c.x<=target.x+g.nx&&
            c.z>=target.z-1&&c.z<=target.z+g.nz;
    });
}
// Conservative dependency groups: all dirty tiles sharing a cardinal
// edge or corner in either accepted or requested ownership are atomic.
// Unchanged inputs need no rebuild; disjoint groups cannot share a halo.
inline std::map<core::Region,core::Region> dirty_groups(
    const std::vector<Input>& jobs,const std::map<core::Region,Input>& previous) {
    std::map<core::Region,std::set<core::Region>> links;
    for(const auto &in:jobs)links.try_emplace(in.tile);
    for(const auto &in:jobs) {
        auto connect=[&](const std::set<core::Region>& neighbors){
            for(const auto &q:neighbors)if(links.contains(q)){
                links.at(in.tile).insert(q);links.at(q).insert(in.tile);
            }
        };
        connect(in.adjacent_geometry);
        auto old=previous.find(in.tile);
        if(old!=previous.end())connect(old->second.adjacent_geometry);
    }
    std::map<core::Region,core::Region> groups;
    for(const auto &[k,neighbors]:links){
        (void)neighbors;
        if(groups.contains(k))continue;
        std::vector<core::Region> queue{k};groups.emplace(k,k);
        for(std::size_t i=0;i<queue.size();++i)
            for(const auto &q:links.at(queue[i]))if(groups.emplace(q,k).second)queue.push_back(q);
    }
    return groups;
}
class Renderer {
    std::map<core::Region,Input> presented_;
    // Exact accepted output cache; never cache a rejected revision as published.
    std::map<core::Region,std::map<std::size_t,std::vector<Vertex>>> published_meshes_;
    std::optional<core::Region> cursor_;
    std::optional<std::future<std::vector<Batch>>> running_;
    std::map<core::Region,core::Region> running_groups_;
    // The async task is sole writer; shared lifetime survives destruction.
    std::shared_ptr<std::map<core::Region,CachedTile>> cache_=std::make_shared<std::map<core::Region,CachedTile>>();
public:
    std::vector<Batch> poll(const std::map<core::Region,Input>& wanted) {
        std::vector<Batch> done;
        if(running_&&running_->wait_for(std::chrono::seconds(0))==std::future_status::ready) {
            auto results=running_->get();running_.reset();
            const bool coherent=!results.empty()&&results.front().input.layered;
            std::set<core::Region> rejected_groups;
            std::vector<Batch> accepted;
            for(auto &result:results) {
                const auto it=wanted.find(result.input.tile);
                auto reject=[&]{if(coherent)rejected_groups.insert(running_groups_.at(result.input.tile));};
                if(it==wanted.end()||it->second.geometry!=result.input.geometry){reject();continue;}
                // Drop obsolete wet membership, not merely the changing
                // head: a dry column cannot be resurrected by a worker.
                if(it->second.wet.size()!=result.input.wet.size()){reject();continue;}
                bool same_members=true;
                for(std::size_t i=0;i<it->second.wet.size();++i) {
                    const auto &a=it->second.wet[i],&b=result.input.wet[i];
                    if(a.id!=b.id||a.type!=b.type){same_members=false;break;}
                }
                if(!same_members){reject();continue;}
                auto membership=[](const Cell& a){return std::tuple{a.x,a.z,a.floor_mm,a.ceiling_mm,a.type};};
                std::set<std::tuple<int,int,int,int,std::size_t>> current;
                for(const auto &cell:it->second.cells)current.insert(membership(cell));
                for(const auto &cell:result.input.cells)if(!current.contains(membership(cell))){same_members=false;break;}
                if(!same_members){reject();continue;}
                if(coherent) {
                    // A stale dry donor in the halo can resurrect an apron
                    // even if all primary cells are still wet.
                    current.clear();
                    for(const auto &cell:it->second.neighbors)current.insert(membership(cell));
                    for(const auto &cell:result.input.neighbors)
                        if(!current.contains(membership(cell))){same_members=false;break;}
                    if(!same_members||it->second.adjacent_geometry!=result.input.adjacent_geometry){
                        reject();continue;
                    }
                }
                accepted.push_back(std::move(result));
            }
            for(auto &result:accepted){
                const auto k=result.input.tile;
                if(coherent&&rejected_groups.contains(running_groups_.at(k)))continue;
                presented_.insert_or_assign(k,result.input);
                // Empty bank tiles and quantized inputs may produce identical
                // geometry. Advance the accepted input but avoid Godot churn.
                auto old=published_meshes_.find(k);
                if(coherent&&old!=published_meshes_.end()&&old->second==result.materials)continue;
                if(coherent)published_meshes_.insert_or_assign(k,result.materials);
                done.push_back(std::move(result));
            }
            running_groups_.clear();
        }
        for(auto it=presented_.begin();it!=presented_.end();) {
            if(!wanted.contains(it->first)){published_meshes_.erase(it->first);it=presented_.erase(it);}else ++it;
        }
        if(!running_) {
            std::vector<Input> jobs;
            // First missing/revised tiles, then changed heads.
            std::vector<core::Region> order;
            auto first=cursor_?wanted.upper_bound(*cursor_):wanted.begin();
            for(auto it=first;it!=wanted.end();++it)order.push_back(it->first);
            for(auto it=wanted.begin();it!=first;++it)order.push_back(it->first);
            const bool layered=!wanted.empty()&&wanted.begin()->second.layered;
            // The integrated model bounds known tiles; never split a dirty
            // dependency group at an arbitrary batch-size threshold.
            const std::size_t limit=layered?wanted.size():4;
            for(int pass=0;pass<2&&jobs.size()<limit;++pass)for(const auto &k:order) {
                const auto &in=wanted.at(k);
                auto old=presented_.find(k);
                const bool new_geometry=old==presented_.end()||old->second.geometry!=in.geometry;
                if((pass==0&&!new_geometry)||(pass==1&&new_geometry))continue;
                if(old!=presented_.end()&&old->second.same(in))continue;
                jobs.push_back(in);cursor_=k;if(jobs.size()==limit)break;
            }
            // No concurrent task owns the cache here. Evict tiles no
            // longer in the presentation working set, including dry tiles.
            for(auto it=cache_->begin();it!=cache_->end();) {
                if(!wanted.contains(it->first))it=cache_->erase(it);else ++it;
            }
            if(layered)running_groups_=dirty_groups(jobs,presented_);
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
