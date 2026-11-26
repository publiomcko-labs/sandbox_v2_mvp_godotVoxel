#include "persistence/hydraulic_domain_store.hpp"
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
    hy::Domain domain(types);
    hy::tp::Snapshot s{{0,-32,0},16,64,16,1,4,std::vector<std::uint8_t>(16*64*16,1)};
    assert(domain.publish(hy::tp::extract(s)));
    assert(domain.seed_finite("pond",{1,-1,1},0,2,true));
    assert(domain.add_ocean("sea",{2,-1,2},0,3,1,true));
    domain.tick();
    auto restored_domain=ps::decode_domain(ps::encode_domain(domain),types);
    assert(restored_domain.graph().finite()==domain.graph().finite());
    assert(restored_domain.seeded()==domain.seeded()&&!restored_domain.wet_at({1,0,1}));
    assert(restored_domain.tick().moved==0);
    assert(restored_domain.publish(hy::tp::extract(s))&&restored_domain.wet_at({1,0,1}));
    assert(restored_domain.graph().finite()==domain.graph().finite());
    std::cout<<"V3_HYDRAULIC_DOMAIN_STORE_PASS mass source_ids revalidate\n";
    std::cout<<"V3_HYDRAULIC_STORE_PASS persistent_type_id mass_ledger closed_until_revalidated\n";
}
