#pragma once
#include "hydraulic_voxel_snapshot.hpp"
#include "core/hydraulic_provenance.hpp"
#include "core/hydraulic_worker.hpp"
#include "core/hydraulic_hybrid_surface.hpp"
#include "../../experiments/v3/hybrid/coupler.hpp"
#include "persistence/hydraulic_domain_store.hpp"
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
namespace sandbox::hydraulic {
class IntegratedRuntime {
    experiment::Coupler model_;
    std::set<std::string> sources_;
    std::map<std::string,std::set<core::Region>> source_windows_;
    std::set<core::Region> source_interest_;
    std::set<std::string> source_conflicts_;
    std::map<std::string,std::tuple<std::uint64_t,std::uint64_t,std::uint64_t>> source_attempts_;
    tp::Worker worker_;
    std::map<core::Region,std::uint64_t> pending_,dirty_,blocked_;
    std::set<core::Region> group_,activate_pending_,visual_invalidated_;
    hybrid::LayeredInputCache surface_cache_;
    EditProvenance provenance_;
    std::set<core::Region> pending_survey_;
    std::uint64_t visual_survey_tiles_{},post_edit_survey_tiles_{},suspended_reclaims_{};
    std::vector<std::uint64_t> tick_samples_;
    std::size_t pristine_survey_tiles_=0;
    std::uint64_t revision_{},debt_{},ticks_{},moved_{},publications_{},activations_{},settles_{},max_tick_us_{},max_snapshot_us_{};
    core::Region center_{};
    static constexpr int side=16,base=-32,height=64;
    static bool resident(const godot::Ref<godot::VoxelTool>& tool,core::Region k) {
        return tool.is_valid()&&tool->is_area_editable(godot::AABB(godot::Vector3(k.x,k.y,k.z),godot::Vector3(17,65,17)));
    }
    static core::Region key(core::Vec3 p){return {static_cast<int>(std::floor(p.x/16))*16,base,static_cast<int>(std::floor(p.z/16))*16};}
    static std::set<core::Region> affected(core::Vec3 p,double r) {
        std::set<core::Region> out;auto a=key({p.x-r-2,0,p.z-r-2}),b=key({p.x+r+2,0,p.z+r+2});
        for(int x=a.x;x<=b.x;x+=side)for(int z=a.z;z<=b.z;z+=side)out.insert({x,base,z});
        return out;
    }
    bool interested(core::Region k)const {
        if(dirty_.contains(k)||source_interest_.contains(k))return true;
        if(std::abs(k.x-center_.x)<=side&&std::abs(k.z-center_.z)<=side)return true;
        if(std::abs(k.x-center_.x)>144||std::abs(k.z-center_.z)>144)return false;
        for(auto d:{core::Region{0,0,0},core::Region{-16,0,0},core::Region{16,0,0},core::Region{0,0,-16},core::Region{0,0,16}}) {
            core::Region n{k.x+d.x,base,k.z+d.z};
            if(model_.tiles().contains(n)&&(model_.tile_mass(n)||model_.tiles().at(n).local))return true;
        }
        return false;
    }
    bool source_certified(core::Region k,std::uint64_t rev,const godot::Ref<godot::VoxelTool>& tool)const {
        const auto it=model_.tiles().find(k);
        return it!=model_.tiles().end()&&!dirty_.contains(k)&&
            (provenance_.certifies(k,it->second.geometry->revision,rev)||(it->second.resident&&resident(tool,k)));
    }
    void discover_sources(const nlohmann::json& rules,std::uint64_t rev,const godot::Ref<godot::VoxelTool>& tool) {
        source_interest_.clear();
        for(const auto &rule:rules){
            const auto id=rule.at("id").get<std::string>();
            if(sources_.contains(id))continue;
            const auto &a=rule.at("anchor_m");
            const core::Vec3 anchor{a[0].get<double>()+0.5,a[1].get<double>()+0.5,a[2].get<double>()+0.5};
            const auto k=key(anchor);
            // Discovery follows current interest, not the initial spawn.
            // Full view-range acquisition is a separate streaming gate.
            if(std::abs(k.x-center_.x)>side||std::abs(k.z-center_.z)>side){source_windows_.erase(id);source_attempts_.erase(id);continue;}
            const bool ocean=rule.at("source_kind")=="fixed_head_ocean";
            auto &window=source_windows_[id];
            if(window.empty()){
                if(ocean)window.insert(k);
                else for(int x=-1;x<=1;++x)for(int z=-1;z<=1;++z)window.insert({k.x+x*side,base,k.z+z*side});
            }
            source_interest_.insert(window.begin(),window.end());
            if(!dirty_.empty()||!std::all_of(window.begin(),window.end(),[&](auto q){return source_certified(q,rev,tool);}))continue;
            // Retry on new certification, terrain revision or a bounded
            // simulation cadence if a competing front currently owns it.
            const auto stamp=std::tuple{publications_,ticks_/20,rev};
            if(source_attempts_.contains(id)&&source_attempts_.at(id)==stamp)continue;
            source_attempts_[id]=stamp;
            const auto &g=*model_.tiles().at(k).geometry;
            const double level=rule.at("level_m").get<double>();
            std::optional<core::Vec3> chosen;Id compartment_id{};
            double best=std::numeric_limits<double>::infinity();
            for(const auto &col:g.column_runs)for(const auto &s:col){
                const double floor=tp::span_floor_mm(g,s)*0.001;
                if(s.top!=height||floor+0.1>=level)continue;
                core::Vec3 q{k.x+s.x+0.5,floor+0.05,k.z+s.z+0.5};
                const double distance=(q.x-anchor.x)*(q.x-anchor.x)+(q.z-anchor.z)*(q.z-anchor.z);
                if(distance<best){best=distance;chosen=q;compartment_id=s.compartment;}
            }
            if(!chosen){source_conflicts_.insert(id);continue;}
            const auto type=rule.at("slot").get<std::size_t>();
            bool accepted=false;
            if(ocean)accepted=model_.ocean({id,k,*chosen,type,level,chosen->y,4});
            else{
                std::set<core::Region> frontier;
                const auto result=model_.seed_surface_basin(k,compartment_id,type,level,base+height,window,frontier);
                accepted=result==experiment::Coupler::BasinResult::seeded;
                if(result==experiment::Coupler::BasinResult::frontier){
                    bool expanded=false;
                    for(auto q:frontier)if(window.size()<64&&std::abs(q.x-k.x)<=5*side&&std::abs(q.z-k.z)<=5*side)
                        expanded=window.insert(q).second||expanded;
                    source_interest_.insert(window.begin(),window.end());
                    if(!expanded)source_conflicts_.insert(id);
                    continue;
                }
            }
            if(accepted){sources_.insert(id);source_windows_.erase(id);source_attempts_.erase(id);source_conflicts_.erase(id);}
            else source_conflicts_.insert(id);
        }
    }
    bool activate(core::Region k) {
        if(model_.tiles().at(k).local)return true;
        if(!model_.activate(k))return false;
        ++activations_;return true;
    }
public:
    explicit IntegratedRuntime(const Domain& bootstrap,std::size_t surveyed=0):model_(experiment::Coupler::adopt(bootstrap)),sources_(bootstrap.seeded()),pristine_survey_tiles_(surveyed){}
    IntegratedRuntime(experiment::Coupler model,std::set<std::string> sources):model_(std::move(model)),sources_(std::move(sources)){}
    const auto& model()const{return model_;}
    bool allows_edit(core::Vec3 p,double radius,bool add) {
        if(!core::valid_point(p)||!std::isfinite(radius)||radius<0.5||radius>8)return false;
        std::size_t needed=0,new_tiles=0;
        const auto keys=affected(p,radius);
        bool near_wet=false;
        for(auto k:keys)if(model_.tiles().contains(k)&&model_.tile_mass(k))near_wet=true;
        for(auto k:keys) {
            auto it=model_.tiles().find(k);
            if(it==model_.tiles().end()) {if(near_wet){++needed;++new_tiles;}continue;}
            if(!it->second.resident||dirty_.contains(k))return false;
            if(add&&model_.tile_mass(k))return false;
            if(!add&&near_wet&&!it->second.local)++needed;
        }
        if(needed+model_.active()>model_.active_limit()||new_tiles+model_.tiles().size()>model_.tile_limit())return false;
        // Activate BEFORE terrain mutation so the old column occupation is
        // preserved when a newly carved interval joins the same basin.
        if(!add&&near_wet)for(auto k:keys)if(model_.tiles().contains(k)&&!activate(k))return false;
        return true;
    }
    void edited(core::Vec3 p,double radius,std::uint64_t rev) {
        if(dirty_.empty())group_.clear();
        revision_=rev;
        const auto keys=affected(p,radius);
        provenance_.record(rev,keys);
        bool near_wet=false;for(auto k:keys)if(model_.tiles().contains(k)&&model_.tile_mass(k))near_wet=true;
        for(auto k:keys) {
            visual_invalidated_.insert(k);
            if(model_.tiles().contains(k)){dirty_[k]=rev;group_.insert(k);model_.set_resident(k,false);}
            else if(near_wet){dirty_[k]=rev;group_.insert(k);activate_pending_.insert(k);}
            worker_.invalidate(k);pending_.erase(k);pending_survey_.erase(k);blocked_.erase(k);
        }
    }
    void frame(const godot::Ref<godot::VoxelTool>& tool,core::Vec3 p,std::uint64_t rev,std::uint64_t elapsed,const nlohmann::json& rules) {
        center_=key(p);
        if(provenance_.revision()!=rev)provenance_.invalidate(rev);
        discover_sources(rules,rev,tool);
        for(const auto &[k,t]:model_.tiles())if(t.resident&&(!interested(k)||!resident(tool,k))){
            model_.set_resident(k,false);
            if(!dirty_.contains(k)&&model_.reclaim_suspended(k)){++suspended_reclaims_;++settles_;}
        }
        if(auto result=worker_.poll()) {
            const auto k=result->origin;pending_.erase(k);
            const bool surveyed=pending_survey_.erase(k)>0;
            const bool loaded=resident(tool,k);
            const bool certified=surveyed&&!dirty_.contains(k)&&result->revision==0&&provenance_.pristine(k,rev);
            if(interested(k)&&(loaded||certified)&&(!surveyed||certified)&&(!dirty_.contains(k)||result->revision>=dirty_.at(k))) {
                auto geometry=std::make_shared<const tp::Result>(std::move(*result));
                const bool exists=model_.tiles().contains(k);
                if(!exists&&model_.tiles().size()>=model_.tile_limit()) {
                    std::optional<core::Region> evict;
                    for(const auto &[q,t]:model_.tiles())if(!t.resident&&!t.local&&!dirty_.contains(q)&&!interested(q)&&!model_.tile_mass(q)){evict=q;break;}
                    if(evict)model_.forget_dry(*evict);
                }
                if(exists?model_.replace_geometry(geometry):model_.publish(geometry)) {
                    if(!loaded){model_.set_resident(k,false);++visual_survey_tiles_;if(rev)++post_edit_survey_tiles_;}
                    if(activate_pending_.contains(k)&&!activate(k)){
                        model_.set_resident(k,false);blocked_[k]=rev;
                    }else {
                        activate_pending_.erase(k);dirty_.erase(k);blocked_.erase(k);++publications_;
                    }
                }else blocked_[k]=rev;
            }
        }
        // Same Voxel Tools snapshots as H14; one acquisition per frame,
        // cached wet geometry survives loss of LOD0 residency.
        std::set<core::Region> candidates=source_interest_;
        for(const auto &[k,r]:dirty_){(void)r;candidates.insert(k);}
        for(int x=-1;x<=1;++x)for(int z=-1;z<=1;++z)candidates.insert({center_.x+x*16,base,center_.z+z*16});
        for(const auto &[k,t]:model_.tiles())if(model_.tile_mass(k)||t.local)
            for(auto d:{core::Region{0,0,0},core::Region{-16,0,0},core::Region{16,0,0},core::Region{0,0,-16},core::Region{0,0,16}}) {
                core::Region q{k.x+d.x,base,k.z+d.z};if(interested(q))candidates.insert(q);
            }
        std::vector<core::Region> ordered(candidates.begin(),candidates.end());
        std::sort(ordered.begin(),ordered.end(),[&](auto a,auto b){
            if(dirty_.contains(a)!=dirty_.contains(b))return dirty_.contains(a);
            return std::abs(a.x-center_.x)+std::abs(a.z-center_.z)<std::abs(b.x-center_.x)+std::abs(b.z-center_.z);
        });
        bool acquired=false;
        if(pending_.size()<2)for(int pass=0;pass<2&&!acquired;++pass)for(auto k:ordered) {
            auto it=model_.tiles().find(k);
            if(it!=model_.tiles().end()&&it->second.resident&&!dirty_.contains(k))continue;
            if(pending_.contains(k)||(blocked_.contains(k)&&blocked_.at(k)==rev))continue;
            const bool loaded=resident(tool,k);
            const bool survey=!loaded&&pass==1&&it==model_.tiles().end()&&!dirty_.contains(k)&&provenance_.pristine(k,rev);
            if((pass==0&&!loaded)||(pass==1&&!survey))continue;
            if(it==model_.tiles().end()&&model_.tiles().size()>=model_.tile_limit()) {
                bool can_reclaim=false;for(const auto &[q,t]:model_.tiles())if(!t.resident&&!t.local&&!dirty_.contains(q)&&!interested(q)&&!model_.tile_mass(q)){can_reclaim=true;break;}
                if(!can_reclaim)continue;
            }
            const auto start=std::chrono::steady_clock::now();
            const auto wanted_revision=survey?0:dirty_.contains(k)?dirty_.at(k):it!=model_.tiles().end()?it->second.geometry->revision:rev;
            auto s=copy_air_snapshot(tool,godot::Vector3i(k.x,k.y,k.z),godot::Vector3i(side,height,side),wanted_revision,true,survey);
            max_snapshot_us_=std::max(max_snapshot_us_,static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count()));
            if(s&&worker_.submit(std::move(*s))){pending_[k]=wanted_revision;if(survey)pending_survey_.insert(k);acquired=true;break;}
        }
        constexpr std::uint64_t period=50000000;
        debt_=std::min(debt_+std::min(elapsed,period*2),period*2);
        if(debt_<period)return;
        const auto start=std::chrono::steady_clock::now();
        // Do not step a partial revision cohort. This preserves the front
        // on the previous certified geometry until all edited tiles arrive.
        if(!dirty_.empty())return;
        // Expand a live front before the boundary transfer. Retain one
        // emergency slot for edits; no limit increase or blocked flow.
        if(model_.active()+1<model_.active_limit()){
            for(auto k:model_.local_front_candidates()){
                if(activate(k))break;
            }
        }
        if(ticks_%10==0&&model_.active()<model_.active_limit()/2) {
            for(auto k:model_.flow_candidates(0.35))if(model_.active()<model_.active_limit()/2)activate(k);
        }
        for(const auto &[k,t]:model_.tiles())if(t.local&&t.resident&&t.phase==experiment::Phase::local_active)model_.request_settle(k);
        const auto n=model_.active();moved_+=static_cast<std::uint64_t>(model_.tick());settles_+=n-model_.active();
        ++ticks_;debt_-=period;
        const auto us=static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count());
        max_tick_us_=std::max(max_tick_us_,us);if(tick_samples_.size()<4096)tick_samples_.push_back(us);
    }
    Litres column_mass(core::Vec3 p)const {
        const auto k=key(p);return model_.column_mass(k,static_cast<int>(std::floor(p.x))-k.x,static_cast<int>(std::floor(p.z))-k.z);
    }
    godot::Dictionary at(core::Vec3 p,const std::vector<Liquid>& types)const {
        godot::Dictionary d;auto s=model_.sample(p,key(p));if(!s)return d;
        const auto [type,mass,head,floor]=*s;d["slot"]=static_cast<int64_t>(type);d["density"]=types.at(type).density;
        d["litres"]=mass;d["level"]=head;d["floor"]=floor;d["physical_floor"]=floor;return d;
    }
    // One immutable surface input per known wet tile, independent of LOD0
    // residency. For a local window, use actual wet intervals, never an
    // averaged compartment head. Aggregate tiles keep B2 bank support.
    const auto& inputs() {
        auto changed=model_.take_surface_changes();
        changed.insert(visual_invalidated_.begin(),visual_invalidated_.end());
        visual_invalidated_.clear();
        auto geometry=[&](core::Region k)->std::shared_ptr<const tp::Result>{
            auto it=model_.tiles().find(k);
            return it==model_.tiles().end()||dirty_.contains(k)?nullptr:it->second.geometry;
        };
        auto primary=[&](core::Region k)->std::optional<hybrid::Input>{
            if(!geometry(k)||!model_.tile_mass(k))return std::nullopt;
            const auto &t=model_.tiles().at(k);
            hybrid::Input in{k,t.geometry,{},height,{}};in.layered=true;
            auto add=[&](int x,int z,int floor,int ceiling,std::size_t type,double head) {
                if(head<=floor*0.001||head>=ceiling*0.001-0.001)return;
                // Quantize only render heads, retain nonzero shallow
                // occupancy and the exact interval bounds.
                const double visual=std::clamp(std::round(head*100.0)/100.0,floor*0.001+0.0001,ceiling*0.001-0.001);
                in.cells.push_back({k.x+x,k.z+z,floor,ceiling,type,visual,{visual,visual,visual,visual}});
            };
            if(t.local)for(const auto &c:t.local->columns()) {
                if(c.litres)add(c.x,c.z,c.floor_mm,c.ceiling_mm,c.type,c.head());
            }else for(const auto &c:t.geometry->compartments) {
                auto v=t.aggregate.find(c.id);if(v==t.aggregate.end()||!v->second.litres)continue;
                const auto h=c.curve.level(v->second.litres);
                for(const auto &s:c.spans)add(s.x,s.z,tp::span_floor_mm(*t.geometry,s),(k.y+s.top)*1000,v->second.type,h);
            }
            if(in.cells.empty())return std::nullopt;
            return in;
        };
        return surface_cache_.update(changed,side,height,primary,geometry);
    }
    std::uint64_t ticks()const{return ticks_;}
    godot::Array surfaces()const {
        godot::Array rows;int64_t id=1;
        for(const auto &[k,t]:model_.tiles())if(model_.tile_mass(k)) {
            (void)t;godot::Array row;row.push_back(id++);row.push_back(0);row.push_back(0.0);row.push_back(godot::Vector3i(k.x,k.y,k.z));rows.push_back(row);
        }
        return rows;
    }
    const auto& dirty()const{return dirty_;}
    bool retained_wet(core::Region k)const{return model_.tiles().contains(k)&&model_.tile_mass(k)>0;}
    godot::Dictionary render_state()const {
        using namespace godot;Dictionary d;
        d["pending_edit_tiles"]=static_cast<int64_t>(dirty_.size());
        d["edit_group_revision"]=static_cast<int64_t>(revision_);
        Array group;for(auto k:group_)group.push_back(Vector3i(k.x,k.y,k.z));d["edit_group_tiles"]=group;
        return d;
    }
    godot::Dictionary report()const {
        using namespace godot;Dictionary d;
        d["solver"]="hybrid";d["litres"]=model_.mass();d["initial"]=model_.initial();d["injected"]=model_.injected();d["drained"]=model_.drained();
        d["ticks"]=static_cast<int64_t>(ticks_);d["moved"]=static_cast<int64_t>(moved_);d["publications"]=static_cast<int64_t>(publications_);
        d["tiles"]=static_cast<int64_t>(model_.tiles().size());d["sources"]=static_cast<int64_t>(sources_.size());
        Array source_ids,source_conflicts;for(const auto &id:sources_)source_ids.push_back(String::utf8(id.c_str()));
        for(const auto &id:source_conflicts_)source_conflicts.push_back(String::utf8(id.c_str()));
        d["source_ids"]=source_ids;d["source_conflicts"]=source_conflicts;d["source_interest_tiles"]=static_cast<int64_t>(source_interest_.size());
        d["pristine_survey_tiles"]=static_cast<int64_t>(pristine_survey_tiles_);
        d["visual_survey_tiles"]=static_cast<int64_t>(visual_survey_tiles_);d["post_edit_survey_tiles"]=static_cast<int64_t>(post_edit_survey_tiles_);
        d["provenance_complete"]=provenance_.complete();d["edited_provenance_tiles"]=static_cast<int64_t>(provenance_.size());
        d["surface_primary_rebuilds"]=static_cast<int64_t>(surface_cache_.primary_rebuilds());d["surface_input_rebuilds"]=static_cast<int64_t>(surface_cache_.input_rebuilds());
        d["local_active"]=static_cast<int64_t>(model_.active());d["activations"]=static_cast<int64_t>(activations_);d["settles"]=static_cast<int64_t>(settles_);
        d["suspended_reclaims"]=static_cast<int64_t>(suspended_reclaims_);
        auto samples=tick_samples_;std::sort(samples.begin(),samples.end());
        d["tick_p95_us"]=samples.empty()?0:static_cast<int64_t>(samples[(samples.size()*95-1)/100]);
        d["max_tick_us"]=static_cast<int64_t>(max_tick_us_);d["max_snapshot_us"]=static_cast<int64_t>(max_snapshot_us_);
        d["pending_edit_tiles"]=static_cast<int64_t>(dirty_.size());d["blocked_tiles"]=static_cast<int64_t>(blocked_.size());
        d["edit_group_revision"]=static_cast<int64_t>(revision_);
        Array group;for(auto k:group_)group.push_back(Vector3i(k.x,k.y,k.z));d["edit_group_tiles"]=group;
        int64_t active=0,near_count=0,wet=0,intervals=0,local_bytes=0;
        for(const auto &[k,t]:model_.tiles()){
            if(t.resident){++active;if(std::abs(k.x-center_.x)<=16&&std::abs(k.z-center_.z)<=16)++near_count;}
            if(model_.tile_mass(k))++wet;
            if(t.local){intervals+=static_cast<int64_t>(t.local->columns().size());local_bytes+=static_cast<int64_t>(t.local->bytes()+t.owners.capacity()*sizeof(Id));}
        }
        d["active_tiles"]=active;d["near_active_tiles"]=near_count;d["visible_wet_tiles"]=wet;d["local_intervals"]=intervals;d["local_bytes"]=local_bytes;
        return d;
    }
    nlohmann::json encode()const {
        using J=nlohmann::json;J geometry=J::array(),dirty=J::array(),activate_pending=J::array();
        for(const auto &[k,t]:model_.tiles()){
            const auto &g=*t.geometry;J runs=J::array();
            for(const auto &col:g.column_runs)for(const auto &s:col)runs.push_back({s.x,s.z,s.bottom,s.top});
            geometry.push_back({{"key",{k.x,k.y,k.z}},{"revision",g.revision},{"runs",runs},{"floor",g.surface_floor},{"refined",g.refine_exposed}});
            if(!g.render_sdf.empty()&&(model_.tile_mass(k)||t.local)){
                constexpr char hex[]="0123456789abcdef";
                std::string packed;packed.reserve(g.render_sdf.size()*4);
                for(auto v:g.render_sdf){const auto u=static_cast<std::uint16_t>(v);for(int shift:{12,8,4,0})packed.push_back(hex[(u>>shift)&15]);}
                geometry.back()["render_sdf"]=std::move(packed);geometry.back()["render_pad"]=g.render_pad;
            }
            if(!g.halo_runs.empty()){
                J hr=J::array();for(const auto &col:g.halo_runs)for(const auto &s:col)hr.push_back({s.x,s.z,s.bottom,s.top});
                geometry.back()["halo_runs"]=std::move(hr);geometry.back()["halo_floor"]=g.halo_floor;
            }
        }
        for(const auto &[k,rev]:dirty_)dirty.push_back({k.x,k.y,k.z,rev});
        for(const auto &k:activate_pending_)activate_pending.push_back({k.x,k.y,k.z});
        return {{"schema","v3-hybrid-runtime-1"},{"geometry",geometry},{"coupler",model_.encode()},{"sources",sources_},{"provenance",provenance_.encode()},{"dirty",dirty},{"activate_pending",activate_pending},{"revision",revision_},{"ticks",ticks_},{"debt",debt_},{"moved",moved_},{"activations",activations_},{"settles",settles_},{"suspended_reclaims",suspended_reclaims_}};
    }
    static std::unique_ptr<IntegratedRuntime> decode(const nlohmann::json& j,const std::vector<Liquid>& types) {
        if(j.at("schema")!="v3-hybrid-runtime-1"||!j.at("geometry").is_array()||j.at("geometry").size()>128)throw std::invalid_argument("hybrid runtime archive");
        std::map<core::Region,std::shared_ptr<const tp::Result>> geometry;
        for(const auto &row:j.at("geometry")){
            const auto &a=row.at("key");core::Region k{a[0].get<int>(),a[1].get<int>(),a[2].get<int>()};
            if(k.y!=base||k.x%16||k.z%16||geometry.contains(k)||row.at("runs").size()>16384)throw std::invalid_argument("hybrid archive geometry");
            tp::Snapshot s{k,16,64,16,1,row.at("revision").get<std::uint64_t>(),std::vector<std::uint8_t>(16*64*16)};
            for(const auto &v:row.at("runs")){
                const int x=v[0].get<int>(),z=v[1].get<int>(),lo=v[2].get<int>(),hi=v[3].get<int>();
                if(x<0||x>=16||z<0||z>=16||lo<0||hi>64||lo>=hi)throw std::invalid_argument("hybrid archive run");
                for(int y=lo;y<hi;++y){auto &air=s.air.at(static_cast<std::size_t>((z*16+x)*64+y));if(air)throw std::invalid_argument("hybrid archive duplicate run");air=1;}
            }
            s.surface_floor=row.at("floor").get<std::vector<float>>();s.refine_exposed=row.at("refined").get<bool>();
            if(row.contains("render_sdf")){
                s.render_pad=row.at("render_pad").get<int>();
                if(s.render_pad<0||s.render_pad>1)throw std::invalid_argument("render archive pad");
                const auto &packed=row.at("render_sdf").get_ref<const std::string&>();
                const auto w=17+2*s.render_pad;
                if(packed.size()!=static_cast<std::size_t>(w*w*65*4))throw std::invalid_argument("render archive shape");
                auto nibble=[](char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;throw std::invalid_argument("render archive hex");};
                for(std::size_t q=0;q<packed.size();q+=4){int n=0;for(std::size_t j=0;j<4;++j)n=n*16+nibble(packed[q+j]);s.render_sdf.push_back(static_cast<std::int16_t>(n>=32768?n-65536:n));}
            }
            if(row.contains("halo_runs")){
                s.halo_floor=row.at("halo_floor").get<std::vector<float>>();s.halo_air.resize(18*18*64);
                for(const auto &v:row.at("halo_runs")){
                    const int x=v[0].get<int>(),z=v[1].get<int>(),lo=v[2].get<int>(),hi=v[3].get<int>();
                    if(x< -1||x>16||z< -1||z>16||(x>=0&&x<16&&z>=0&&z<16)||lo<0||hi>64||lo>=hi)throw std::invalid_argument("render archive halo");
                    for(int y=lo;y<hi;++y)s.halo_air.at(static_cast<std::size_t>(((z+1)*18+x+1)*64+y))=1;
                }
            }
            geometry.emplace(k,std::make_shared<const tp::Result>(tp::extract(s)));
        }
        auto model=experiment::Coupler::decode(j.at("coupler"),types,geometry);model.suspend_all();
        auto out=std::make_unique<IntegratedRuntime>(std::move(model),j.at("sources").get<std::set<std::string>>());
        for(const auto &v:j.at("dirty")){core::Region k{v[0].get<int>(),v[1].get<int>(),v[2].get<int>()};if(k.y!=base||k.x%16||k.z%16)throw std::invalid_argument("hybrid dirty tile");out->dirty_[k]=v[3].get<std::uint64_t>();out->group_.insert(k);}
        if(j.contains("activate_pending"))for(const auto &v:j.at("activate_pending")){
            core::Region k{v[0].get<int>(),v[1].get<int>(),v[2].get<int>()};
            if(!out->dirty_.contains(k))throw std::invalid_argument("hybrid pending owner");
            out->activate_pending_.insert(k);
        }
        out->revision_=j.at("revision").get<std::uint64_t>();
        out->provenance_=EditProvenance::decode(j.value("provenance",nlohmann::json(nullptr)),out->revision_);
        out->ticks_=j.at("ticks").get<std::uint64_t>();
        out->activations_=j.value("activations",std::uint64_t(0));out->settles_=j.value("settles",std::uint64_t(0));
        out->suspended_reclaims_=j.value("suspended_reclaims",std::uint64_t(0));
        if(out->suspended_reclaims_>out->settles_)throw std::invalid_argument("hybrid lifecycle counters");
        out->debt_=j.at("debt").get<std::uint64_t>();out->moved_=j.at("moved").get<std::uint64_t>();
        if(out->debt_>100000000)throw std::invalid_argument("hybrid archive tick debt");
        return out;
    }
};
}
