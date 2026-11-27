#include "core/hydraulic_hybrid_surface.hpp"
#include <cassert>
#include <iostream>
#include <thread>
using namespace sandbox::hydraulic;
int main(){
    tp::Snapshot s{{0,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
    // Ring with dry central island, separate covered lower interval
    // beneath the same XZ coordinates. No global height mask.
    for(int z=0;z<4;++z)for(int x=0;x<4;++x) {
        if(x==1&&z==1)continue;
        for(int y=4;y<8;++y)s.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
        for(int y=0;y<2;++y)s.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
    }
    Domain d({{"water",1,1000}},4,4,1,0);
    assert(d.publish(tp::extract(s)));
    assert(d.seed_finite("upper",{0.5,4.1,0.5},0,5,true));
    assert(d.seed_finite("lower",{0.5,0.1,0.5},0,1,true));
    auto inputs=hybrid::snapshot(d,8);assert(inputs.size()==1);
    const auto mass=d.graph().finite();
    auto batch=hybrid::build(inputs.begin()->second);
    const auto &v=batch.materials.at(0);assert(v.size()==15*2*6);
    std::map<double,double> areas;
    for(std::size_t i=0;i<v.size();i+=3){
        const auto &a=v[i],&b=v[i+1],&c=v[i+2];
        const double x=(a.x+b.x+c.x)/3,z=(a.z+b.z+c.z)/3;
        assert(!(x>1&&x<2&&z>1&&z<2));
        areas[a.y]+=((b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x))*0.5;
    }
    assert(areas.size()==2&&areas.at(1)==15&&areas.at(5)==15);
    assert(d.graph().finite()==mass);
    // Read-only cache: no result may be returned for invalidated revision.
    hybrid::Renderer renderer;renderer.poll(inputs);
    d.invalidate(s.origin,2);auto invalid=hybrid::snapshot(d,8);assert(invalid.empty());
    for(int i=0;i<100;++i){assert(renderer.poll(invalid).empty());std::this_thread::yield();}
    assert(d.graph().finite()==mass);
    std::cout<<"V3_HYBRID_R1_PASS layers=2 area_per_layer=15 dry_island=1 mass="<<mass<<" triangles="<<v.size()/3<<" stale_rejected=1\n";
}
