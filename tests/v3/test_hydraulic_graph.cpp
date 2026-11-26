#include "core/hydraulic_graph.hpp"
#include <cassert>
#include <chrono>
#include <iostream>
using namespace sandbox::hydraulic;
static Curve tank(int bottom=0,int top=10000,Litres capacity=100000){return Curve({{bottom,0},{top,capacity}});}
int main(){
    Graph g({{"water",1,1000},{"lava",10,2800}});
    g.add_volume({1,0,tank(),100000});g.add_volume({2,0,tank(),0});g.add_volume({3,0,tank(),0});
    g.add_portal({1,1,2,0,1,0.62,false,1});
    g.add_portal({2,2,3,0,1,0.62,true,1});
    assert(g.tick().moved==0&&g.volumes().at(2).litres==0);
    g.invalidate_portal(1,2);
    assert(!g.publish_portal(1,0,1,true,1));
    assert(g.publish_portal(1,0,1,true,2));
    auto first=g.tick();
    assert(first.moved>0&&g.volumes().at(2).litres>0&&g.volumes().at(3).litres==0);
    assert(g.tick().moved>0&&g.volumes().at(3).litres>0);
    g.invalidate_portal(1,3);const auto held=g.volumes().at(1).litres;
    for(int i=0;i<100;++i)g.tick();
    assert(g.volumes().at(1).litres==held&&g.finite()==100000);
    assert(!g.replace_curve(1,tank(0,1000,1)));
    Graph ocean({{"water",1,1000}});
    ocean.add_volume({1,0,tank(),0,true,5});ocean.add_volume({2,0,tank(),0});
    ocean.add_portal({1,1,2,0,2,0.62,true,0});
    for(int i=0;i<500;++i)ocean.tick();
    assert(ocean.finite()==50000&&ocean.injected()==50000&&ocean.drained()==0&&ocean.backlog()==0);
    Graph drain({{"water",1,1000}});
    drain.add_volume({1,0,tank(),0,true,2});drain.add_volume({2,0,tank(),100000});
    drain.add_portal({1,1,2,0,2,0.62,true,0});
    for(int i=0;i<500;++i)drain.tick();
    assert(drain.finite()==20000&&drain.drained()==80000);
    Graph viscosity({{"water",1,1000},{"lava",10,2800}});
    for(Id i=1;i<=4;++i)viscosity.add_volume({i,i<3?0U:1U,tank(),i%2?100000:0});
    viscosity.add_portal({1,1,2,0,1,0.62,true,0});
    viscosity.add_portal({2,3,4,0,1,0.62,true,0});
    viscosity.add_portal({3,1,4,0,1,0.62,true,0});
    viscosity.tick();
    const auto water=viscosity.volumes().at(2).litres,lava=viscosity.volumes().at(4).litres;
    assert(lava>0&&water>=lava*9&&viscosity.finite()==200000);
    // Volume count does not determine the tick work: 4096 dormant bodies,
    // one opening, one portal visit. A billion litres is still one node.
    Graph scale({{"water",1,1000}});
    for(Id i=1;i<=4096;++i)scale.add_volume({i,0,tank(0,10000,1000000000),i==1?1000000000:0});
    scale.add_portal({1,1,2,0,20,0.62,true,0});
    auto r=scale.tick(1);assert(r.visited==1&&r.moved>0&&scale.finite()==1000000000);
    scale.restore_ledger(1000000000,0,0);
    bool rejected=false;try{scale.restore_ledger(1,0,0);}catch(const std::invalid_argument&){rejected=true;}
    assert(rejected);
    std::cout<<"V3_HYDRAULIC_GRAPH_PASS finite_mass ocean_source ocean_sink isolated_dry revision viscosity dormant_4096 one_portal\n";
}
