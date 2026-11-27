#include "../../experiments/v3/hybrid/coupler.hpp"
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
