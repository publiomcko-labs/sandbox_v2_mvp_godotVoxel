#pragma once
#include "hydraulic_domain.hpp"
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
struct Input {
    core::Region tile;
    std::shared_ptr<const tp::Result> geometry;
    std::vector<Wet> wet;
    bool same(const Input& o)const{return geometry==o.geometry&&wet==o.wet;}
};
struct Vertex {double x{},y{},z{},floor{},ceiling{};};
struct Batch {
    Input input;
    std::map<std::size_t,std::vector<Vertex>> materials;
    std::uint64_t build_us{};
    std::size_t fallback_columns{};
};
inline double sdf(const tp::Result& g,int x,int z,double h) {
    const double y=std::clamp((h-g.origin.y)/g.step,0.0,double(g.render_ny));
    const int lo=static_cast<int>(std::floor(y)),hi=std::min(lo+1,g.render_ny);
    const auto base=static_cast<std::size_t>((z*(g.nx+1)+x)*(g.render_ny+1));
    const double a=g.render_sdf.at(base+static_cast<std::size_t>(lo));
    const double b=g.render_sdf.at(base+static_cast<std::size_t>(hi));
    return a+(b-a)*(y-lo);
}
// Fixed world-space triangulation of authorized footprints. Interpolated
// SDF clips only WITHIN a wet interval, never claims an unclassified cell.
// Distinct Y layers remain independent. Both sides of a shared lattice
// edge use identical endpoints and interpolation at a common head.
inline Batch build(Input input) {
    const auto start=std::chrono::steady_clock::now();
    Batch out{std::move(input),{},0,0};
    const auto &g=*out.input.geometry;
    const bool has_sdf=g.render_ny>0&&g.render_sdf.size()==static_cast<std::size_t>((g.nx+1)*(g.nz+1)*(g.render_ny+1));
    std::map<Id,Wet> wet;
    for(const auto &w:out.input.wet)wet.emplace(w.local,w);
    for(const auto &column:g.column_runs)for(const auto &s:column) {
        const auto found=wet.find(s.compartment);if(found==wet.end())continue;
        const auto &w=found->second;
        const double floor=tp::span_floor_mm(g,s)*0.001,ceiling=g.origin.y+s.top*g.step;
        if(w.physical<=floor||w.physical>=ceiling-0.001)continue;
        // Never use a smoothed head that would move the free surface
        // outside the certified interval. Preserve genuine falls.
        const double h=w.visual>floor&&w.visual<ceiling-0.001?w.visual:w.physical;
        std::array<Vertex,4> p{};
        std::array<double,4> values{};
        constexpr std::array<std::pair<int,int>,4> corners{{{0,0},{1,0},{1,1},{0,1}}};
        for(std::size_t i=0;i<corners.size();++i) {
            const auto [dx,dz]=corners[i];
            const int x=s.x+dx,z=s.z+dz;
            p[i]={double(g.origin.x+x*g.step),h,double(g.origin.z+z*g.step),floor,ceiling};
            values[i]=has_sdf?sdf(g,x,z,h):1.0;
        }
        if(!has_sdf)++out.fallback_columns;
        auto &dst=out.materials[w.type];
        // Deterministic diagonal; clip individual triangles, not a
        // polygon across unrelated heads/ceilings or a dry island.
        for(const auto &tri:std::array<std::array<std::size_t,3>,2>{{{0,1,2},{0,2,3}}}) {
            std::vector<Vertex> poly;
            for(std::size_t j=0;j<3;++j) {
                auto a=tri[j],b=tri[(j+1)%3];
                const bool ia=values[a]>=0,ib=values[b]>=0;
                if(ia)poly.push_back(p[a]);
                if(ia!=ib) {
                    // Canonical endpoint order gives identical edge
                    // interpolation even when traversal is reversed.
                    if(std::tuple{p[b].x,p[b].z}<std::tuple{p[a].x,p[a].z})std::swap(a,b);
                    const double t=std::clamp(values[a]/(values[a]-values[b]),0.0,1.0);
                    const auto snap=[](double v){return std::round(v*1000000.0)/1000000.0;};
                    poly.push_back({snap(p[a].x+(p[b].x-p[a].x)*t),h,snap(p[a].z+(p[b].z-p[a].z)*t),floor,ceiling});
                }
            }
            for(std::size_t j=1;j+1<poly.size();++j) {
                const auto &a=poly[0],&b=poly[j],&c=poly[j+1];
                const double area=(b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x);
                if(area>1e-12)dst.insert(dst.end(),{a,b,c});
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
        Input in{k,t.geometry,{}};
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
    std::optional<std::future<std::vector<Batch>>> running_;
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
            for(int pass=0;pass<2&&jobs.size()<4;++pass)for(const auto &[k,in]:wanted) {
                auto old=presented_.find(k);
                const bool new_geometry=old==presented_.end()||old->second.geometry!=in.geometry;
                if((pass==0&&!new_geometry)||(pass==1&&new_geometry))continue;
                if(old!=presented_.end()&&old->second.same(in))continue;
                jobs.push_back(in);if(jobs.size()==4)break;
            }
            if(!jobs.empty())running_.emplace(std::async(std::launch::async,[items=std::move(jobs)]() mutable {
                std::vector<Batch> out;for(auto &in:items)out.push_back(build(std::move(in)));return out;
            }));
        }
        return done;
    }
    bool current(const Input& in)const {
        auto it=presented_.find(in.tile);return it!=presented_.end()&&it->second.same(in);
    }
};
}
