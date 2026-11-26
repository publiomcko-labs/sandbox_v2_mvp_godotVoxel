#include "persistence/hydraulic_store.hpp"
#include <cassert>
#include <iostream>
namespace hy=sandbox::hydraulic;
namespace ps=sandbox::persistence;
int main(){
    const std::vector<hy::Liquid> types{{"hydro:water",1,1000},{"hydro:lava",10,2800}};
    hy::Graph graph(types);
    hy::Curve c({{0,0},{10000,100000}});
    graph.add_volume({1,0,c,0,true,5});
    graph.add_volume({2,0,c,0});
    graph.add_portal({1,1,2,0,2,0.62,true,7});
    graph.tick();
    const auto j=ps::encode_hydraulic(graph);
    auto restored=ps::decode_hydraulic(sandbox::content::strict_json(j.dump()),types);
    assert(restored.finite()==graph.finite()&&restored.injected()==graph.injected());
    assert(!restored.portals().at(1).available&&restored.tick().visited==0);
    assert(!restored.publish_portal(1,0,2,true,6));
    assert(restored.publish_portal(1,0,2,true,7));
    graph.tick();restored.tick();
    assert(restored.finite()==graph.finite());
    auto bad=j;bad["injected"]=0;bool rejected=false;
    try{ps::decode_hydraulic(sandbox::content::strict_json(bad.dump()),types);}catch(const std::exception&){rejected=true;}
    assert(rejected);
    std::cout<<"V3_HYDRAULIC_STORE_PASS persistent_type_id mass_ledger closed_until_revalidated\n";
}
