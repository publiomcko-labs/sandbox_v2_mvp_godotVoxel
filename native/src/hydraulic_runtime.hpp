#pragma once
#include "hydraulic_voxel_snapshot.hpp"
#include "core/hydraulic_domain.hpp"
#include "core/hydraulic_worker.hpp"
#include "core/hydraulic_surface.hpp"
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
    std::set<core::Region> edited_tiles_;
    std::map<Id,std::pair<Transfer,std::uint64_t>> recent_flows_;
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
    bool wet_tile(const Tile &t)const {
        for(const auto &[local,id]:t.ids) {
            (void)local;if(domain_.graph().volumes().at(id).litres)return true;
        }
        return false;
    }
    bool visual_tile(core::Region k,const Tile &t)const {
        return t.renderable()||edited_tiles_.contains(k);
    }
    bool hydraulic_interest(core::Region k,core::Region center)const {
        if(edited_tiles_.contains(k))return true;
        if(within_interest(k,center))return true;
        // Retain and expand around known wet bodies while their geometry
        // is editable. Simulation interest no longer follows only player.
        if(std::abs(k.x-center.x)>192||std::abs(k.z-center.z)>192)return false;
        constexpr std::array<core::Region,5> offsets{{{0,0,0},{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}}};
        for(auto d:offsets) {
            auto it=domain_.tiles().find({k.x+d.x*side,base,k.z+d.z*side});
            if(it!=domain_.tiles().end()&&wet_tile(it->second))return true;
        }
        return false;
    }
    std::map<Id,godot::PackedVector3Array> visible_flows()const {
        using namespace godot;
        std::map<Id,PackedVector3Array> out;
        const auto &graph=domain_.graph();
        std::vector<Transfer> candidates;
        for(const auto &[id,entry]:recent_flows_) {
            const auto &f=entry.first;
            auto p=graph.portals().find(id);
            if(p==graph.portals().end()||!p->second.available||p->second.opening_height_m<=0)continue;
            const auto &a=graph.volumes().at(f.from),&b=graph.volumes().at(f.to);
            if(a.ocean||b.ocean||!a.litres||a.level()-b.level()<0.08||
                a.level()<=p->second.sill_m)continue;
            candidates.push_back(f);
        }
        std::sort(candidates.begin(),candidates.end(),[](const auto &a,const auto &b){
            return a.litres!=b.litres?a.litres>b.litres:a.portal<b.portal;
        });
        if(candidates.size()>16)candidates.resize(16);
        if(candidates.empty())return out;
        std::set<Id> wanted;
        for(const auto &f:candidates){wanted.insert(f.from);wanted.insert(f.to);}
        std::map<Id,std::pair<const Tile*,Id>> locations;
        for(const auto &[k,t]:domain_.tiles())if(t.available) {
            (void)k;
            for(const auto &[local,id]:t.ids)if(wanted.contains(id))locations.emplace(id,std::pair{&t,local});
        }
        std::size_t remaining=64;
        for(const auto &f:candidates) {
            if(!remaining)break;
            if(!locations.contains(f.from)||!locations.contains(f.to))continue;
            const auto &p=graph.portals().at(f.portal);
            const auto &a=graph.volumes().at(f.from),&b=graph.volumes().at(f.to);
            const auto [ta,la]=locations.at(f.from);
            const auto [tb,lb]=locations.at(f.to);
            const auto faces=surface::flow_faces(*ta->geometry,la,*tb->geometry,lb,
                static_cast<int>(std::lround(p.sill_m*1000)),
                static_cast<int>(std::lround((p.sill_m+p.opening_height_m)*1000)),
                base+height,a.level(),b.level(),remaining);
            for(const auto &q:faces) {
                auto &vertices=out[f.from];
                const Vector3 a0(q.x0,q.bottom,q.z0),a1(q.x0,q.top,q.z0),
                    b0(q.x1,q.bottom,q.z1),b1(q.x1,q.top,q.z1);
                for(const auto &v:{a0,a1,b1,a0,b1,b0})vertices.push_back(v);
                --remaining;
            }
        }
        return out;
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
            if(domain_.tiles().contains(k))edited_tiles_.insert(k);
            domain_.invalidate(k,revision);worker_.invalidate(k);pending_.erase(k);blocked_.erase(k);
        }
    }
    void frame(const godot::Ref<godot::VoxelTool>& tool,core::Vec3 position,std::uint64_t revision,std::uint64_t elapsed) {
        if(!core::valid_point(position))throw std::invalid_argument("hydraulic interest");
        const auto center=key(position);
        // Only the 3x3 near-field is active. No voxel streaming requests.
        for(const auto &[k,t]:domain_.tiles())if(t.available&&(!hydraulic_interest(k,center)||!resident(tool,k)))
            domain_.invalidate(k,t.geometry->revision);
        if(auto result=worker_.poll()) {
            const auto k=result->origin;pending_.erase(k);
            if(hydraulic_interest(k,center)&&resident(tool,k)) {
                if(domain_.publish(std::move(*result))){edited_tiles_.erase(k);++publications_;seed(k);}
                else blocked_[k]=revision;
            }
        }
        // At most one immutable copy per frame. Prioritize nearest tiles.
        std::vector<core::Region> candidates(edited_tiles_.begin(),edited_tiles_.end());
        for(const auto &[k,t]:domain_.tiles())if(wet_tile(t)) {
            for(auto offset:{core::Region{0,0,0},core::Region{-1,0,0},core::Region{1,0,0},core::Region{0,0,-1},core::Region{0,0,1}}) {
                const core::Region q{k.x+offset.x*side,base,k.z+offset.z*side};
                if(hydraulic_interest(q,center))candidates.push_back(q);
            }
        }
        for(int x=-1;x<=1;++x)for(int z=-1;z<=1;++z)candidates.push_back({center.x+x*side,base,center.z+z*side});
        std::sort(candidates.begin(),candidates.end());
        candidates.erase(std::unique(candidates.begin(),candidates.end()),candidates.end());
        std::sort(candidates.begin(),candidates.end(),[&](auto a,auto b){
            if(edited_tiles_.contains(a)!=edited_tiles_.contains(b))return edited_tiles_.contains(a);
            const auto dist=[&](auto k){return std::abs(k.x-center.x)+std::abs(k.z-center.z);};return dist(a)<dist(b);
        });
        for(auto k:candidates) {
            const auto t=domain_.tiles().find(k);
            if(t!=domain_.tiles().end()&&t->second.available)continue;
            if(pending_.contains(k)||(blocked_.contains(k)&&blocked_.at(k)==revision))continue;
            if(domain_.tiles().size()>=256&&t==domain_.tiles().end())continue;
            if(!resident(tool,k))continue;
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
            // Retain a short presentation history to avoid flicker from the
            // bounded portal scheduler. Stale/inactive portals are rejected
            // again against current geometry and head before drawing.
            for(auto it=recent_flows_.begin();it!=recent_flows_.end();) {
                if(ticks_-it->second.second>=4)it=recent_flows_.erase(it);else ++it;
            }
            for(const auto &f:r.flows)recent_flows_.insert_or_assign(f.portal,std::pair{f,ticks_});
            debt_-=period;
            max_tick_us_=std::max(max_tick_us_,static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count()));
        }
    }
    godot::Dictionary at(core::Vec3 p)const {
        godot::Dictionary out;const auto wet=domain_.wet_at(p);if(!wet)return out;
        out["slot"]=static_cast<int64_t>(wet->type);out["density"]=domain_.graph().types().at(wet->type).density;
        const auto &v=domain_.graph().volumes().at(*domain_.volume_at(p));
        const auto &g=*domain_.tiles().at(key(p)).geometry;
        const auto *span=tp::span_at(g,p);
        out["level"]=v.level();
        out["floor"]=span?double(g.origin.y+span->bottom*g.step):v.curve.knots().front().mm*0.001;
        out["id"]=static_cast<int64_t>(v.id);
        return out;
    }
    godot::Array surfaces()const {
        godot::Array out;
        const auto flows=visible_flows();
        for(const auto &[k,t]:domain_.tiles())if(visual_tile(k,t))for(const auto &[local,id]:t.ids) {
            (void)k;(void)local;const auto &v=domain_.graph().volumes().at(id);
            if(!v.litres)continue;
            godot::Array row;row.push_back(static_cast<int64_t>(id));row.push_back(static_cast<int64_t>(v.type));row.push_back(v.level());row.push_back(godot::Vector3i(k.x,k.y,k.z));
            if(auto it=flows.find(id);it!=flows.end())row.push_back(it->second);
            out.push_back(row);
        }
        return out;
    }
    godot::Array mesh(Id id)const {
        using namespace godot;
        Array out;
        for(const auto &[k,t]:domain_.tiles())if(visual_tile(k,t))for(const auto &c:t.geometry->compartments) {
            if(t.ids.at(c.id)!=id)continue;
            PackedVector3Array vertices;PackedVector2Array uv;
            const bool exposed=std::any_of(c.spans.begin(),c.spans.end(),[](const auto &s){return s.top==height;});
            for(const auto &patch:surface::build(*t.geometry,c))for(auto p:patch.vertices) {
                vertices.push_back(Vector3(k.x+p.x*t.geometry->step,0,k.z+p.z*t.geometry->step));
                // Exposed basin banks may extend into solid by one sample.
                // Roofed intervals keep the conservative lower clip.
                uv.push_back(Vector2(p.floor-(exposed?1.35:0.35),patch.ceiling));
            }
            out.push_back(vertices);out.push_back(uv);return out;
        }
        return out;
    }
    godot::Dictionary report()const {
        godot::Dictionary d;
        d["litres"]=domain_.graph().finite();d["initial"]=domain_.graph().initial();
        d["injected"]=domain_.graph().injected();d["drained"]=domain_.graph().drained();
        std::size_t active=0,visual=0;
        for(const auto &[k,t]:domain_.tiles()){(void)k;if(t.available)++active;if(visual_tile(k,t)&&wet_tile(t))++visual;}
        d["active_tiles"]=static_cast<int64_t>(active);d["visible_wet_tiles"]=static_cast<int64_t>(visual);
        d["tiles"]=static_cast<int64_t>(domain_.tiles().size());d["volumes"]=static_cast<int64_t>(domain_.graph().volumes().size());
        d["portals"]=static_cast<int64_t>(domain_.graph().portals().size());d["sources"]=static_cast<int64_t>(domain_.seeded().size());
        d["ticks"]=static_cast<int64_t>(ticks_);d["visited"]=static_cast<int64_t>(visited_);d["moved"]=static_cast<int64_t>(moved_);
        d["pending_edit_tiles"]=static_cast<int64_t>(edited_tiles_.size());
        d["publications"]=static_cast<int64_t>(publications_);d["blocked_tiles"]=static_cast<int64_t>(blocked_.size());
        d["max_tick_us"]=static_cast<int64_t>(max_tick_us_);d["max_snapshot_us"]=static_cast<int64_t>(max_snapshot_us_);
        return d;
    }
};
}
