#pragma once
#include "hydraulic_voxel_snapshot.hpp"
#include "core/hydraulic_provenance.hpp"
#include "core/hydraulic_worker.hpp"
#include "core/hydraulic_hybrid_surface.hpp"
#include "../../experiments/v3/hybrid/coupler.hpp"
#include "../../experiments/v3/hybrid/finite_basin_survey.hpp"
#include "persistence/hydraulic_region_store.hpp"
#include <array>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
namespace sandbox::hydraulic {
class IntegratedRuntime {
    experiment::Coupler model_;
    std::unique_ptr<persistence::HydraulicRegionStore> cold_store_;
    std::uint64_t cold_evictions_{},cold_restores_{},cold_visual_reads_{};
    std::map<core::Region,hybrid::Input> cold_visible_;
    std::map<core::Region,std::map<std::string,experiment::OceanReach>> cold_ocean_;
    std::set<core::Region> ocean_interest_,ocean_dirty_,ocean_examined_;
    std::optional<core::Region> ocean_search_center_;
    std::optional<std::uint64_t> ocean_revision_;
    std::uint64_t ocean_certifications_{},ocean_acquisitions_{};
    std::optional<core::Region> cold_scan_center_;
    std::size_t cold_scan_cursor_{};
    int cold_scan_radius_{};
    std::set<std::string> sources_;
    std::map<std::string,std::set<core::Region>> source_windows_;
    std::set<core::Region> source_interest_;
    std::map<std::string,experiment::FiniteBasinSurvey> basin_surveys_;
    std::uint64_t basin_completed_{},basin_surveyed_tiles_{},basin_wet_tiles_{},basin_cold_seeds_{},basin_commit_max_us_{};
    Litres basin_initial_litres_{};
    bool finite_pending_=false;
    std::size_t visible_sources_pending_{};
    std::uint64_t nonresident_source_discoveries_{};
    double view_distance_=192.0;
    std::set<std::string> source_conflicts_;
    std::map<std::string,std::string> source_diagnostics_;
    std::map<std::string,std::tuple<std::uint64_t,std::uint64_t,std::uint64_t>> source_attempts_;
    tp::Worker worker_;
    std::map<core::Region,std::uint64_t> pending_,dirty_,blocked_;
    std::set<core::Region> group_,activate_pending_,visual_invalidated_,construction_pending_;
    std::uint64_t wet_preflights_{},wet_preflight_rejections_{},construction_commits_{};
    hybrid::LayeredInputCache surface_cache_;
    EditProvenance provenance_;
    std::set<core::Region> pending_survey_,pending_stream_;
    std::optional<StreamSnapshotJob> stream_job_;
    StreamBlockCache stream_cache_;
    std::uint64_t stream_steps_{},stream_cached_blocks_{},stream_max_step_us_{},stream_retry_frames_{},pristine_stream_starts_{};
    std::uint64_t visual_survey_tiles_{},post_edit_survey_tiles_{},suspended_reclaims_{};
    std::uint64_t stream_survey_tiles_{},stream_found_blocks_{},stream_generated_blocks_{},stream_read_failures_{};
    std::vector<std::uint64_t> tick_samples_,voxel_copy_samples_,classification_samples_;
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
    bool near_player(core::Region k)const {
        return std::abs(k.x-center_.x)<=side&&std::abs(k.z-center_.z)<=side;
    }
    bool visible(core::Region k)const {
        return std::abs(k.x-center_.x)<=view_distance_+side&&std::abs(k.z-center_.z)<=view_distance_+side;
    }
    // Ocean topology work may acquire geometry, but cannot pin a local
    // physics owner outside the actual simulation interest.
    bool physics_interested(core::Region k)const {
        if(dirty_.contains(k)||source_interest_.contains(k))return true;
        if(std::abs(k.x-center_.x)<=side&&std::abs(k.z-center_.z)<=side)return true;
        if(std::abs(k.x-center_.x)>view_distance_+side||std::abs(k.z-center_.z)>view_distance_+side)return false;
        for(auto d:{core::Region{0,0,0},core::Region{-16,0,0},core::Region{16,0,0},core::Region{0,0,-16},core::Region{0,0,16}}) {
            core::Region n{k.x+d.x,base,k.z+d.z};
            // Stable aggregate ocean mass is not a local flow front.
            // A neighboring ACTIVE local solver is the only physical
            // expansion trigger; ocean topology/visualization is read-only.
            if(auto it=model_.tiles().find(n);it!=model_.tiles().end()&&it->second.local)return true;
        }
        return false;
    }
    bool interested(core::Region k)const {
        return physics_interested(k)||ocean_interest_.contains(k);
    }
    bool source_certified(core::Region k,std::uint64_t rev,const godot::Ref<godot::VoxelTool>& tool)const {
        const auto it=model_.tiles().find(k);
        return it!=model_.tiles().end()&&!dirty_.contains(k)&&
            (provenance_.certifies(k,it->second.geometry->revision,rev)||(it->second.resident&&resident(tool,k)));
    }
    // All reached ownership is preflighted on a copy of the bounded hot
    // domain. Newly seeded non-hot regions become exact disk owners
    // without ever consuming a physical slot. Session intent is the
    // existing crash gate; a failed write poisons the cold store.
    bool commit_basin(const experiment::FiniteBasinSurvey& survey,std::size_t type,std::uint64_t rev) {
        const auto start=std::chrono::steady_clock::now();
        auto staged=model_;
        struct Record {core::Region key;nlohmann::json geometry,owner;Litres mass;};
        std::vector<Record> records;
        Litres total=0;
        for(const auto &[k,contents]:survey.reached()){
            const auto &g=survey.geometry().at(k);
            if(!certified_geometry(k,*g,rev)||cold_contains(k))return false;
            if(auto it=staged.tiles().find(k);it!=staged.tiles().end()){
                if(it->second.local||it->second.geometry->revision!=g->revision)return false;
                for(const auto &[id,amount]:contents)if(!staged.seed(k,id,type,amount))return false;
            }else{
                if(!cold_store_)return false;
                auto row=staged.stage_cold_seed(g,type,contents);
                if(!row)return false;
                experiment::CoupledTile witness;witness.geometry=g;
                records.push_back({k,encode_geometry(k,witness,true),std::move(row->first),row->second});
            }
            for(const auto &[id,amount]:contents){(void)id;total+=amount;}
        }
        if(staged.initial()-model_.initial()!=total||staged.mass()-model_.mass()!=total)return false;
        try{
            for(const auto &record:records)cold_store_->put(record.key,record.geometry,record.owner,record.mass);
            if(cold_store_&&!cold_store_->consistent(staged.cold_count(),staged.cold_mass()))throw std::logic_error("finite basin cold ledger");
            model_=std::move(staged);
        }catch(...){if(cold_store_)cold_store_->poison();throw;}
        cold_scan_center_.reset();
        ++basin_completed_;basin_surveyed_tiles_+=survey.geometry().size();
        basin_wet_tiles_+=survey.reached().size();basin_cold_seeds_+=records.size();basin_initial_litres_+=total;
        basin_commit_max_us_=std::max(basin_commit_max_us_,static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count()));
        return true;
    }
    void discover_sources(const nlohmann::json& rules,std::uint64_t rev,const godot::Ref<godot::VoxelTool>& tool,core::Vec3 position) {
        source_interest_.clear();visible_sources_pending_=0;finite_pending_=false;
        for(const auto &rule:rules){
            const auto id=rule.at("id").get<std::string>();
            if(sources_.contains(id))continue;
            const auto &a=rule.at("anchor_m");
            const core::Vec3 anchor{a[0].get<double>()+0.5,a[1].get<double>()+0.5,a[2].get<double>()+0.5};
            const auto k=key(anchor);
            // Visible mod anchors are surveyed regardless of LOD0 residency.
            // Only an anchor/window is scheduled, not every tile in the view.
            const bool ocean=rule.at("source_kind")=="fixed_head_ocean";
            const bool in_view=std::hypot(anchor.x-position.x,anchor.z-position.z)<=view_distance_;
            if(!in_view&&!ocean){source_windows_.erase(id);source_attempts_.erase(id);basin_surveys_.erase(id);continue;}
            if(in_view)++visible_sources_pending_;
            const bool volume=rule.contains("volume_litres");
            // A finite level source is surveyed incrementally. Only the
            // unresolved frontier is pinned, not the whole proof.
            if(!ocean&&!volume){
                finite_pending_=true;
                auto survey=basin_surveys_.find(id);
                if(survey!=basin_surveys_.end()&&survey->second.revision()!=rev){basin_surveys_.erase(survey);survey=basin_surveys_.end();}
                if(survey!=basin_surveys_.end()){
                    auto &job=survey->second;
                    std::vector<core::Region> wanted(job.wanted().begin(),job.wanted().end());
                    for(std::size_t n=0;n<std::min<std::size_t>(4,wanted.size());++n){
                        const auto q=wanted[n];
                        if(source_certified(q,rev,tool)&&certified_geometry(q,*model_.tiles().at(q).geometry,rev))
                            job.offer(model_.tiles().at(q).geometry);
                        else if(cold_contains(q)){
                            auto g=decode_geometry(cold_store_->get(q).at("geometry"));
                            if(certified_geometry(q,*g,rev))job.offer(std::move(g));
                        }else source_interest_.insert(q);
                    }
                    job.step();
                    if(job.invalid()){source_conflicts_.insert(id);source_diagnostics_[id]="finite basin invalid or open at world boundary";continue;}
                    if(job.complete()){
                        if(commit_basin(job,rule.at("slot").get<std::size_t>(),rev)){
                            if(!resident(tool,k))++nonresident_source_discoveries_;
                            sources_.insert(id);source_conflicts_.erase(id);source_diagnostics_.erase(id);
                            source_windows_.erase(id);source_attempts_.erase(id);basin_surveys_.erase(survey);
                            if(in_view)--visible_sources_pending_;
                        }else{source_conflicts_.insert(id);source_diagnostics_[id]="finite basin conflicts with existing owner or revision";}
                    }
                    continue;
                }
            }
            auto &window=source_windows_[id];
            if(window.empty())window.insert(k);
            source_interest_.insert(window.begin(),window.end());
            if(!dirty_.empty()||!std::all_of(window.begin(),window.end(),[&](auto q){return source_certified(q,rev,tool);}))continue;
            // Retry on new certification, terrain revision or a bounded
            // simulation cadence if a competing front currently owns it.
            const auto stamp=std::tuple{publications_,ticks_/20,rev};
            if(source_attempts_.contains(id)&&source_attempts_.at(id)==stamp)continue;
            source_attempts_[id]=stamp;
            const auto &g=*model_.tiles().at(k).geometry;
            const double level=volume?std::numeric_limits<double>::infinity():rule.at("level_m").get<double>();
            const auto amount=volume?rule.at("volume_litres").get<Litres>():0;
            std::optional<core::Vec3> chosen;Id compartment_id{};
            double best=std::numeric_limits<double>::infinity(),min_floor=std::numeric_limits<double>::infinity();
            for(const auto &col:g.column_runs)for(const auto &s:col){
                const double floor=tp::span_floor_mm(g,s)*0.001;
                if(s.top!=height)continue;
                min_floor=std::min(min_floor,floor);
                if(floor+0.1>=level)continue;
                if(volume){
                    auto c=std::find_if(g.compartments.begin(),g.compartments.end(),[&](const auto &v){return v.id==s.compartment;});
                    if(c==g.compartments.end()||c->curve.capacity()<amount)continue;
                }
                core::Vec3 q{k.x+s.x+0.5,floor+0.05,k.z+s.z+0.5};
                const double distance=(q.x-anchor.x)*(q.x-anchor.x)+(q.z-anchor.z)*(q.z-anchor.z);
                if(distance<best){best=distance;chosen=q;compartment_id=s.compartment;}
            }
            if(!chosen){source_conflicts_.insert(id);source_diagnostics_[id]="no eligible exposed anchor; min_floor="+std::to_string(min_floor);continue;}
            const auto type=rule.at("slot").get<std::size_t>();
            bool accepted=false;
            if(ocean)accepted=model_.ocean({id,k,*chosen,type,level,chosen->y,4});
            else if(volume)accepted=model_.seed(k,compartment_id,type,amount);
            else{
                if(!certified_geometry(k,g,rev))continue;
                auto [job,inserted]=basin_surveys_.try_emplace(id,k,compartment_id,level,base+height,rev);
                (void)inserted;
                job->second.offer(model_.tiles().at(k).geometry);job->second.step();
                continue;
            }
            if(accepted){if(!model_.tiles().at(k).resident)++nonresident_source_discoveries_;if(in_view)--visible_sources_pending_;if(ocean)ocean_changed(k);sources_.insert(id);source_windows_.erase(id);source_attempts_.erase(id);source_conflicts_.erase(id);source_diagnostics_.erase(id);}
            else {source_conflicts_.insert(id);source_diagnostics_[id]="wet/local owner or invalid capacity at certified anchor";}
        }
    }
    static std::array<core::Region,4> adjacent(core::Region k) {
        return {{{k.x-side,base,k.z},{k.x+side,base,k.z},{k.x,base,k.z-side},{k.x,base,k.z+side}}};
    }
    void ocean_changed(core::Region k) {
        if(model_.oceans().empty())return;
        if(model_.tiles().contains(k))ocean_dirty_.insert(k);
        for(auto q:adjacent(k))if(model_.tiles().contains(q))ocean_dirty_.insert(q);
    }
    bool certified_geometry(core::Region k,const tp::Result& g,std::uint64_t rev)const {
        return !dirty_.contains(k)&&provenance_.certifies(k,g.revision,rev);
    }
    // Maintain only a bounded hot work queue plus current visible proof
    // witnesses. A global revision change invalidates every older path.
    // No search over all previously visited regions.
    void advance_ocean(std::uint64_t rev) {
        if(model_.oceans().empty()){ocean_interest_.clear();ocean_dirty_.clear();return;}
        if(!ocean_revision_||*ocean_revision_!=rev){
            ocean_revision_=rev;ocean_dirty_.clear();ocean_examined_.clear();ocean_interest_.clear();
            for(const auto &[k,t]:model_.tiles()){(void)t;ocean_dirty_.insert(k);}
        }
        if(!ocean_search_center_||*ocean_search_center_!=center_){
            ocean_search_center_=center_;ocean_examined_.clear();
        }
        auto distance=[&](core::Region k){return std::abs(k.x-center_.x)+std::abs(k.z-center_.z);};
        for(int budget=0;budget<4&&!ocean_dirty_.empty();++budget){
            auto next=std::min_element(ocean_dirty_.begin(),ocean_dirty_.end(),[&](auto a,auto b){return distance(a)<distance(b);});
            const auto k=*next;ocean_dirty_.erase(next);
            const auto it=model_.tiles().find(k);
            if(it==model_.tiles().end()||!certified_geometry(k,*it->second.geometry,rev))continue;
            const auto &g=*it->second.geometry;
            for(const auto &source:model_.oceans()){
                std::optional<Id> root;
                if(source.tile==k)root=tp::compartment_at(g,source.anchor);
                std::vector<experiment::OceanReach::Neighbor> neighbors;
                for(auto q:adjacent(k)){
                    if(auto n=model_.tiles().find(q);n!=model_.tiles().end()){
                        const auto p=n->second.ocean_reach.find(source.id);
                        if(p!=n->second.ocean_reach.end()&&certified_geometry(q,*n->second.geometry,rev))neighbors.emplace_back(n->second.geometry.get(),&p->second);
                    }else if(auto v=cold_visible_.find(q);v!=cold_visible_.end()&&cold_ocean_.contains(q)){
                        const auto &proofs=cold_ocean_.at(q);const auto p=proofs.find(source.id);
                        if(p!=proofs.end()&&certified_geometry(q,*v->second.geometry,rev))neighbors.emplace_back(v->second.geometry.get(),&p->second);
                    }
                }
                auto proof=experiment::OceanReach::extend(source.id,source.head,base+height,rev,g,root,neighbors);
                const auto previous=it->second.ocean_reach.find(source.id);
                if(previous!=it->second.ocean_reach.end()&&previous->second.matches(g,rev)){
                    proof.compartments.insert(previous->second.compartments.begin(),previous->second.compartments.end());
                    if(proof.compartments==previous->second.compartments)continue;
                }
                if(proof.compartments.empty())continue;
                // A same-revision source path certifies every submerged
                // portal. Pristine target tiles can be acquired even after
                // unrelated terrain edits; edited owners retain real mass
                // and must fill by flow, never by reinitialization.
                // The certified source tile is also a real wet tile. Do not
                // leave a square dry hole under an otherwise full ocean.
                // acquire_ocean is idempotent and never overwrites an
                // existing owner: it explicitly ledgers only additions.
                if(!it->second.local&&provenance_.pristine(k,rev)){
                    if(!model_.acquire_ocean(proof,rev,true))continue;
                    ++ocean_acquisitions_;
                }else if(!model_.remember_ocean(proof,rev))continue;
                ++ocean_certifications_;
                for(auto q:adjacent(k))if(model_.tiles().contains(q))ocean_dirty_.insert(q);
            }
            if(ocean_interest_.contains(k))ocean_examined_.insert(k);
        }
        // Explore only toward the current view (or within it), not toward
        // the whole unbounded world. Limit remote search work per view.
        std::map<core::Region,core::Region> frontier;
        auto add_frontier=[&](const tp::Result& g,const auto& proofs){
            for(const auto &[id,proof]:proofs){
                (void)id;if(!proof.matches(g,rev))continue;
                for(auto q:proof.frontier(g)){
                    if(!core::valid_point({double(q.x),double(q.y),double(q.z)})||
                        model_.tiles().contains(q)||cold_visible_.contains(q)||ocean_examined_.contains(q))continue;
                    // Spatial interest, not a fixed number of wet tiles, bounds
                    // the proof work; per-frame acquisition is still capped.
                    if(!visible(q)&&distance(q)>=distance(g.origin))continue;
                    frontier.try_emplace(q,g.origin);
                }
            }
        };
        for(const auto &[k,t]:model_.tiles())if(certified_geometry(k,*t.geometry,rev))add_frontier(*t.geometry,t.ocean_reach);
        for(const auto &[k,proofs]:cold_ocean_){
            auto v=cold_visible_.find(k);if(v!=cold_visible_.end()&&certified_geometry(k,*v->second.geometry,rev))add_frontier(*v->second.geometry,proofs);
        }
        std::vector<core::Region> ordered;for(const auto &[k,parent]:frontier){(void)parent;ordered.push_back(k);}
        std::sort(ordered.begin(),ordered.end(),[&](auto a,auto b){return distance(a)<distance(b);});
        ocean_interest_.clear();
        for(std::size_t i=0;i<std::min<std::size_t>(4,ordered.size());++i){
            ocean_interest_.insert(ordered[i]);ocean_interest_.insert(frontier.at(ordered[i]));
        }
        // Pin at most the four queued remote topology candidates, not the
        // entire dirty set after a revision change. Never pin a distant local
        // physics owner just because its geometry awaits a certificate.
        std::vector<core::Region> remote_pending;
        for(auto k:ocean_dirty_)if(model_.tiles().contains(k)&&!visible(k)&&!model_.tiles().at(k).local)
            remote_pending.push_back(k);
        std::sort(remote_pending.begin(),remote_pending.end(),[&](auto a,auto b){return distance(a)<distance(b);});
        for(std::size_t i=0;i<std::min<std::size_t>(4,remote_pending.size());++i)ocean_interest_.insert(remote_pending[i]);
    }
    static nlohmann::json encode_geometry(core::Region k,const experiment::CoupledTile& t,bool retain_render) {
        using J=nlohmann::json;
        const auto &g=*t.geometry;J runs=J::array();
        for(const auto &col:g.column_runs)for(const auto &s:col)runs.push_back({s.x,s.z,s.bottom,s.top});
        J row={{"key",{k.x,k.y,k.z}},{"revision",g.revision},{"runs",runs},{"floor",g.surface_floor},{"refined",g.refine_exposed}};
        if(!g.render_sdf.empty()&&(retain_render)){
            constexpr char hex[]="0123456789abcdef";
            std::string packed;packed.reserve(g.render_sdf.size()*4);
            for(auto v:g.render_sdf){const auto u=static_cast<std::uint16_t>(v);for(int shift:{12,8,4,0})packed.push_back(hex[(u>>shift)&15]);}
            row["render_sdf"]=std::move(packed);row["render_pad"]=g.render_pad;
        }
        if(!g.halo_runs.empty()){
            J hr=J::array();for(const auto &col:g.halo_runs)for(const auto &s:col)hr.push_back({s.x,s.z,s.bottom,s.top});
            row["halo_runs"]=std::move(hr);row["halo_floor"]=g.halo_floor;
        }
        return row;
    }
    static std::shared_ptr<const tp::Result> decode_geometry(const nlohmann::json& row) {
        const auto &a=row.at("key");core::Region k{a[0].get<int>(),a[1].get<int>(),a[2].get<int>()};
        if(k.y!=base||k.x%16||k.z%16||row.at("runs").size()>16384)throw std::invalid_argument("hybrid archive geometry");
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
        return std::make_shared<const tp::Result>(tp::extract(s));
    }
    static std::optional<hybrid::Input> owner_input(core::Region k,const experiment::CoupledTile& t) {
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
    }
    void clear_cold_visual(core::Region k) {
        cold_ocean_.erase(k);
        if(cold_visible_.erase(k))visual_invalidated_.insert(k);
    }
    // Bounded spatial scan: no global directory enumeration or cold owner index.
    // At most 16 probes and one record decode per frame; near physics is separate.
    void acquire_cold_visual(std::uint64_t rev) {
        for(auto it=cold_visible_.begin();it!=cold_visible_.end();){
            if(!visible(it->first)||!provenance_.certifies(it->first,it->second.geometry->revision,rev)){
                cold_ocean_.erase(it->first);visual_invalidated_.insert(it->first);it=cold_visible_.erase(it);
            }else ++it;
        }
        if(!cold_store_||!model_.cold_count())return;
        const int radius=static_cast<int>(std::ceil(view_distance_/side))+1;
        if(!cold_scan_center_||*cold_scan_center_!=center_||cold_scan_radius_!=radius){
            cold_scan_center_=center_;cold_scan_radius_=radius;cold_scan_cursor_=0;
        }
        const auto width=static_cast<std::size_t>(radius*2+1);
        for(int probe=0;probe<16&&cold_scan_cursor_<width*width;++probe){
            const auto cursor=cold_scan_cursor_++;
            const core::Region k{center_.x+(static_cast<int>(cursor%width)-radius)*side,base,
                center_.z+(static_cast<int>(cursor/width)-radius)*side};
            if(!visible(k)||near_player(k)||model_.tiles().contains(k)||cold_visible_.contains(k)||
                !core::valid_point({double(k.x),double(k.y),double(k.z)})||!cold_contains(k))continue;
            const auto row=cold_store_->get(k);
            auto geometry=decode_geometry(row.at("geometry"));
            if(!provenance_.certifies(k,geometry->revision,rev))continue;
            auto decoded=model_.inspect_cold(std::move(geometry),row.at("owner"));
            if(!decoded||decoded->second!=row.at("mass").get<Litres>())throw std::logic_error("cold visual owner");
            if(auto input=owner_input(k,decoded->first)){
                cold_visible_.emplace(k,std::move(*input));
                if(!decoded->first.ocean_reach.empty())cold_ocean_.insert_or_assign(k,decoded->first.ocean_reach);
                ocean_changed(k);visual_invalidated_.insert(k);
            }
            ++cold_visual_reads_;break;
        }
    }
    bool cold_contains(core::Region k)const {
        return cold_store_&&model_.cold_count()&&cold_store_->contains(k);
    }
    bool reclaimable(core::Region k,bool pressure=false)const {
        return model_.can_archive(k)&&!dirty_.contains(k)&&!pending_.contains(k)&&
            !near_player(k)&&!source_interest_.contains(k)&&!ocean_interest_.contains(k)&&(!interested(k)||pressure)&&
            ((!model_.tile_mass(k)&&!model_.tiles().at(k).local)||cold_store_);
    }
    bool archive_owner(core::Region k,bool pressure=false) {
        if(!cold_store_||!reclaimable(k,pressure))return false;
        const auto amount=model_.tile_mass(k);
        try{
            const auto &t=model_.tiles().at(k);
            auto visual=visible(k)?owner_input(k,t):std::nullopt;
            auto reach=t.ocean_reach;
            cold_store_->put(k,encode_geometry(k,t,true),model_.encode_tile(k),amount);
            if(!model_.detach_cold(k)||!cold_store_->consistent(model_.cold_count(),model_.cold_mass()))
                throw std::logic_error("cold detach ledger");
            if(visual){cold_visible_.insert_or_assign(k,std::move(*visual));if(!reach.empty())cold_ocean_.insert_or_assign(k,std::move(reach));visual_invalidated_.insert(k);}
            ocean_dirty_.erase(k);
            ++cold_evictions_;return true;
        }catch(...){cold_store_->poison();throw;}
    }
    bool reclaim_slot() {
        for(const auto &[k,t]:model_.tiles())if(reclaimable(k)&&!t.local&&!model_.tile_mass(k))
            return model_.forget_dry(k);
        for(const auto &[k,t]:model_.tiles()){(void)t;if(reclaimable(k))return archive_owner(k);}
        for(const auto &[k,t]:model_.tiles())if(reclaimable(k,true)&&!t.local&&!model_.tile_mass(k))
            return model_.forget_dry(k);
        for(const auto &[k,t]:model_.tiles()){(void)t;if(reclaimable(k,true))return archive_owner(k,true);}
        return false;
    }
    bool restore_owner(core::Region k,std::uint64_t rev) {
        if(!cold_contains(k)||dirty_.contains(k))return false;
        try{
            const auto row=cold_store_->get(k);
            const auto &owner=row.at("owner");
            if(owner.at("local").get<bool>()&&model_.active()>=model_.active_limit())return false;
            auto geometry=decode_geometry(row.at("geometry"));
            // Old hydraulic geometry is a derived checkpoint, not terrain.
            // A missing current revision certificate must not publish it.
            if(geometry->origin!=k||!provenance_.certifies(k,geometry->revision,rev))return false;
            if(model_.tiles().size()>=model_.tile_limit()&&!reclaim_slot())return false;
            if(!model_.restore_cold(std::move(geometry),owner))throw std::logic_error("cold restore owner");
            cold_store_->erase(k,row.at("mass").get<Litres>());
            if(!cold_store_->consistent(model_.cold_count(),model_.cold_mass()))throw std::logic_error("cold restore ledger");
            clear_cold_visual(k);
            ocean_changed(k);
            ++cold_restores_;++publications_;return true;
        }catch(...){cold_store_->poison();throw;}
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
    void configure_cold_store(const std::filesystem::path& world) {
        if(cold_store_)throw std::logic_error("cold store already configured");
        cold_store_=std::make_unique<persistence::HydraulicRegionStore>(world,model_.cold_count(),model_.cold_mass());
    }
    void checkpoint_cold_store() {
        if(cold_store_)cold_store_->checkpoint(model_.cold_count(),model_.cold_mass());
        else if(model_.cold_count())throw std::logic_error("cold store absent");
    }
    bool allows_edit(core::Vec3 p,double radius,bool add,const godot::Ref<godot::VoxelTool>& tool,std::uint64_t next_revision,bool exact_brush) {
        if(!core::valid_point(p)||!std::isfinite(radius)||radius<0.5||radius>8)return false;
        std::size_t needed=0,new_tiles=0;
        const auto keys=affected(p,radius);
        // Never mutate terrain whose cold hydraulic owner has not been loaded.
        for(auto k:keys)if(cold_contains(k))return false;
        bool near_wet=false;
        for(auto k:keys)if(model_.tiles().contains(k)&&model_.tile_mass(k))near_wet=true;
        for(auto k:keys) {
            auto it=model_.tiles().find(k);
            if(it==model_.tiles().end()) {if(near_wet){++needed;++new_tiles;}continue;}
            if(!it->second.resident||dirty_.contains(k))return false;
            if(near_wet&&!it->second.local)++needed;
        }
        if(needed+model_.active()>model_.active_limit()||new_tiles+model_.tiles().size()>model_.tile_limit())return false;
        if(!near_wet)return true;
        ++wet_preflights_;
        auto reject=[&](){++wet_preflight_rejections_;return false;};
        if(!exact_brush||tool.is_null()||!dirty_.empty()||next_revision!=revision_+1)return reject();
        // Bounded, edit-only staging; immutable geometry shared. No
        // live owner changes on a rejected or deferred terrain command.
        auto staged=model_;
        for(auto k:keys)if(staged.tiles().contains(k)&&!staged.tiles().at(k).local&&!staged.activate(k))return reject();
        const BrushPreview preview{godot::Vector3(p.x,p.y,p.z),radius,add};
        for(auto k:keys)if(staged.tiles().contains(k)){
            auto snapshot=copy_air_snapshot(tool,godot::Vector3i(k.x,k.y,k.z),godot::Vector3i(side,height,side),next_revision,true,false,&preview);
            if(!snapshot)return reject();
            auto geometry=std::make_shared<const tp::Result>(tp::extract(*snapshot));
            if(!staged.replace_geometry(geometry,add))return reject();
        }
        if(staged.mass()!=model_.mass())throw std::logic_error("hydraulic preflight ledger");
        return true;
    }
    void edited(core::Vec3 p,double radius,std::uint64_t rev,bool add) {
        if(dirty_.empty())group_.clear();
        revision_=rev;
        const auto keys=affected(p,radius);
        provenance_.record(rev,keys);
        bool near_wet=false;for(auto k:keys)if(model_.tiles().contains(k)&&model_.tile_mass(k))near_wet=true;
        // Accepted command only. The old hydraulic geometry is immutable
        // until the authoritative post-edit snapshots are published.
        if(near_wet)for(auto k:keys)if(model_.tiles().contains(k)&&!activate(k))
            throw std::logic_error("preflight activation mismatch");
        if(add&&near_wet)++construction_commits_;
        for(auto k:keys) {
            if(add&&near_wet&&model_.tiles().contains(k))construction_pending_.insert(k);
            visual_invalidated_.insert(k);
            if(model_.tiles().contains(k)){dirty_[k]=rev;group_.insert(k);model_.set_resident(k,false);}
            else if(near_wet){dirty_[k]=rev;group_.insert(k);activate_pending_.insert(k);}
            worker_.invalidate(k);pending_.erase(k);pending_survey_.erase(k);pending_stream_.erase(k);blocked_.erase(k);
            if(stream_job_&&stream_job_->key()==k)stream_job_.reset();
        }
    }
    void frame(const godot::Ref<godot::VoxelTool>& tool,core::Vec3 p,std::uint64_t rev,std::uint64_t elapsed,const nlohmann::json& rules,const StreamSnapshotSource& stream,double view_distance) {
        center_=key(p);
        if(provenance_.revision()!=rev)provenance_.invalidate(rev);
        view_distance_=std::clamp(view_distance,16.0,4096.0);
        discover_sources(rules,rev,tool,p);
        // Do not bulk-initialize an ocean over an uncommitted finite basin.
        if(!finite_pending_)advance_ocean(rev);
        for(const auto &[k,t]:model_.tiles())if(t.resident&&(!physics_interested(k)||!resident(tool,k))){
            model_.set_resident(k,false);
            if(!dirty_.contains(k)&&model_.reclaim_suspended(k)){++suspended_reclaims_;++settles_;}
        }
        // One distant wet/local owner can leave the hot set per frame.
        // Keep everything in the visible interest and all source anchors.
        if(cold_store_)for(const auto &[k,t]:model_.tiles()){
            if((t.local||model_.tile_mass(k))&&reclaimable(k)){archive_owner(k);break;}
        }
        if(auto result=worker_.poll()) {
            const auto k=result->origin;pending_.erase(k);
            const bool surveyed=pending_survey_.erase(k)>0;
            const bool streamed=pending_stream_.erase(k)>0;
            const bool loaded=resident(tool,k);
            const bool certified=(surveyed&&!dirty_.contains(k)&&result->revision==0&&provenance_.pristine(k,rev))||
                (streamed&&result->revision<=stream.durable_revision&&provenance_.certifies(k,result->revision,rev));
            if(interested(k)&&(loaded||certified)&&(!(surveyed||streamed)||certified)&&(!dirty_.contains(k)||result->revision>=dirty_.at(k))) {
                auto geometry=std::make_shared<const tp::Result>(std::move(*result));
                const bool exists=model_.tiles().contains(k);
                if(!exists&&cold_contains(k))throw std::logic_error("snapshot would overwrite cold owner");
                if(!exists&&model_.tiles().size()>=model_.tile_limit())reclaim_slot();
                if(exists?model_.replace_geometry(geometry,construction_pending_.contains(k)):model_.publish(geometry)) {
                    if(activate_pending_.contains(k)&&!activate(k)){
                        model_.set_resident(k,false);blocked_[k]=rev;
                    }else {
                        if(!loaded||!physics_interested(k))model_.set_resident(k,false);
                        if(!loaded){++visual_survey_tiles_;if(rev)++post_edit_survey_tiles_;}
                        if(streamed)++stream_survey_tiles_;
                        activate_pending_.erase(k);construction_pending_.erase(k);dirty_.erase(k);blocked_.erase(k);++publications_;ocean_changed(k);
                    }
                }else blocked_[k]=rev;
            }
        }
        // Same Voxel Tools snapshots as H14; one acquisition per frame,
        // cached wet geometry survives loss of LOD0 residency.
        std::set<core::Region> candidates=source_interest_;
        candidates.insert(ocean_interest_.begin(),ocean_interest_.end());
        for(const auto &[k,r]:dirty_){(void)r;candidates.insert(k);}
        for(int x=-1;x<=1;++x)for(int z=-1;z<=1;++z)candidates.insert({center_.x+x*16,base,center_.z+z*16});
        for(const auto &[k,t]:model_.tiles())if(model_.tile_mass(k)||t.local)
            for(auto d:{core::Region{0,0,0},core::Region{-16,0,0},core::Region{16,0,0},core::Region{0,0,-16},core::Region{0,0,16}}) {
                core::Region q{k.x+d.x,base,k.z+d.z};if(interested(q))candidates.insert(q);
            }
        std::vector<core::Region> ordered(candidates.begin(),candidates.end());
        std::sort(ordered.begin(),ordered.end(),[&](auto a,auto b){
            if(dirty_.contains(a)!=dirty_.contains(b))return dirty_.contains(a);
            if(finite_pending_&&source_interest_.contains(a)!=source_interest_.contains(b))return source_interest_.contains(a);
            return std::abs(a.x-center_.x)+std::abs(a.z-center_.z)<std::abs(b.x-center_.x)+std::abs(b.z-center_.z);
        });
        // Restore an exact persisted owner before acquiring any replacement
        // geometry. Near-player, wet-front and source-window candidates
        // share the same bounded priority queue.
        if(model_.cold_count())for(auto k:ordered){
            if(!model_.tiles().contains(k)&&(near_player(k)||source_interest_.contains(k)||ocean_interest_.contains(k)||resident(tool,k))&&cold_contains(k)){
                if(restore_owner(k,rev))break;
            }
        }
        acquire_cold_visual(rev);
        // Drop a partial snapshot when its certificate or interest changes.
        if(stream_job_&&(!stream.valid()||stream_job_->durable_revision()!=stream.durable_revision||
            !interested(stream_job_->key())||!provenance_.certifies_halo(stream_job_->key(),stream_job_->revision(),rev)))stream_job_.reset();
        if(stream_retry_frames_)--stream_retry_frames_;
        bool acquired=false;
        if(pending_.size()<2)for(int pass=0;pass<2&&!acquired;++pass){
            if(pass==1&&stream_job_){
                const auto begin=std::chrono::steady_clock::now();
                // Main-thread work is bounded by elapsed time, not a
                // single block per frame. Cached 16^3 blocks can advance
                // together; generating a new block stops the batch after
                // its first expensive step. This reuses Voxel Tools'
                // canonical stream and generator, never a second terrain.
                for(int batch=0;batch<8&&!stream_job_->done();++batch){
                    stream_job_->step(&stream_cache_);++stream_steps_;
                    if(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-begin).count()>=4000)break;
                }
                if(stream_job_->done()){
                    const auto k=stream_job_->key();const auto wanted_revision=stream_job_->revision();
                    const auto stats=stream_job_->stats();stream_found_blocks_+=stats.found;stream_generated_blocks_+=stats.generated;stream_cached_blocks_+=stats.cached;
                    auto snapshot=stream_job_->finish();
                    if(snapshot&&worker_.submit(std::move(*snapshot))){pending_[k]=wanted_revision;pending_stream_.insert(k);}
                    else {++stream_read_failures_;stream_retry_frames_=20;}
                    stream_job_.reset();
                }
                const auto us=static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-begin).count());
                stream_max_step_us_=std::max(stream_max_step_us_,us);max_snapshot_us_=std::max(max_snapshot_us_,us);
                break;
            }
            for(auto k:ordered) {
            auto it=model_.tiles().find(k);
            if(it!=model_.tiles().end()&&it->second.resident&&!dirty_.contains(k))continue;
            if(pending_.contains(k)||(blocked_.contains(k)&&blocked_.at(k)==rev)||cold_contains(k))continue;
            const bool loaded=resident(tool,k);
            // A certified hot owner used only as an ocean witness does not
            // require another live snapshot every frame.
            if(it!=model_.tiles().end()&&!physics_interested(k)&&certified_geometry(k,*it->second.geometry,rev))continue;
            // Prefer a durable, revision- and halo-certified read of the
            // existing VoxelStream/generator for unchanged geometry.
            // A live unsaved terrain edit never takes this path.
            const bool stream_safe=!stream_retry_frames_&&stream.valid()&&!dirty_.contains(k)&&
                provenance_.certifies_halo(k,stream.durable_revision,rev)&&
                (it==model_.tiles().end()||it->second.geometry->render_sdf.empty());
            const bool survey=!loaded&&pass==1&&!stream_safe&&it==model_.tiles().end()&&
                provenance_.pristine(k,rev);
            const bool archived=pass==1&&stream_safe;
            if((pass==0&&(!loaded||stream_safe))||(pass==1&&!survey&&!archived))continue;
            if(it==model_.tiles().end()&&model_.tiles().size()>=model_.tile_limit()) {
                bool can_reclaim=false;for(const auto &[q,t]:model_.tiles()){(void)t;if(reclaimable(q,true)){can_reclaim=true;break;}}
                if(!can_reclaim)continue;
            }
            const auto start=std::chrono::steady_clock::now();
            const auto wanted_revision=survey?0:archived?stream.durable_revision:dirty_.contains(k)?dirty_.at(k):it!=model_.tiles().end()?it->second.geometry->revision:rev;
            if(archived){
                stream_job_.emplace(stream,godot::Vector3i(k.x,k.y,k.z),godot::Vector3i(side,height,side),wanted_revision);
                ++pristine_stream_starts_;
                acquired=true;break;
            }
            SnapshotTiming timing;
            auto s=copy_air_snapshot(tool,godot::Vector3i(k.x,k.y,k.z),godot::Vector3i(side,height,side),wanted_revision,true,survey,nullptr,&timing);
            if(voxel_copy_samples_.size()<4096){voxel_copy_samples_.push_back(timing.voxel_copy_us);classification_samples_.push_back(timing.classification_us);}
            max_snapshot_us_=std::max(max_snapshot_us_,static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count()));
            if(s&&worker_.submit(std::move(*s))){pending_[k]=wanted_revision;if(survey)pending_survey_.insert(k);acquired=true;break;}
            }
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
            if(dirty_.contains(k))return nullptr;
            if(it!=model_.tiles().end())return it->second.geometry;
            const auto cold=cold_visible_.find(k);
            return cold==cold_visible_.end()?nullptr:cold->second.geometry;
        };
        auto primary=[&](core::Region k)->std::optional<hybrid::Input>{
            if(auto cold=cold_visible_.find(k);cold!=cold_visible_.end())return cold->second;
            if(!geometry(k)||!model_.tile_mass(k))return std::nullopt;
            const auto &t=model_.tiles().at(k);
            return owner_input(k,t);
        };
        return surface_cache_.update(changed,side,height,primary,geometry);
    }
    std::uint64_t ticks()const{return ticks_;}
    godot::Array surfaces()const {
        godot::Array rows;int64_t id=1;
        for(const auto &[k,t]:model_.tiles())if(model_.tile_mass(k)) {
            (void)t;godot::Array row;row.push_back(id++);row.push_back(0);row.push_back(0.0);row.push_back(godot::Vector3i(k.x,k.y,k.z));rows.push_back(row);
        }
        for(const auto &[k,input]:cold_visible_){
            (void)input;godot::Array row;row.push_back(id++);row.push_back(0);row.push_back(0.0);row.push_back(godot::Vector3i(k.x,k.y,k.z));rows.push_back(row);
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
        d["visible_sources_pending"]=static_cast<int64_t>(visible_sources_pending_);d["nonresident_source_discoveries"]=static_cast<int64_t>(nonresident_source_discoveries_);d["source_view_distance"]=view_distance_;
        Dictionary reasons;for(const auto &[id,reason]:source_diagnostics_)reasons[String::utf8(id.c_str())]=String::utf8(reason.c_str());d["source_diagnostics"]=reasons;
        d["pristine_survey_tiles"]=static_cast<int64_t>(pristine_survey_tiles_);
        d["visual_survey_tiles"]=static_cast<int64_t>(visual_survey_tiles_);d["post_edit_survey_tiles"]=static_cast<int64_t>(post_edit_survey_tiles_);
        d["stream_survey_tiles"]=static_cast<int64_t>(stream_survey_tiles_);
        d["stream_found_blocks"]=static_cast<int64_t>(stream_found_blocks_);d["stream_generated_blocks"]=static_cast<int64_t>(stream_generated_blocks_);
        d["stream_read_failures"]=static_cast<int64_t>(stream_read_failures_);
        d["stream_cached_blocks"]=static_cast<int64_t>(stream_cached_blocks_);d["stream_steps"]=static_cast<int64_t>(stream_steps_);
        d["stream_max_step_us"]=static_cast<int64_t>(stream_max_step_us_);
        d["pristine_stream_starts"]=static_cast<int64_t>(pristine_stream_starts_);
        d["provenance_complete"]=provenance_.complete();d["edited_provenance_tiles"]=static_cast<int64_t>(provenance_.size());
        d["surface_primary_rebuilds"]=static_cast<int64_t>(surface_cache_.primary_rebuilds());d["surface_input_rebuilds"]=static_cast<int64_t>(surface_cache_.input_rebuilds());
        d["local_active"]=static_cast<int64_t>(model_.active());d["activations"]=static_cast<int64_t>(activations_);d["settles"]=static_cast<int64_t>(settles_);
        d["suspended_reclaims"]=static_cast<int64_t>(suspended_reclaims_);
        d["cold_tiles"]=static_cast<int64_t>(model_.cold_count());d["cold_litres"]=model_.cold_mass();
        d["cold_evictions"]=static_cast<int64_t>(cold_evictions_);d["cold_restores"]=static_cast<int64_t>(cold_restores_);
        d["cold_visual_tiles"]=static_cast<int64_t>(cold_visible_.size());d["cold_visual_reads"]=static_cast<int64_t>(cold_visual_reads_);
        if(cold_store_){
            const auto io=cold_store_->metrics();
            for(const auto &key:{"read_count","read_total_us","read_max_us","read_p95_upper_us","read_bytes",
                "write_count","write_total_us","write_max_us","write_p95_upper_us","write_bytes",
                "erase_count","erase_total_us","erase_max_us"}){
                const std::string label="cold_io_"+std::string(key);
                d[String::utf8(label.c_str())]=static_cast<int64_t>(io.at(key).get<std::uint64_t>());
            }
        }
        d["basin_completed"]=static_cast<int64_t>(basin_completed_);d["basin_surveyed_tiles"]=static_cast<int64_t>(basin_surveyed_tiles_);
        d["basin_wet_tiles"]=static_cast<int64_t>(basin_wet_tiles_);d["basin_cold_seeds"]=static_cast<int64_t>(basin_cold_seeds_);
        d["basin_initial_litres"]=basin_initial_litres_;d["basin_commit_max_us"]=static_cast<int64_t>(basin_commit_max_us_);
        std::size_t surveyed=0,wanted=0;for(const auto &[id,job]:basin_surveys_){(void)id;surveyed+=job.geometry().size();wanted+=job.wanted().size();}
        d["basin_survey_progress"]=static_cast<int64_t>(surveyed);d["basin_frontier_pending"]=static_cast<int64_t>(wanted);
        d["ocean_certifications"]=static_cast<int64_t>(ocean_certifications_);d["ocean_acquisitions"]=static_cast<int64_t>(ocean_acquisitions_);d["ocean_frontier_tiles"]=static_cast<int64_t>(ocean_interest_.size());d["ocean_checked_tiles"]=static_cast<int64_t>(ocean_examined_.size());
        auto samples=tick_samples_;std::sort(samples.begin(),samples.end());
        d["tick_p95_us"]=samples.empty()?0:static_cast<int64_t>(samples[(samples.size()*95-1)/100]);
        d["max_tick_us"]=static_cast<int64_t>(max_tick_us_);d["max_snapshot_us"]=static_cast<int64_t>(max_snapshot_us_);
        auto sample_stats=[](const std::vector<std::uint64_t>& input) {
            std::array<std::uint64_t,3> result{};
            if(input.empty())return result;
            auto values=input;std::sort(values.begin(),values.end());
            result[0]=values[(values.size()*95-1)/100];
            result[1]=values[(values.size()*99-1)/100];
            result[2]=values.back();
            return result;
        };
        const auto copy_stats=sample_stats(voxel_copy_samples_),classify_stats=sample_stats(classification_samples_);
        d["voxel_copy_p95_us"]=static_cast<int64_t>(copy_stats[0]);d["voxel_copy_p99_us"]=static_cast<int64_t>(copy_stats[1]);
        d["voxel_copy_max_us"]=static_cast<int64_t>(copy_stats[2]);
        d["classification_p95_us"]=static_cast<int64_t>(classify_stats[0]);d["classification_p99_us"]=static_cast<int64_t>(classify_stats[1]);
        d["classification_max_us"]=static_cast<int64_t>(classify_stats[2]);
        d["pending_edit_tiles"]=static_cast<int64_t>(dirty_.size());d["blocked_tiles"]=static_cast<int64_t>(blocked_.size());
        d["wet_preflights"]=static_cast<int64_t>(wet_preflights_);d["wet_preflight_rejections"]=static_cast<int64_t>(wet_preflight_rejections_);d["construction_commits"]=static_cast<int64_t>(construction_commits_);
        d["edit_group_revision"]=static_cast<int64_t>(revision_);
        Array group;for(auto k:group_)group.push_back(Vector3i(k.x,k.y,k.z));d["edit_group_tiles"]=group;
        int64_t active=0,near_count=0,wet=0,hot_wet=0,intervals=0,local_bytes=0;
        for(const auto &[k,t]:model_.tiles()){
            if(t.resident){++active;if(std::abs(k.x-center_.x)<=16&&std::abs(k.z-center_.z)<=16)++near_count;}
            if(model_.tile_mass(k)){++hot_wet;if(visible(k))++wet;}
            if(t.local){intervals+=static_cast<int64_t>(t.local->columns().size());local_bytes+=static_cast<int64_t>(t.local->bytes()+t.owners.capacity()*sizeof(Id));}
        }
        d["active_tiles"]=active;d["near_active_tiles"]=near_count;
        d["hot_wet_tiles"]=hot_wet;d["hot_tile_limit"]=static_cast<int64_t>(model_.tile_limit());
        d["visible_wet_tiles"]=wet+static_cast<int64_t>(cold_visible_.size());d["local_intervals"]=intervals;d["local_bytes"]=local_bytes;
        return d;
    }
    nlohmann::json encode()const {
        using J=nlohmann::json;J geometry=J::array(),dirty=J::array(),activate_pending=J::array(),construction_pending=J::array();
        for(const auto &[k,t]:model_.tiles())geometry.push_back(encode_geometry(k,t,model_.tile_mass(k)>0||t.local.has_value()));
        for(const auto &[k,rev]:dirty_)dirty.push_back({k.x,k.y,k.z,rev});
        for(const auto &k:activate_pending_)activate_pending.push_back({k.x,k.y,k.z});
        for(const auto &k:construction_pending_)construction_pending.push_back({k.x,k.y,k.z});
        return {{"schema","v3-hybrid-runtime-1"},{"geometry",geometry},{"coupler",model_.encode()},{"sources",sources_},{"provenance",provenance_.encode()},{"dirty",dirty},{"activate_pending",activate_pending},{"construction_pending",construction_pending},{"revision",revision_},{"ticks",ticks_},{"debt",debt_},{"moved",moved_},{"activations",activations_},{"settles",settles_},{"suspended_reclaims",suspended_reclaims_},{"cold_evictions",cold_evictions_},{"cold_restores",cold_restores_}};
    }
    static std::unique_ptr<IntegratedRuntime> decode(const nlohmann::json& j,const std::vector<Liquid>& types) {
        if(j.at("schema")!="v3-hybrid-runtime-1"||!j.at("geometry").is_array()||j.at("geometry").size()>128)throw std::invalid_argument("hybrid runtime archive");
        std::map<core::Region,std::shared_ptr<const tp::Result>> geometry;
        for(const auto &row:j.at("geometry")){
            auto g=decode_geometry(row);const auto k=g->origin;
            if(!geometry.emplace(k,std::move(g)).second)throw std::invalid_argument("duplicate hydraulic geometry");
        }
        auto model=experiment::Coupler::decode(j.at("coupler"),types,geometry);model.suspend_all();
        auto out=std::make_unique<IntegratedRuntime>(std::move(model),j.at("sources").get<std::set<std::string>>());
        for(const auto &v:j.at("dirty")){core::Region k{v[0].get<int>(),v[1].get<int>(),v[2].get<int>()};if(k.y!=base||k.x%16||k.z%16)throw std::invalid_argument("hybrid dirty tile");out->dirty_[k]=v[3].get<std::uint64_t>();out->group_.insert(k);}
        if(j.contains("activate_pending"))for(const auto &v:j.at("activate_pending")){
            core::Region k{v[0].get<int>(),v[1].get<int>(),v[2].get<int>()};
            if(!out->dirty_.contains(k))throw std::invalid_argument("hybrid pending owner");
            out->activate_pending_.insert(k);
        }
        if(j.contains("construction_pending"))for(const auto &v:j.at("construction_pending")){
            core::Region k{v[0].get<int>(),v[1].get<int>(),v[2].get<int>()};
            if(!out->dirty_.contains(k)||!out->model_.tiles().contains(k))throw std::invalid_argument("hybrid construction pending");
            out->construction_pending_.insert(k);
        }
        out->revision_=j.at("revision").get<std::uint64_t>();
        out->provenance_=EditProvenance::decode(j.value("provenance",nlohmann::json(nullptr)),out->revision_);
        out->ticks_=j.at("ticks").get<std::uint64_t>();
        out->activations_=j.value("activations",std::uint64_t(0));out->settles_=j.value("settles",std::uint64_t(0));
        out->suspended_reclaims_=j.value("suspended_reclaims",std::uint64_t(0));
        out->cold_evictions_=j.value("cold_evictions",std::uint64_t(0));out->cold_restores_=j.value("cold_restores",std::uint64_t(0));
        if(out->suspended_reclaims_>out->settles_)throw std::invalid_argument("hybrid lifecycle counters");
        out->debt_=j.at("debt").get<std::uint64_t>();out->moved_=j.at("moved").get<std::uint64_t>();
        if(out->debt_>100000000)throw std::invalid_argument("hybrid archive tick debt");
        return out;
    }
};
}
