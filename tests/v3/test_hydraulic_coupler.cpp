#include "../../experiments/v3/hybrid/coupler.hpp"
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
    std::cout<<"V3_R3_COUPLER_PASS two_fronts=1 mass="<<mass<<" mid_flow_reopen=1 unload=1 activation_cycles=3 lava=1 source_l="<<sea.injected()<<" drain_l="<<sea.drained()<<" capacity_blocked=1 stale_revision_rejected=1\n";
}
