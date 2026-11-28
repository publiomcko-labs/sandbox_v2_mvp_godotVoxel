#include "../../experiments/v3/hybrid/coupler.hpp"
#include "../../experiments/v3/hybrid/finite_basin_survey.hpp"
#include "core/hydraulic_provenance.hpp"
#include <cassert>
#include <iostream>
using namespace sandbox::hydraulic;
using namespace sandbox::hydraulic::experiment;
static std::shared_ptr<const tp::Result> flat(int x,std::uint64_t revision=1) {
    tp::Snapshot s{{x,0,0},4,8,4,1,revision,std::vector<std::uint8_t>(4*8*4,1)};
    return std::make_shared<const tp::Result>(tp::extract(s));
}
int main(){
    const std::vector<Liquid> types{{"water",1,1000},{"lava",10,2800}};
    EditProvenance provenance;
    const sandbox::core::Region edit_key{0,-32,0},safe_key{16,-32,0};
    assert(provenance.pristine(edit_key,0));
    provenance.record(1,{edit_key});
    assert(!provenance.pristine(edit_key,1)&&provenance.pristine(safe_key,1)&&!provenance.pristine(safe_key,2));
    auto restored=EditProvenance::decode(provenance.encode(),1);
    assert(restored.complete()&&restored.pristine(safe_key,1)&&!restored.pristine(edit_key,1));
    restored.record(3,{safe_key});
    assert(!restored.complete()&&!restored.pristine(edit_key,3));
    assert(!EditProvenance::decode(nlohmann::json(nullptr),1).pristine(safe_key,1));
    std::cout<<"V3_HYBRID_I15_PROVENANCE_PASS\n";
    const auto a=flat(0),b=flat(4),c=flat(8);
    const auto ka=a->origin,kb=b->origin,kc=c->origin;
    std::map<sandbox::core::Region,std::shared_ptr<const tp::Result>> geometry{{ka,a},{kb,b},{kc,c}};
    Coupler domain(types,2,3);
    assert(domain.publish(a)&&domain.publish(b)&&domain.publish(c));
    assert(domain.seed(ka,a->compartments.front().id,0,32000));
    assert(domain.seed(kc,c->compartments.front().id,0,16000));
    const auto mass=domain.mass();
    assert(domain.activate(ka)&&domain.activate(kc)&&!domain.activate(kb));
    assert(domain.tiles().at(kb).phase==Phase::blocked&&domain.active()==2&&domain.mass()==mass);
    assert(domain.tiles().at(ka).aggregate.empty()&&domain.tiles().at(kc).aggregate.empty());
    for(int i=0;i<10;++i)domain.tick();
    assert(domain.tile_mass(kb)>0&&domain.mass()==mass);
    // A receiving tile is promoted before the first local discharge,
    // so a remote column remains dry during the initial boundary tick.
    Coupler frontier(types,2,2);
    assert(frontier.publish(a)&&frontier.publish(b)&&frontier.seed(ka,a->compartments.front().id,0,32000));
    assert(frontier.activate(ka));
    assert(frontier.local_front_candidates()==std::vector<sandbox::core::Region>{kb});
    assert(frontier.activate(kb)&&frontier.tile_mass(kb)==0);
    frontier.tick();
    assert(frontier.tile_mass(kb)>0&&frontier.column_mass(kb,3,0)==0&&frontier.mass()==32000);
    std::cout<<"V3_HYBRID_I13_FRONT_ACTIVATION_PASS\n";
    // Versioned mid-flow round trip; same geometry checkpoint, flux and
    // ledger retained. Continue original and reopened identically.
    const auto saved=domain.encode().dump();
    auto reopened=Coupler::decode(nlohmann::json::parse(saved),types,geometry);
    assert(reopened.encode()==domain.encode());
    for(int i=0;i<100;++i){domain.tick();reopened.tick();assert(domain.encode()==reopened.encode()&&reopened.mass()==mass);}
    const auto retained=reopened.tile_mass(kc);
    reopened.set_resident(kc,false);
    for(int i=0;i<50;++i)reopened.tick();
    assert(reopened.tile_mass(kc)==retained&&reopened.mass()==mass);
    reopened.set_resident(kc,true);
    // An unchanged wet geometry revision preserves exact owner mass.
    const auto next=flat(0,2);assert(reopened.replace_geometry(next));geometry[ka]=next;
    assert(reopened.mass()==mass);
    auto bad=nlohmann::json::parse(saved);bad["tiles"][0]["revision"]=999;
    bool rejected=false;try{(void)Coupler::decode(bad,types,geometry);}catch(const std::exception&){rejected=true;}
    assert(rejected);
    // Isolated equal-head activation/reaggregation cycle: no collapse of
    // a live front and no repeated application of a source.
    Coupler stable(types,1,1);assert(stable.publish(a)&&stable.seed(ka,a->compartments.front().id,1,16000));
    for(int cycle=0;cycle<3;++cycle) {
        assert(stable.activate(ka)&&stable.request_settle(ka));
        for(int i=0;i<25;++i)stable.tick();
        assert(stable.active()==0&&stable.tiles().at(ka).phase==Phase::aggregate&&stable.mass()==16000);
    }
    // Recover an exact suspended equilibrium without advancing frozen
    // time, preserve non-equilibrium local state, then reuse the slot.
    Coupler reclaim(types,1,2);assert(reclaim.publish(a)&&reclaim.publish(b));
    assert(reclaim.seed(ka,a->compartments.front().id,0,16000)&&reclaim.activate(ka));
    reclaim.set_resident(ka,false);
    assert(reclaim.reclaim_suspended(ka)&&reclaim.active()==0&&reclaim.mass()==16000);
    assert(reclaim.activate(kb));reclaim.set_resident(kb,false);
    assert(reclaim.reclaim_suspended(kb)&&reclaim.active()==0);
    auto cold=Coupler::decode(reclaim.encode(),types,{{ka,a},{kb,b}});
    assert(cold.encode()==reclaim.encode());cold.set_resident(ka,true);
    assert(cold.activate(ka)&&cold.mass()==16000);
    frontier.set_resident(kb,false);
    assert(!frontier.reclaim_suspended(kb)&&frontier.tiles().at(kb).local&&frontier.mass()==32000);
    std::cout<<"V3_HYBRID_I16_RECLAIM_PASS\n";
    // I22: stream more owners than the hot budget without changing mass
    // or local pipe momentum. The external record is the only cold owner.
    Coupler streamed(types,1,2);
    assert(streamed.publish(a)&&streamed.publish(b)&&streamed.seed(ka,a->compartments.front().id,0,32000));
    assert(streamed.activate(ka));streamed.tick();streamed.set_resident(ka,false);
    const auto owner=streamed.encode_tile(ka);const auto owner_mass=streamed.tile_mass(ka);
    const auto global_mass=streamed.mass();
    assert(streamed.detach_cold(ka)&&streamed.active()==0&&streamed.cold_count()==1&&streamed.cold_mass()==owner_mass);
    assert(streamed.mass()==global_mass&&streamed.publish(c));
    const auto before_view=streamed.encode();
    auto viewed=streamed.inspect_cold(a,owner);
    assert(viewed&&viewed->first.local&&viewed->second==owner_mass);
    assert(streamed.encode()==before_view&&streamed.active()==0);
    assert(!streamed.restore_cold(a,owner));
    streamed.set_resident(kc,false);assert(streamed.forget_dry(kc));
    auto hot_reopen=Coupler::decode(streamed.encode(),types,{{kb,b}});
    assert(hot_reopen.mass()==global_mass&&hot_reopen.cold_count()==1);
    assert(hot_reopen.restore_cold(a,owner)&&hot_reopen.encode_tile(ka)==owner);
    assert(hot_reopen.mass()==global_mass&&hot_reopen.cold_count()==0&&hot_reopen.active()==1);
    assert(!hot_reopen.restore_cold(a,owner));
    Coupler many(types,1,2);
    std::vector<nlohmann::json> cold_rows;
    for(int i=0;i<120;++i){
        const auto g=flat(i*4);const auto k=g->origin;
        assert(many.publish(g)&&many.seed(k,g->compartments.front().id,0,16000));
        many.set_resident(k,false);cold_rows.push_back(many.encode_tile(k));assert(many.detach_cold(k));
        assert(many.tiles().empty()&&many.mass()==16000*(i+1));
    }
    assert(many.cold_count()==120&&many.cold_mass()==1920000);
    auto many_reopen=Coupler::decode(many.encode(),types,{});
    for(int i=119;i>=0;--i){
        const auto g=flat(i*4);assert(many_reopen.restore_cold(g,cold_rows.at(static_cast<std::size_t>(i))));
        assert(many_reopen.encode_tile(g->origin)==cold_rows.at(static_cast<std::size_t>(i))&&many_reopen.mass()==1920000);
        assert(many_reopen.detach_cold(g->origin));
    }
    std::cout<<"V3_HYBRID_I22_COLD_OWNER_PASS count="<<many_reopen.cold_count()<<" mass="<<many_reopen.mass()<<"\n";
    // A two-tile exposed bowl with a closed outer rim. Initialize
    // late only after the whole reached component has been certified.
    auto bowl=[](int offset){
        tp::Snapshot s{{offset,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
        for(int z=1;z<=2;++z)for(int x=(offset?0:1);x<=(offset?2:3);++x)for(int y=0;y<8;++y)
            s.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
        return std::make_shared<const tp::Result>(tp::extract(s));
    };
    const auto ba=bowl(0),bb=bowl(4);
    Coupler late(types,1,2);assert(late.publish(ba));
    const auto bid=tp::compartment_at(*ba,{2.5,0.5,1.5});assert(bid);
    std::set<sandbox::core::Region> edge;
    assert(late.seed_surface_basin(ka,*bid,1,3,8,{ka},edge)==Coupler::BasinResult::frontier&&edge.contains(kb)&&late.mass()==0);
    assert(late.publish(bb));late.set_resident(kb,false);
    assert(late.seed_surface_basin(ka,*bid,1,3,8,{ka,kb},edge)==Coupler::BasinResult::seeded);
    assert(late.mass()==36000&&late.initial()==36000&&late.tile_mass(kb)==18000);
    assert(late.seed_surface_basin(ka,*bid,1,3,8,{ka,kb},edge)==Coupler::BasinResult::conflict&&late.mass()==36000);
    auto late_save=Coupler::decode(late.encode(),types,{{ka,ba},{kb,bb}});
    assert(late_save.encode()==late.encode());
    std::cout<<"V3_HYBRID_I17_LATE_BASIN_PASS mass="<<late.mass()<<"\n";
    // Incremental closed-basin discovery across 121 regions, independent
    // of the two-region hot limit. Unknown endpoints are not assumed dry.
    auto narrow=[](int i){
        tp::Snapshot s{{i*4,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
        for(int z=1;z<=2;++z)for(int x=(i==0?1:0);x<=(i==120?2:3);++x)
            for(int y=0;y<8;++y)s.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
        return std::make_shared<const tp::Result>(tp::extract(s));
    };
    auto first_basin=narrow(0);
    FiniteBasinSurvey basin(first_basin->origin,first_basin->compartments.front().id,3,8,1);
    Coupler surveyed_basin(types,1,2);
    for(int i=0;i<=120;++i){
        assert(!basin.complete()&&surveyed_basin.mass()==0);
        assert(basin.offer(narrow(i)));basin.step();
    }
    for(int i=0;i<121&&!basin.complete();++i)basin.step();
    assert(basin.complete()&&basin.reached().size()==121&&basin.geometry().size()==121);
    std::vector<nlohmann::json> basin_rows;
    for(const auto &[k,contents]:basin.reached()){
        auto row=surveyed_basin.stage_cold_seed(basin.geometry().at(k),0,contents);
        assert(row);basin_rows.push_back(row->first);
    }
    const auto basin_mass=static_cast<Litres>((121*4-2)*2*3000);
    assert(surveyed_basin.tiles().empty()&&surveyed_basin.cold_count()==121&&surveyed_basin.mass()==basin_mass&&surveyed_basin.initial()==basin_mass);
    auto basin_reopened=Coupler::decode(surveyed_basin.encode(),types,{});
    assert(basin_reopened.restore_cold(first_basin,basin_rows.front())&&basin_reopened.mass()==basin_mass);
    std::cout<<"V3_HYBRID_I22_FINITE_SURVEY_PASS regions=121 mass="<<basin_mass<<" hot=0\n";
    // A 2m structural wall spans the shared boundary of two independently
    // owned local tiles. Both edits are preflighted on one staged model;
    // no mass is lost and no artificial cross-wall portal survives.
    Coupler cross_tile(types,2,2);
    assert(cross_tile.publish(a)&&cross_tile.publish(b));
    assert(cross_tile.seed(ka,a->compartments.front().id,0,32000));
    assert(cross_tile.seed(kb,b->compartments.front().id,0,32000));
    assert(cross_tile.activate(ka)&&cross_tile.activate(kb));
    const auto original_cross=cross_tile.encode();
    tp::Snapshot left_cut{{0,0,0},4,8,4,1,2,std::vector<std::uint8_t>(4*8*4,1)};
    tp::Snapshot right_cut{{4,0,0},4,8,4,1,2,std::vector<std::uint8_t>(4*8*4,1)};
    for(int z=0;z<4;++z)for(int y=0;y<8;++y){
        left_cut.air[static_cast<std::size_t>((z*4+3)*8+y)]=0;
        right_cut.air[static_cast<std::size_t>((z*4)*8+y)]=0;
    }
    auto staged_cross=cross_tile;
    assert(staged_cross.replace_geometry(std::make_shared<const tp::Result>(tp::extract(left_cut)),true));
    assert(staged_cross.replace_geometry(std::make_shared<const tp::Result>(tp::extract(right_cut)),true));
    assert(staged_cross.mass()==64000&&staged_cross.column_mass(ka,3,1)==0&&staged_cross.column_mass(kb,0,1)==0);
    for(const auto &interface:staged_cross.interfaces())
        assert(interface.a.tile==interface.b.tile);
    auto invalid_cross=cross_tile;
    auto solid_cross=left_cut;solid_cross.revision=3;
    std::fill(solid_cross.air.begin(),solid_cross.air.end(),0);
    assert(!invalid_cross.replace_geometry(std::make_shared<const tp::Result>(tp::extract(solid_cross)),true));
    assert(invalid_cross.encode()==original_cross);
    std::cout<<"V3_HYBRID_I23_CROSS_TILE_BARRIER_PASS mass=64000 atomic_reject=1 portals_closed=1\n";
    // A solid wall deletes complete wet intervals. Only surviving
    // previously wet recipients can accept displaced mass.
    tp::Snapshot wall{{0,0,0},4,8,4,1,2,std::vector<std::uint8_t>(4*8*4,1)};
    for(int z=0;z<4;++z)for(int y=0;y<8;++y)wall.air[static_cast<std::size_t>((z*4+2)*8+y)]=0;
    const auto wall_geom=std::make_shared<const tp::Result>(tp::extract(wall));
    Coupler barrier(types,1,1);assert(barrier.publish(a)&&barrier.seed(ka,a->compartments.front().id,0,16000)&&barrier.activate(ka));
    assert(!barrier.replace_geometry(wall_geom)&&barrier.mass()==16000);
    assert(barrier.replace_geometry(wall_geom,true)&&barrier.mass()==16000&&barrier.column_mass(ka,2,1)==0);
    const auto before_wall=barrier.encode();
    auto solid=wall;solid.revision=3;std::fill(solid.air.begin(),solid.air.end(),0);
    assert(!barrier.replace_geometry(std::make_shared<const tp::Result>(tp::extract(solid)),true)&&barrier.encode()==before_wall);
    for(int i=0;i<40;++i)barrier.tick();
    assert(barrier.mass()==16000&&barrier.column_mass(ka,2,1)==0);
    std::cout<<"V3_HYBRID_I18_BARRIER_PASS mass="<<barrier.mass()<<"\n";
    // Explicit ocean source and sink, no infinite volume in resident state.
    Coupler sea(types,1,1);assert(sea.publish(a));
    assert(sea.ocean({"sea",ka,{0.5,0.1,0.5},0,2,0,1}));
    assert(!sea.ocean({"sea",ka,{0.5,0.1,0.5},0,2,0,1}));
    for(int i=0;i<20;++i)sea.tick();
    assert(sea.mass()>0&&sea.mass()==sea.injected()-sea.drained());
    assert(sea.activate(ka));
    assert(sea.ocean({"sink",ka,{3.5,0.1,3.5},0,0.5,0,1}));
    for(int i=0;i<200;++i)sea.tick();
    assert(sea.drained()>0&&sea.mass()==sea.injected()-sea.drained());
    auto sea_reopen=Coupler::decode(nlohmann::json::parse(sea.encode().dump()),types,{{ka,a}});
    assert(sea_reopen.encode()==sea.encode());
    // I22d: a source-connected ocean chain extends beyond the entire hot
    // budget without enumerating a global ocean or wetting a roofed cave.
    Coupler extended(types,1,2);
    assert(extended.publish(a)&&extended.ocean({"extended",ka,{0.5,0.1,0.5},0,2,0,1}));
    auto proof=OceanReach::extend("extended",2,8,1,*a,a->compartments.front().id,{});
    assert(proof.compartments.size()==1&&proof.frontier(*a).contains(kb));
    assert(extended.acquire_ocean(proof,1,true)&&extended.mass()==32000&&extended.initial()==0);
    // The physical source tile must also be filled by its own certified
    // fixed-head source, exactly once, without skipping its root geometry.
    assert(extended.tile_mass(ka)==32000&&extended.injected()==32000);
    assert(extended.acquire_ocean(proof,1,true)&&extended.mass()==32000&&extended.injected()==32000);
    auto previous=a;
    nlohmann::json archived_ocean;
    for(int x=1;x<=120;++x){
        auto next_ocean_tile=flat(x*4);
        auto reached=OceanReach::extend("extended",2,8,1,*next_ocean_tile,std::nullopt,{{previous.get(),&proof}});
        assert(reached.compartments.size()==1);
        assert(OceanReach::extend("extended",2,8,2,*next_ocean_tile,std::nullopt,{{previous.get(),&proof}}).compartments.empty());
        assert(extended.publish(next_ocean_tile)&&extended.acquire_ocean(reached,1,true));
        extended.set_resident(next_ocean_tile->origin,false);archived_ocean=extended.encode_tile(next_ocean_tile->origin);assert(extended.detach_cold(next_ocean_tile->origin));
        proof=std::move(reached);previous=std::move(next_ocean_tile);
    }
    assert(extended.tiles().size()==1&&extended.cold_count()==120&&extended.mass()==121*32000&&extended.injected()==extended.mass());
    auto reopened_ocean=Coupler::decode(extended.encode(),types,{{ka,a}});
    auto archived_view=reopened_ocean.inspect_cold(previous,archived_ocean);
    assert(archived_view&&archived_view->first.ocean_reach.at("extended").encode()==proof.encode());
    assert(reopened_ocean.restore_cold(previous,archived_ocean)&&reopened_ocean.mass()==extended.mass());
    assert(reopened_ocean.tiles().at(previous->origin).ocean_reach.at("extended").matches(*previous,1));
    // A source-connected path must be recertified at a newer revision.
    // Pristine receiver after an unrelated edit is eligible, while an
    // actually edited receiver is not (the runtime provenance gate).
    auto root2=OceanReach::extend("extended",2,8,2,*a,a->compartments.front().id,{});
    assert(!root2.compartments.empty());
    auto after_edit_geometry=flat(4,2);
    auto post_edit=OceanReach::extend("extended",2,8,2,*after_edit_geometry,std::nullopt,{{a.get(),&root2}});
    assert(post_edit.compartments.size()==1);
    assert(OceanReach::extend("extended",2,8,2,*after_edit_geometry,std::nullopt,{{a.get(),&proof}}).compartments.empty());
    EditProvenance post_provenance;
    post_provenance.record(1,{{0,-32,0}});
    post_provenance.record(2,{{16,-32,0}});
    assert(!post_provenance.pristine({16,-32,0},2)&&post_provenance.pristine({32,-32,0},2));
    Coupler post_coupler(types,1,2);
    assert(post_coupler.publish(a)&&post_coupler.ocean({"extended",ka,{0.5,0.1,0.5},0,2,0,1}));
    assert(post_coupler.publish(after_edit_geometry));
    assert(post_coupler.remember_ocean(root2,2));
    assert(post_coupler.acquire_ocean(post_edit,2,true));
    assert(post_coupler.mass()==32000&&post_coupler.injected()==32000);
    assert(!post_coupler.acquire_ocean(post_edit,1,true));
    std::cout<<"V3_HYBRID_I22_POST_EDIT_REACH_PASS fresh_proof=1 stale_rejected=1 pristine_gate=1\n";
    tp::Snapshot roof{{484,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
    for(int z=0;z<4;++z)for(int x=0;x<4;++x)for(int y=0;y<2;++y)
        roof.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
    const auto roof_geometry=tp::extract(roof);
    auto isolated=OceanReach::extend("extended",2,8,1,roof_geometry,std::nullopt,{{previous.get(),&proof}});
    assert(isolated.compartments.empty());
    std::cout<<"V3_HYBRID_I22_OCEAN_CONNECTIVITY_PASS regions=121 hot=1 injected="<<extended.injected()<<" cave=excluded stale=excluded\n";
    // I2 local carve changes an existing floor and opens a formerly
    // solid horizontal column. Remap must not wet the remote cell.
    tp::Snapshot old{{0,0,0},4,8,2,1,1,std::vector<std::uint8_t>(4*8*2,0)};
    for(int z=0;z<2;++z)for(int x:{0,1,3})for(int y=1;y<8;++y)
        old.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
    auto cut=old;cut.revision=2;
    for(int z=0;z<2;++z)for(int y=0;y<8;++y){
        cut.air[static_cast<std::size_t>((z*4+1)*8+y)]=1;
        cut.air[static_cast<std::size_t>((z*4+2)*8+y)]=1;
    }
    const auto before_geom=std::make_shared<const tp::Result>(tp::extract(old));
    const auto after_geom=std::make_shared<const tp::Result>(tp::extract(cut));
    Coupler carve(types,1,1);assert(carve.publish(before_geom));
    const auto id=tp::compartment_at(*before_geom,{0.5,1.5,0.5});assert(id);
    assert(carve.seed(old.origin,*id,0,4000)&&carve.activate(old.origin));
    assert(carve.replace_geometry(after_geom)&&carve.mass()==4000);
    assert(!carve.sample({2.5,0.1,0.5},old.origin)&&!carve.sample({3.5,1.1,0.5},old.origin));
    for(int i=0;i<200;++i)carve.tick();
    assert(carve.mass()==4000&&carve.sample({2.5,0.1,0.5},old.origin));
    std::cout<<"V3_HYBRID_I2_REMAP_PASS changed_floor=1 zero_tick_dry=1 progressive_mass=4000\n";
    std::cout<<"V3_R3_COUPLER_PASS two_fronts=1 mass="<<mass<<" mid_flow_reopen=1 unload=1 activation_cycles=3 lava=1 source_l="<<sea.injected()<<" drain_l="<<sea.drained()<<" capacity_blocked=1 stale_revision_rejected=1\n";
}
