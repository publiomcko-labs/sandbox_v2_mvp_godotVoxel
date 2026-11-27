#pragma once
#include "hydraulic_voxel_snapshot.hpp"
#include "core/hydraulic_domain.hpp"
#include "core/hydraulic_worker.hpp"
#include "core/hydraulic_surface.hpp"
#include "core/hydraulic_hybrid_surface.hpp"
#include "hydraulic_integrated_runtime.hpp"
#include "content_registry/hydraulic_profile.hpp"
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace sandbox::hydraulic {
class Runtime {
    content::HydraulicProfile profile_;
    Domain domain_;
    bool integrated_mode_=false;
    std::unique_ptr<IntegratedRuntime> integrated_;
    tp::Worker worker_;
    hybrid::Renderer hybrid_renderer_;
    std::map<core::Region,std::uint64_t> pending_,blocked_;
    std::set<core::Region> capacity_blocked_;
    std::uint64_t capacity_rejections_=0,dry_evictions_=0;
    std::size_t peak_volumes_=0,peak_portals_=0;
    std::set<core::Region> edited_tiles_,edit_group_,seed_interest_;
    // Only bootstrap geometry from an unedited world. Never reuse this
    // exception for edited or reopened nonzero-revision worlds.
    std::set<core::Region> pristine_surveyed_;
    std::map<std::string,std::set<core::Region>> seed_windows_;
    std::uint64_t seed_boundary_caps_=0;
    std::uint64_t edit_group_revision_=0;
    std::map<Id,std::pair<Transfer,std::uint64_t>> recent_flows_;
    std::uint64_t debt_=0,ticks_=0,visited_=0,moved_=0,publications_=0,max_tick_us_=0,max_snapshot_us_=0;
    static constexpr int side=16,base=-32,height=64;
    std::optional<core::Region> last_center_;
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
        if(edited_tiles_.contains(k)||seed_interest_.contains(k))return true;
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
    // Close numerical cracks between certified wet exposed faces, not
    // just portals with a recent transfer. A cached tile may participate
    // only while its rendered revision is still valid. No physics changes.
    std::map<Id,godot::PackedVector3Array> visible_seams(const std::map<Id,double> &heads)const {
        using namespace godot;
        std::map<Id,PackedVector3Array> out;
        if(heads.empty())return out;
        const auto &graph=domain_.graph();
        std::map<Id,std::pair<const Tile*,Id>> locations;
        for(const auto &[k,t]:domain_.tiles())if(t.renderable()) {
            (void)k;
            for(const auto &[local,id]:t.ids)if(heads.contains(id))locations.emplace(id,std::pair{&t,local});
        }
        std::size_t remaining=2048;
        for(const auto &[id,location]:locations) {
            if(!remaining)break;
            for(auto pid:graph.incident(id)) {
                if(!remaining)break;
                const auto &p=graph.portals().at(pid);
                const Id other=p.a==id?p.b:p.a;
                if(!locations.contains(other)||p.opening_height_m<=0)continue;
                const double high=heads.at(id),low=heads.at(other);
                // Larger falls retain the H5 flow presentation. Do not
                // draw across a sill above either water surface.
                if(high-low<0.0005||high-low>1.0||low<=p.sill_m||
                    high>=p.sill_m+p.opening_height_m||
                    graph.volumes().at(id).type!=graph.volumes().at(other).type)continue;
                const auto [a,la]=location;
                const auto [b,lb]=locations.at(other);
                const auto faces=surface::flow_faces(*a->geometry,la,*b->geometry,lb,
                    static_cast<int>(std::lround(p.sill_m*1000)),
                    static_cast<int>(std::lround((p.sill_m+p.opening_height_m)*1000)),
                    base+height,high,low,remaining,0.0005,0.0);
                for(const auto &q:faces) {
                    auto &vertices=out[id];
                    const Vector3 a0(q.x0,q.bottom-0.001,q.z0),a1(q.x0,q.top+0.001,q.z0),
                        b0(q.x1,q.bottom-0.001,q.z1),b1(q.x1,q.top+0.001,q.z1);
                    for(const auto &v:{a0,a1,b1,a0,b1,b0})vertices.push_back(v);
                    --remaining;
                }
            }
        }
        return out;
    }
    std::map<Id,godot::PackedVector3Array> visible_flows(const std::map<Id,double> &heads)const {
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
            if(heads.contains(f.from)&&heads.contains(f.to)) {
                const double high=heads.at(f.from),low=heads.at(f.to);
                if(high-low<0.08||(high-low<=1.0&&low>p->second.sill_m&&
                    high<p->second.sill_m+p->second.opening_height_m))continue;
            }
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
    void seed(const core::Region &center) {
        seed_interest_.clear();
        for(const auto &rule:profile_.config.at("sources")) {
            const auto id=content::str(rule.at("id"));
            if(domain_.seeded().contains(id))continue;
            const auto &a=rule.at("anchor_m");
            core::Vec3 anchor{a[0].get<double>()+0.5,a[1].get<double>()+0.5,a[2].get<double>()+0.5};
            const auto k=key(anchor);
            if(!within_interest(k,center))continue;
            if(integrated_mode_)seed_interest_.insert(k);
            auto found=domain_.tiles().find(k);
            if(found==domain_.tiles().end()||!found->second.available)continue;
            const auto &tile=found->second;
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
            else {
                // Start with the near field, then follow only below-head
                // exposed boundary spans of the reached component.
                // Follow the source valley farther when resident, bounded
                // by 64 surveyed tiles and the graph capacity headroom.
                auto &window=seed_windows_[id];
                if(window.empty())for(int x=-1;x<=1;++x)for(int z=-1;z<=1;++z)
                    window.insert({k.x+x*side,base,k.z+z*side});
                std::set<core::Region> frontier;
                if(domain_.seed_surface_basin(id,*chosen,slot,level,base+height,window,&frontier)) {
                    seed_windows_.erase(id);
                    continue;
                }
                if(!frontier.empty()) {
                    bool expanded=false;
                    for(const auto &q:frontier)
                        if(std::abs(q.x-k.x)<=5*side&&std::abs(q.z-k.z)<=5*side&&window.size()<64&&
                            domain_.graph().volumes().size()<3200)
                            expanded=window.insert(q).second||expanded;
                    if(!expanded) {
                        // Explicitly bounded fallback for a very large
                        // finite lake; never infer unknown terrain.
                        if(domain_.seed_surface_basin(id,*chosen,slot,level,base+height,window)) {
                            ++seed_boundary_caps_;seed_windows_.erase(id);continue;
                        }
                    }
                }
                seed_interest_.insert(window.begin(),window.end());
            }
        }
    }
public:
    explicit Runtime(content::HydraulicProfile profile,bool integrated=false):profile_(std::move(profile)),domain_(profile_.types),integrated_mode_(integrated){}
    Runtime(content::HydraulicProfile profile,Domain domain):profile_(std::move(profile)),domain_(std::move(domain)){}
    Runtime(content::HydraulicProfile profile,const nlohmann::json& archive):profile_(std::move(profile)),domain_(profile_.types),integrated_mode_(true) {
        if(archive.at("schema")=="v3-hybrid-runtime-1")integrated_=IntegratedRuntime::decode(archive,profile_.types);
        else if(archive.at("schema")=="v3-hybrid-bootstrap-1")domain_=persistence::decode_domain(archive.at("bootstrap"),profile_.types);
        else throw std::invalid_argument("hybrid save schema");
    }
    bool integrated_mode()const{return integrated_mode_;}
    nlohmann::json archive()const {
        if(integrated_)return integrated_->encode();
        if(integrated_mode_)return {{"schema","v3-hybrid-bootstrap-1"},{"bootstrap",persistence::encode_domain(domain_)}};
        return persistence::encode_domain(domain_);
    }
    const auto &domain()const{return domain_;}
    const auto &profile()const{return profile_;}
    // Conservative initial edit policy: no construction in a wet tile;
    // no carving that could merge different liquids in the same tile.
    bool allows_edit(core::Vec3 center,double radius,bool add) {
        if(integrated_)return integrated_->allows_edit(center,radius,add);
        if(integrated_mode_)return false;
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
        if(integrated_){integrated_->edited(center,radius,revision);return;}
        if(edited_tiles_.empty())edit_group_.clear();
        edit_group_revision_=revision;
        const auto lo=key({center.x-radius-2,0,center.z-radius-2}),hi=key({center.x+radius+2,0,center.z+radius+2});
        for(int x=lo.x;x<=hi.x;x+=side)for(int z=lo.z;z<=hi.z;z+=side) {
            const core::Region k{x,base,z};
            if(domain_.tiles().contains(k)){edited_tiles_.insert(k);edit_group_.insert(k);}
            domain_.invalidate(k,revision);worker_.invalidate(k);pending_.erase(k);blocked_.erase(k);capacity_blocked_.erase(k);
        }
    }
    void frame(const godot::Ref<godot::VoxelTool>& tool,core::Vec3 position,std::uint64_t revision,std::uint64_t elapsed) {
        if(!core::valid_point(position))throw std::invalid_argument("hydraulic interest");
        if(integrated_){integrated_->frame(tool,position,revision,elapsed);return;}
        const auto center=key(position);
        last_center_=center;
        const bool pristine=integrated_mode_&&revision==0;
        // Surveyed pristine seed tiles may remain available to the
        // finite basin initializer without LOD0. Once adopted, ordinary
        // integrated residency applies and only presentation is retained.
        for(const auto &[k,t]:domain_.tiles())if(t.available&&(!hydraulic_interest(k,center)||
            (!resident(tool,k)&&!(pristine&&pristine_surveyed_.contains(k)))))
            domain_.invalidate(k,t.geometry->revision);
        // Under pressure reclaim only suspended, dry geometry outside
        // the near/wet/seed interest. Never evict wet or edited state.
        const auto &g=domain_.graph();
        if(g.volumes().size()>=g.volume_budget()*3/4||
            g.portals().size()>=g.portal_budget()*3/4||domain_.tiles().size()>=192||
            !capacity_blocked_.empty()) {
            std::vector<core::Region> reclaim;
            for(const auto &[k,t]:domain_.tiles())
                if(!t.available&&!wet_tile(t)&&!hydraulic_interest(k,center)&&!pending_.contains(k))reclaim.push_back(k);
            std::size_t removed=0;
            for(const auto &k:reclaim) {
                if(domain_.forget_dry_tile(k)){++dry_evictions_;++removed;worker_.invalidate(k);blocked_.erase(k);}
                if(removed>=2)break;
            }
            if(removed)capacity_blocked_.clear();
        }
        for(auto it=capacity_blocked_.begin();it!=capacity_blocked_.end();) {
            if(!hydraulic_interest(*it,center))it=capacity_blocked_.erase(it);else ++it;
        }
        if(auto result=worker_.poll()) {
            const auto k=result->origin;pending_.erase(k);
            const bool loaded=resident(tool,k);
            const bool surveyed=pristine&&seed_interest_.contains(k)&&result->revision==0;
            if(hydraulic_interest(k,center)&&(loaded||surveyed)) {
                const auto before_volumes=g.volumes().size(),before_portals=g.portals().size();
                bool capacity=false;
                if(domain_.publish(std::move(*result),&capacity)){
                    if(surveyed&&!loaded)pristine_surveyed_.insert(k);
                    edited_tiles_.erase(k);++publications_;
                    if(g.volumes().size()<before_volumes||g.portals().size()<before_portals)capacity_blocked_.clear();
                    peak_volumes_=std::max(peak_volumes_,g.volumes().size());
                    peak_portals_=std::max(peak_portals_,g.portals().size());
                } else if(capacity) {
                    ++capacity_rejections_;capacity_blocked_.insert(k);
                } else blocked_[k]=revision;
            }
        }
        seed(center);
        if(integrated_mode_&&!domain_.seeded().empty()) {
            integrated_=std::make_unique<IntegratedRuntime>(domain_,pristine_surveyed_.size());
            domain_=Domain(profile_.types); // relinquish bootstrap mass owner
            return;
        }
        // At most one immutable copy per frame. Prioritize nearest tiles.
        std::vector<core::Region> candidates(edited_tiles_.begin(),edited_tiles_.end());
        candidates.insert(candidates.end(),seed_interest_.begin(),seed_interest_.end());
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
            if(pending_.contains(k)||capacity_blocked_.contains(k)||(blocked_.contains(k)&&blocked_.at(k)==revision))continue;
            if(domain_.tiles().size()>=256&&t==domain_.tiles().end())continue;
            const bool loaded=resident(tool,k);
            const bool survey=pristine&&seed_interest_.contains(k);
            if(!loaded&&!survey)continue;
            const auto start=std::chrono::steady_clock::now();
            auto snapshot=copy_air_snapshot(tool,godot::Vector3i(k.x,k.y,k.z),godot::Vector3i(side,height,side),revision,integrated_mode_,survey);
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
    Litres column_mass(core::Vec3 p)const {
        if(!core::valid_point(p)||!integrated_)return -1;
        return integrated_->column_mass(p);
    }
    godot::Dictionary at(core::Vec3 p)const {
        if(integrated_)return integrated_->at(p,profile_.types);
        godot::Dictionary out;const auto wet=domain_.wet_at(p);if(!wet)return out;
        out["slot"]=static_cast<int64_t>(wet->type);out["density"]=domain_.graph().types().at(wet->type).density;
        const auto &v=domain_.graph().volumes().at(*domain_.volume_at(p));
        const auto &g=*domain_.tiles().at(key(p)).geometry;
        const auto *span=tp::span_at(g,p);
        out["level"]=v.level();
        // Preserve the binary sample-floor API for existing tools;
        // physical_floor reports the conservative sub-metre capacity bound.
        out["floor"]=span?double(g.origin.y+span->bottom*g.step):v.curve.knots().front().mm*0.001;
        out["physical_floor"]=span?double(tp::span_floor_mm(g,*span))*0.001:v.curve.knots().front().mm*0.001;
        out["id"]=static_cast<int64_t>(v.id);
        return out;
    }
    godot::Array surfaces()const {
        if(integrated_)return integrated_->surfaces();
        godot::Array out;
        std::set<Id> exposed;
        for(const auto &[k,t]:domain_.tiles())if(t.renderable()&&visual_tile(k,t))for(const auto &c:t.geometry->compartments) {
            const auto id=t.ids.at(c.id);
            if(domain_.graph().volumes().at(id).litres&&std::any_of(c.spans.begin(),c.spans.end(),
                [](const auto &s){return s.top==height;}))exposed.insert(id);
        }
        // Unavailable due only to streaming is still a valid render
        // snapshot. Edited tiles are excluded until the new revision.
        const auto heads=domain_.graph().presentation_heads(exposed,0.15,true);
        auto flows=visible_flows(heads);
        for(const auto &[id,vertices]:visible_seams(heads))flows[id].append_array(vertices);
        for(const auto &[k,t]:domain_.tiles())if(visual_tile(k,t))for(const auto &[local,id]:t.ids) {
            (void)k;(void)local;const auto &v=domain_.graph().volumes().at(id);
            if(!v.litres)continue;
            godot::Array row;row.push_back(static_cast<int64_t>(id));row.push_back(static_cast<int64_t>(v.type));row.push_back(heads.contains(id)?heads.at(id):v.level());row.push_back(godot::Vector3i(k.x,k.y,k.z));
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
            for(const auto &patch:surface::build(*t.geometry,c,height))for(auto p:patch.vertices) {
                vertices.push_back(Vector3(k.x+p.x*t.geometry->step,p.offset,k.z+p.z*t.geometry->step));
                // Exposed basin banks may extend into solid by one sample.
                // Roofed intervals keep the conservative lower clip.
                uv.push_back(Vector2(p.floor-(exposed?1.35:0.35),patch.ceiling));
            }
            out.push_back(vertices);out.push_back(uv);return out;
        }
        return out;
    }
    godot::Dictionary hybrid_render() {
        using namespace godot;
        const auto started=std::chrono::steady_clock::now();
        const auto wanted=integrated_?integrated_->inputs():hybrid::snapshot(domain_,height);
        const auto snapshots_us=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count();
        auto done=hybrid_renderer_.poll(wanted);
        Array updates,keys,ready;
        for(const auto &[k,in]:wanted) {
            Vector3i tile(k.x,k.y,k.z);keys.push_back(tile);
            if(hybrid_renderer_.current(in))ready.push_back(tile);
        }
        // Retain prior revision during edit cohort, but never schedule
        // construction from invalidated geometry.
        for(const auto &k:edited_tiles_)if(!wanted.contains(k)&&domain_.tiles().contains(k)&&wet_tile(domain_.tiles().at(k)))
            keys.push_back(Vector3i(k.x,k.y,k.z));
        if(integrated_)for(const auto &[k,rev]:integrated_->dirty()){(void)rev;if(integrated_->retained_wet(k))keys.push_back(Vector3i(k.x,k.y,k.z));}
        for(auto &batch:done) {
            Dictionary row;
            const auto k=batch.input.tile;
            row["tile"]=Vector3i(k.x,k.y,k.z);
            row["revision"]=static_cast<int64_t>(batch.input.geometry->revision);
            row["build_us"]=static_cast<int64_t>(batch.build_us);
            row["fallback_columns"]=static_cast<int64_t>(batch.fallback_columns);
            Array materials;
            for(const auto &[slot,verts]:batch.materials) {
                if(verts.empty())continue;
                PackedVector3Array vertices;PackedVector2Array uv;
                vertices.resize(static_cast<int64_t>(verts.size()));uv.resize(static_cast<int64_t>(verts.size()));
                for(std::size_t i=0;i<verts.size();++i) {
                    const auto &v=verts[i];
                    vertices.set(static_cast<int64_t>(i),Vector3(v.x,v.y,v.z));
                    uv.set(static_cast<int64_t>(i),Vector2(v.floor,v.ceiling));
                }
                Array item;item.push_back(static_cast<int64_t>(slot));item.push_back(vertices);item.push_back(uv);materials.push_back(item);
            }
            row["materials"]=materials;updates.push_back(row);
        }
        Dictionary out;out["updates"]=updates;out["wanted"]=keys;out["ready"]=ready;
        out["snapshot_us"]=static_cast<int64_t>(snapshots_us);
        // Physical fingerprint for frozen A/B replay. Includes every
        // compartment's exact ledger and its revision/availability.
        std::uint64_t hash=1469598103934665603ULL;
        auto mix=[&](std::uint64_t x){hash^=x;hash*=1099511628211ULL;};
        if(integrated_) {
            const auto state=integrated_->report();mix(static_cast<std::uint64_t>(static_cast<int64_t>(state["litres"])));mix(static_cast<std::uint64_t>(static_cast<int64_t>(state["ticks"])));
        }else {mix(static_cast<std::uint64_t>(domain_.graph().finite()));mix(ticks_);}
        for(const auto &[id,v]:domain_.graph().volumes()){mix(id);mix(v.type);mix(static_cast<std::uint64_t>(v.litres));}
        for(const auto &[k,t]:domain_.tiles()){mix(static_cast<std::uint64_t>(k.x));mix(static_cast<std::uint64_t>(k.z));mix(t.geometry->revision);mix(t.expected_revision);mix(t.available?1:0);}
        out["physics_digest"]=String::utf8(std::to_string(hash).c_str());
        return out;
    }
    godot::Dictionary report()const {
        if(integrated_)return integrated_->report();
        godot::Dictionary d;
        d["litres"]=domain_.graph().finite();d["initial"]=domain_.graph().initial();
        d["injected"]=domain_.graph().injected();d["drained"]=domain_.graph().drained();
        std::size_t active=0,near_active=0,visual=0;
        for(const auto &[k,t]:domain_.tiles()){
            if(t.available){++active;if(last_center_&&within_interest(k,*last_center_))++near_active;}
            if(visual_tile(k,t)&&wet_tile(t))++visual;
        }
        d["active_tiles"]=static_cast<int64_t>(active);d["near_active_tiles"]=static_cast<int64_t>(near_active);
        d["visible_wet_tiles"]=static_cast<int64_t>(visual);
        d["tiles"]=static_cast<int64_t>(domain_.tiles().size());d["volumes"]=static_cast<int64_t>(domain_.graph().volumes().size());
        d["portals"]=static_cast<int64_t>(domain_.graph().portals().size());d["sources"]=static_cast<int64_t>(domain_.seeded().size());
        d["ticks"]=static_cast<int64_t>(ticks_);d["visited"]=static_cast<int64_t>(visited_);d["moved"]=static_cast<int64_t>(moved_);
        d["seed_survey_tiles"]=static_cast<int64_t>(seed_interest_.size());
        d["seed_boundary_caps"]=static_cast<int64_t>(seed_boundary_caps_);
        d["pending_edit_tiles"]=static_cast<int64_t>(edited_tiles_.size());
        d["edit_group_revision"]=static_cast<int64_t>(edit_group_revision_);
        godot::Array group;
        for(const auto &k:edit_group_)group.push_back(godot::Vector3i(k.x,k.y,k.z));
        d["edit_group_tiles"]=group;
        d["publications"]=static_cast<int64_t>(publications_);d["blocked_tiles"]=static_cast<int64_t>(blocked_.size());
        d["capacity_blocked_tiles"]=static_cast<int64_t>(capacity_blocked_.size());
        d["capacity_rejections"]=static_cast<int64_t>(capacity_rejections_);
        d["dry_evictions"]=static_cast<int64_t>(dry_evictions_);
        d["volume_budget"]=static_cast<int64_t>(domain_.graph().volume_budget());
        d["portal_budget"]=static_cast<int64_t>(domain_.graph().portal_budget());
        d["peak_volumes"]=static_cast<int64_t>(std::max(peak_volumes_,domain_.graph().volumes().size()));
        d["peak_portals"]=static_cast<int64_t>(std::max(peak_portals_,domain_.graph().portals().size()));
        d["max_tick_us"]=static_cast<int64_t>(max_tick_us_);d["max_snapshot_us"]=static_cast<int64_t>(max_snapshot_us_);
        return d;
    }
};
}
