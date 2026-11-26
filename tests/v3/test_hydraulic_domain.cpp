#include "core/hydraulic_domain.hpp"
#include <cassert>
#include <iostream>
using namespace sandbox::hydraulic;
int main(){
    Domain d({{"water",1,1000},{"lava",10,2800}},4,4,1,0);
    tp::Snapshot a{{0,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,1)};
    auto b=a;b.origin.x=4;
    assert(d.publish(tp::extract(a)));
    assert(!d.seed_finite("pond",{1,1,1},0,4,false));
    assert(d.seed_finite("pond",{1,1,1},0,4,true));
    assert(!d.seed_finite("pond",{1,1,1},0,4,true));
    assert(d.graph().finite()==64000&&d.graph().portals().empty());
    assert(d.publish(tp::extract(b)));
    assert(d.graph().portals().size()==1&&d.tick().moved>0&&d.wet_at({5,0.01,1}));
    const auto mass=d.graph().finite();
    d.invalidate(b.origin,2);
    assert(!d.wet_at({5,0.01,1}));
    assert(!d.publish(tp::extract(b)));
    assert(d.tick().moved==0&&d.graph().finite()==mass);
    b.revision=2;
    assert(d.publish(tp::extract(b))&&d.graph().finite()==mass);
    // Destruction of all available capacity must not erase mass.
    d.invalidate(b.origin,3);auto solid=b;solid.revision=3;solid.air.assign(solid.air.size(),0);
    assert(!d.publish(tp::extract(solid))&&d.graph().finite()==mass);
    assert(!d.tiles().at(b.origin).available);
    b.revision=3;assert(d.publish(tp::extract(b)));
    assert(d.add_ocean("sea",{1,0,1},0,5,2,true));
    for(int i=0;i<1000;++i)d.tick();
    assert(d.graph().finite()==160000&&d.graph().finite()==d.graph().initial()+d.graph().injected()-d.graph().drained());
    assert(!d.add_ocean("sea",{1,0,1},0,5,2,true));
    auto same=a;same.revision=4;d.invalidate(a.origin,4);
    assert(d.publish(tp::extract(same))&&d.graph().finite()==160000);
    assert(d.graph().portals().size()==2);
    std::cout<<"V3_HYDRAULIC_DOMAIN_PASS regional_publish boundary_flow unload mass_remap ocean_idempotent\n";
}
