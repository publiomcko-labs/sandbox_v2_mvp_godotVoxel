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
    Graph dry({{"water",1,1000},{"lava",10,2800}});
    dry.add_volume({1,1,tank(),100000});dry.add_volume({2,no_liquid,tank(),0});
    dry.add_portal({1,1,2,0,1,0.62,true,0});
    dry.tick();
    assert(dry.volumes().at(2).type==1&&dry.volumes().at(2).litres>0);
    // A positive head with a sub-litre discharge must keep transferring.
    Graph trickle({{"water",1,1000}});
    trickle.add_volume({1,0,tank(),20000});trickle.add_volume({2,0,tank(),0});
    trickle.add_portal({1,1,2,0,0.001,0.62,true,1});
    assert(trickle.tick().moved==0&&trickle.backlog()==1);
    for(int i=0;i<20;++i)trickle.tick();
    assert(trickle.volumes().at(2).litres>0&&trickle.finite()==20000);
    trickle.invalidate_portal(1,2);
    const auto retained=trickle.volumes().at(2).litres;
    for(int i=0;i<20;++i)trickle.tick();
    assert(trickle.volumes().at(2).litres==retained);
    std::cout<<"V3_HYDRAULIC_TRICKLE_PASS sub_litre_credit closed_portal exact_mass\n";
    // Wide submerged connections equalize small head differences faster
    // than the ordinary Torricelli law, without changing narrow/dry flow.
    const auto make_pair=[](double width,bool geometric,bool wet) {
        Graph pair({{"water",1,1000}});
        pair.add_volume({1,0,tank(0,10000,1000000),400000});
        pair.add_volume({2,0,tank(0,10000,1000000),wet?380000:0});
        pair.add_portal({1,1,2,0,width*(geometric?10.0:4.0),0.62,true,1,geometric?10.0:0.0});
        return pair;
    };
    auto broad=make_pair(8,true,true),baseline=make_pair(8,false,true);
    const auto broad_moved=broad.tick().moved,base_moved=baseline.tick().moved;
    assert(broad_moved>base_moved&&broad.finite()==780000);
    assert(broad.volumes().at(1).level()>=broad.volumes().at(2).level());
    auto narrow=make_pair(1,true,true),narrow_base=make_pair(1,false,true);
    assert(narrow.tick().moved==narrow_base.tick().moved);
    auto dry_broad=make_pair(8,true,false),dry_base=make_pair(8,false,false);
    assert(dry_broad.tick().moved==dry_base.tick().moved);
    broad.invalidate_portal(1,2);
    assert(broad.tick().moved==0&&broad.finite()==780000);
    std::cout<<"V3_HYDRAULIC_WIDE_CONTACT_PASS accelerated_wet narrow_and_dry_unchanged exact_mass\n";
    // Presentation may share only a certified near-equilibrium plane.
    // The group spread is bounded, even on chains of small differences.
    Graph heads({{"water",1,1000},{"lava",10,2800}});
    heads.add_volume({1,0,tank(),40000});
    heads.add_volume({2,0,tank(),41000});
    heads.add_volume({3,0,tank(),42000});
    heads.add_volume({4,0,tank(),41000});
    heads.add_volume({5,1,tank(),41000});
    heads.add_volume({6,0,tank(),0});
    heads.add_portal({1,1,2,0,20,0.62,true,1,10});
    heads.add_portal({2,2,3,0,20,0.62,true,1,10});
    heads.add_portal({3,2,4,4.2,20,0.62,true,1,5});
    heads.add_portal({4,2,5,0,20,0.62,true,1,10});
    heads.add_portal({5,2,6,0,20,0.62,true,1,10});
    const auto visual=heads.presentation_heads({1,2,3,4,5,6});
    assert(visual.at(1)==visual.at(2)&&std::abs(visual.at(1)-4.05)<1e-8);
    assert(visual.at(3)==4.2&&visual.at(4)==4.1&&visual.at(5)==4.1&&!visual.contains(6));
    assert(heads.volumes().at(1).litres==40000&&heads.volumes().at(2).litres==41000);
    heads.invalidate_portal(1,2);
    assert(heads.presentation_heads({1,2}).at(1)==4.0);
    // Runtime supplies only revision-valid renderable endpoints when
    // using cached connectivity. Physics still treats the portal closed.
    assert(heads.presentation_heads({1,2},0.15,true).at(1)==visual.at(1));
    assert(heads.presentation_heads({1},0.15,true).at(1)==4.0);
    assert(heads.volumes().at(1).litres==40000&&heads.volumes().at(2).litres==41000);
    std::cout<<"V3_HYDRAULIC_SHARED_PLANE_PASS bounded_group_head no_mass_mutation no_closed_sill\n";
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
