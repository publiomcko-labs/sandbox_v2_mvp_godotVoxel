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
    // H13 refined curves survive archive/revalidation, including a head
    // below the binary floor. Older schema-2 archives remain readable.
    hy::Domain precise(types);
    hy::tp::Snapshot sub{{0,-32,0},16,64,16,1,4,std::vector<std::uint8_t>(16*64*16,0)};
    for(int z=0;z<16;++z)for(int x=0;x<16;++x)for(int y=36;y<64;++y)
        sub.air[static_cast<std::size_t>((z*16+x)*64+y)]=1;
    sub.surface_floor.assign(17*17,3.4f);sub.refine_exposed=true;
    assert(precise.publish(hy::tp::extract(sub)));
    assert(precise.seed_finite("sub",{1,3.6,1},0,3.8,true));
    const auto exact=precise.graph().finite();
    auto saved=ps::decode_domain(sandbox::content::strict_json(ps::encode_domain(precise).dump()),types);
    assert(saved.graph().finite()==exact&&!saved.wet_at({1,3.6,1}));
    assert(saved.publish(hy::tp::extract(sub))&&saved.wet_at({1,3.6,1}));
    assert(saved.graph().finite()==exact);
    std::cout<<"V3_HYDRAULIC_REFINED_STORE_PASS exact_mass below_binary_floor revalidate\n";
    std::cout<<"V3_HYDRAULIC_DOMAIN_STORE_PASS mass source_ids revalidate\n";
    std::cout<<"V3_HYDRAULIC_STORE_PASS persistent_type_id mass_ledger closed_until_revalidated\n";
}
