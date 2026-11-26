#include "core/world_core.hpp"
#include <cassert>
#include <iostream>
using namespace sandbox::core;
struct Fixture : TerrainAdapter {
    unsigned calls{};
    ApplyResult status = ApplyResult::applied;
    ApplyResult apply(const Brush &) noexcept override { ++calls; return status; }
};
int main() {
    Fixture terrain;
    WorldCore<2> core(terrain);
    Brush b{1,{0,0,0},1.5,false};
    assert(core.submit(b)==CommandResult::accepted);
    assert(core.submit(b)==CommandResult::duplicate && terrain.calls==1);
    b.sequence=3;
    assert(core.submit(b)==CommandResult::out_of_order);
    b.sequence=2; b.radius_m=0;
    assert(core.submit(b)==CommandResult::rejected && terrain.calls==1);
    b.radius_m=1.5;
    terrain.status=ApplyResult::deferred;
    assert(core.submit(b)==CommandResult::deferred);
    terrain.status=ApplyResult::applied;
    assert(core.submit(b)==CommandResult::accepted);
    b.sequence=3;
    assert(core.submit(b)==CommandResult::backpressure && terrain.calls==3);
    assert(core.queued_events()==2 && core.peek()->revision==1);
    assert(core.peek()->bounds.min.x==-3.5);
    assert(!core.acknowledge(2) && core.acknowledge(1));
    terrain.status=ApplyResult::no_effect;
    assert(core.submit(b)==CommandResult::no_effect);
    assert(core.acknowledge(2) && !core.peek());
    auto &scheduler=core.scheduler();
    scheduler.accrue(12*tick_period_ns+123);
    assert(scheduler.drain(2,[](auto,auto){return true;})==2);
    assert(scheduler.backlog()==10);
    assert(scheduler.drain(2,[](auto,auto){return false;})==0);
    assert(scheduler.backlog()==10);
    unsigned aggregated=0;
    assert(scheduler.drain(20,[&](auto tick,bool agg){if(agg){assert(tick==10);++aggregated;}return true;})==10);
    assert(aggregated==1 && scheduler.pending_ns()==123);
    auto cp=core.checkpoint();
    assert(cp.terrain_revision==2 && cp.last_command==3 && cp.completed_tick==12);
    WorldCore<2> reopened(terrain,cp);
    assert(reopened.submit(b)==CommandResult::duplicate);
    b.sequence=4; terrain.status=ApplyResult::applied;
    assert(reopened.submit(b)==CommandResult::accepted && reopened.peek()->revision==3);
    assert(region_at({-.01,-64.0,64.0})==(Region{-1,-1,1}));
    Regions regions(3);
    assert(regions.set({0,0,0},Tier::active));
    assert(regions.set({-1,0,0},Tier::aggregate));
    assert(regions.set({4,0,0},Tier::dormant));
    assert(!regions.set({5,0,0},Tier::active));
    assert(regions.active_count()==1 && regions.aggregate_count()==1 && regions.dormant_count()==1);
    assert(regions.query({{-1,0,0},{63,0,0}}).size()==2);
    assert(regions.set({-1,0,0},Tier::active));
    assert(regions.active_count()==2 && regions.aggregate_count()==0);
    assert(regions.set({0,0,0},Tier::dormant));
    assert(regions.active_count()==1 && regions.dormant_count()==2);
    regions.erase({4,0,0});
    assert(regions.size()==2 && !regions.get({4,0,0}));
    bool rejected=false;
    try { regions.query({{0,0,0},{100000,100000,100000}}); }
    catch(const std::invalid_argument &){rejected=true;}
    assert(rejected);
    std::cout << "V3_WORLD_CORE_CONTRACT_PASS\n";
}
