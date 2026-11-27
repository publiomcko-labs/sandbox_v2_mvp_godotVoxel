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
struct Input {
    core::Region tile;
    std::shared_ptr<const tp::Result> geometry;
    std::vector<Wet> wet;
    int exposed_top{};
    bool same(const Input& o)const{return geometry==o.geometry&&wet==o.wet;}
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
