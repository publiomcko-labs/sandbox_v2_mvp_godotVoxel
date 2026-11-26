#pragma once
#include "hydraulic_voxel_snapshot.hpp"
#include "core/hydraulic_domain.hpp"
#include "core/hydraulic_worker.hpp"
#include "content_registry/hydraulic_profile.hpp"
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace sandbox::hydraulic {
class Runtime {
    content::HydraulicProfile profile_;
    Domain domain_;
    tp::Worker worker_;
    std::map<core::Region,std::uint64_t> pending_,blocked_;
    std::uint64_t debt_=0,ticks_=0,visited_=0,moved_=0,publications_=0,max_tick_us_=0,max_snapshot_us_=0;
    static constexpr int side=16,base=-32,height=64;
    static core::Region key(core::Vec3 p) {
        return {static_cast<int>(std::floor(p.x/side))*side,base,static_cast<int>(std::floor(p.z/side))*side};
    }
    static bool resident(const godot::Ref<godot::VoxelTool>& tool,core::Region k) {
        return tool.is_valid()&&tool->is_area_editable(godot::AABB(godot::Vector3(k.x,k.y,k.z),godot::Vector3(side+1,height+1,side+1)));
    }
    static bool within_interest(core::Region k,core::Region center) {
        return std::abs(k.x-center.x)<=side&&std::abs(k.z-center.z)<=side;
    }
    void seed(const core::Region &k) {
        const auto &tile=domain_.tiles().at(k);
        for(const auto &rule:profile_.config.at("sources")) {
            const auto id=content::str(rule.at("id"));
            if(domain_.seeded().contains(id))continue;
            const auto &a=rule.at("anchor_m");
            core::Vec3 anchor{a[0].get<double>()+0.5,a[1].get<double>()+0.5,a[2].get<double>()+0.5};
            if(key(anchor)!=k)continue;
            const double level=rule.at("level_m").get<double>();
            // Explicit source tile only. Pick closest column whose air run
            // reaches the top of the bounded surface band and lies below head.
            // An isolated subterranean span is never a candidate.
            std::optional<core::Vec3> chosen;double best=std::numeric_limits<double>::infinity();
            for(const auto &col:tile.geometry->column_runs)for(const auto &s:col) {
                if(s.top!=height||base+s.bottom+0.1>=level)continue;
                core::Vec3 p{k.x+s.x+0.5,base+s.bottom+0.05,k.z+s.z+0.5};
                const double distance=(p.x-anchor.x)*(p.x-anchor.x)+(p.z-anchor.z)*(p.z-anchor.z);
                if(distance<best){best=distance;chosen=p;}
            }
            if(!chosen)continue;
            const auto slot=rule.at("slot").get<std::size_t>();
            if(rule.at("source_kind")=="fixed_head_ocean")
                domain_.add_ocean(id,*chosen,slot,level,4,true);
            else domain_.seed_finite(id,*chosen,slot,level,true);
        }
    }
public:
    explicit Runtime(content::HydraulicProfile profile):profile_(std::move(profile)),domain_(profile_.types){}
    Runtime(content::HydraulicProfile profile,Domain domain):profile_(std::move(profile)),domain_(std::move(domain)){}
    const auto &domain()const{return domain_;}
    const auto &profile()const{return profile_;}
    // Conservative initial edit policy: no construction in a wet tile;
    // no carving that could merge different liquids in the same tile.
    bool allows_edit(core::Vec3 center,double radius,bool add)const {
        if(!core::valid_point(center)||!std::isfinite(radius)||radius<0.5||radius>8)return false;
        const auto lo=key({center.x-radius-2,0,center.z-radius-2}),hi=key({center.x+radius+2,0,center.z+radius+2});
        for(int x=lo.x;x<=hi.x;x+=side)for(int z=lo.z;z<=hi.z;z+=side) {
            const core::Region k{x,base,z};
            auto it=domain_.tiles().find(k);if(it==domain_.tiles().end())continue;
            if(!it->second.available)return false;
            std::set<std::size_t> wet;
            for(const auto &[local,id]:it->second.ids) {
                (void)local;const auto &v=domain_.graph().volumes().at(id);if(v.litres)wet.insert(v.type);
            }
            if((add&&!wet.empty())||wet.size()>1)return false;
            if(add)for(const auto &[name,o]:domain_.oceans())if(o.tile==k){(void)name;return false;}
        }
        return true;
    }
    void edited(core::Vec3 center,double radius,std::uint64_t revision) {
        const auto lo=key({center.x-radius-2,0,center.z-radius-2}),hi=key({center.x+radius+2,0,center.z+radius+2});
        for(int x=lo.x;x<=hi.x;x+=side)for(int z=lo.z;z<=hi.z;z+=side) {
            const core::Region k{x,base,z};
            domain_.invalidate(k,revision);worker_.invalidate(k);pending_.erase(k);blocked_.erase(k);
        }
    }
    void frame(const godot::Ref<godot::VoxelTool>& tool,core::Vec3 position,std::uint64_t revision,std::uint64_t elapsed) {
        if(!core::valid_point(position))throw std::invalid_argument("hydraulic interest");
        const auto center=key(position);
        // Only the 3x3 near-field is active. No voxel streaming requests.
        for(const auto &[k,t]:domain_.tiles())if(t.available&&(!within_interest(k,center)||!resident(tool,k)))
            domain_.invalidate(k,t.geometry->revision);
        if(auto result=worker_.poll()) {
            const auto k=result->origin;pending_.erase(k);
            if(within_interest(k,center)&&resident(tool,k)) {
                if(domain_.publish(std::move(*result))){++publications_;seed(k);}
                else blocked_[k]=revision;
            }
        }
        // At most one immutable copy per frame. Prioritize nearest tiles.
        std::vector<core::Region> candidates;
        for(int x=-1;x<=1;++x)for(int z=-1;z<=1;++z)candidates.push_back({center.x+x*side,base,center.z+z*side});
        std::sort(candidates.begin(),candidates.end(),[&](auto a,auto b){
            const auto dist=[&](auto k){return std::abs(k.x-center.x)+std::abs(k.z-center.z);};return dist(a)<dist(b);
        });
        for(auto k:candidates) {
            const auto t=domain_.tiles().find(k);
            if(t!=domain_.tiles().end()&&t->second.available)continue;
            if(pending_.contains(k)||(blocked_.contains(k)&&blocked_.at(k)==revision))continue;
            if(domain_.tiles().size()>=256&&t==domain_.tiles().end())continue;
            const auto start=std::chrono::steady_clock::now();
            auto snapshot=copy_air_snapshot(tool,godot::Vector3i(k.x,k.y,k.z),godot::Vector3i(side,height,side),revision);
            const auto us=static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count());
            max_snapshot_us_=std::max(max_snapshot_us_,us);
            if(snapshot&&worker_.submit(std::move(*snapshot))){pending_[k]=revision;break;}
        }
        constexpr std::uint64_t period=50000000;
        debt_=std::min<std::uint64_t>(debt_+std::min<std::uint64_t>(elapsed,period*2),period*2);
        if(debt_>=period) {
            const auto start=std::chrono::steady_clock::now();
            const auto r=domain_.tick(128);++ticks_;visited_+=r.visited;moved_+=static_cast<std::uint64_t>(r.moved);
            debt_-=period;
            max_tick_us_=std::max(max_tick_us_,static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count()));
        }
    }
    godot::Dictionary at(core::Vec3 p)const {
        godot::Dictionary out;const auto wet=domain_.wet_at(p);if(!wet)return out;
        out["slot"]=static_cast<int64_t>(wet->type);out["density"]=domain_.graph().types().at(wet->type).density;return out;
    }
    godot::Array surfaces()const {
        godot::Array out;
        for(const auto &[k,t]:domain_.tiles())if(t.available)for(const auto &[local,id]:t.ids) {
            (void)k;(void)local;const auto &v=domain_.graph().volumes().at(id);
            if(!v.litres)continue;
            godot::Array row;row.push_back(static_cast<int64_t>(id));row.push_back(static_cast<int64_t>(v.type));row.push_back(v.level());out.push_back(row);
        }
        return out;
    }
    godot::Array mesh(Id id)const {
        using namespace godot;
        Array out;
        for(const auto &[k,t]:domain_.tiles())if(t.available)for(const auto &c:t.geometry->compartments) {
            if(t.ids.at(c.id)!=id)continue;
            PackedVector3Array vertices;PackedVector2Array uv;
            // Merge contiguous spans with equal ceiling on each scanline.
            // Surface Y is set by the node transform, not rebuilt per tick.
            std::map<std::pair<int,int>,std::vector<int>> rows;
            for(const auto &s:c.spans)rows[{s.z,s.top}].push_back(s.x);
            for(auto &[row,xs]:rows) {
                std::sort(xs.begin(),xs.end());
                for(std::size_t i=0;i<xs.size();) {
                    const int first=xs[i];int last=first+1;++i;
                    while(i<xs.size()&&xs[i]==last){++last;++i;}
                    const double x0=k.x+first,x1=k.x+last,z0=k.z+row.first,z1=z0+1;
                    for(auto v:{Vector3(x0,0,z0),Vector3(x1,0,z0),Vector3(x1,0,z1),
                                Vector3(x0,0,z0),Vector3(x1,0,z1),Vector3(x0,0,z1)}) {
                        vertices.push_back(v);uv.push_back(Vector2(0,k.y+row.second));
                    }
                }
            }
            out.push_back(vertices);out.push_back(uv);return out;
        }
        return out;
    }
    godot::Dictionary report()const {
        godot::Dictionary d;
        d["litres"]=domain_.graph().finite();d["initial"]=domain_.graph().initial();
        d["injected"]=domain_.graph().injected();d["drained"]=domain_.graph().drained();
        d["tiles"]=static_cast<int64_t>(domain_.tiles().size());d["volumes"]=static_cast<int64_t>(domain_.graph().volumes().size());
        d["portals"]=static_cast<int64_t>(domain_.graph().portals().size());d["sources"]=static_cast<int64_t>(domain_.seeded().size());
        d["ticks"]=static_cast<int64_t>(ticks_);d["visited"]=static_cast<int64_t>(visited_);d["moved"]=static_cast<int64_t>(moved_);
        d["publications"]=static_cast<int64_t>(publications_);d["blocked_tiles"]=static_cast<int64_t>(blocked_.size());
        d["max_tick_us"]=static_cast<int64_t>(max_tick_us_);d["max_snapshot_us"]=static_cast<int64_t>(max_snapshot_us_);
        return d;
    }
};
}
