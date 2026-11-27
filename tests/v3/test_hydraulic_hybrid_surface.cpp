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
    const auto &v=batch.materials.at(0);assert(!v.empty());
    // B2 batches exactly the H14 support/attributes (excluding provably
    // invisible triangles). Synthetic solid island is depth-clipped by
    // terrain; physical occupation is still independently authoritative.
    assert(!d.wet_at({1.5,4.5,1.5}).has_value());
    std::vector<hybrid::Vertex> expected;
    const auto &in=inputs.begin()->second;
    for(const auto &c:in.geometry->compartments) {
        const auto w=std::find_if(in.wet.begin(),in.wet.end(),[&](const auto &item){return item.local==c.id;});
        if(w==in.wet.end())continue;
        const bool exposed=std::any_of(c.spans.begin(),c.spans.end(),[](const auto &span){return span.top==8;});
        for(const auto &patch:surface::build(*in.geometry,c,8))for(std::size_t i=0;i+2<patch.vertices.size();i+=3) {
            bool below=true,above=true;
            std::array<hybrid::Vertex,3> tri{};
            for(std::size_t j=0;j<3;++j) {
                const auto &p=patch.vertices[i+j];
                const double y=w->visual+p.offset,floor=p.floor-(exposed?1.35:0.35);
                tri[j]={p.x,y,p.z,floor,double(patch.ceiling)};
                below=below&&y<floor-0.0001;above=above&&y>double(patch.ceiling)+0.0001;
            }
            if(!below&&!above)expected.insert(expected.end(),tri.begin(),tri.end());
        }
    }
    assert(v.size()==expected.size());
    bool lower=false,upper=false;
    for(std::size_t i=0;i<v.size();++i) {
        const auto &a=v[i],&b=expected[i];
        assert(a.x==b.x&&a.y==b.y&&a.z==b.z&&a.floor==b.floor&&a.ceiling==b.ceiling);
        lower=lower||a.y==1;upper=upper||a.y==5;
    }
    assert(lower&&upper);
    hybrid::CachedTile cache;
    auto first=hybrid::build(in,&cache);auto second=hybrid::build(in,&cache);
    assert(first.materials.at(0).size()==second.materials.at(0).size()&&cache.geometry==in.geometry);
    assert(d.graph().finite()==mass);
    // Read-only cache: no result may be returned for invalidated revision.
    hybrid::Renderer renderer;renderer.poll(inputs);
    d.invalidate(s.origin,2);auto invalid=hybrid::snapshot(d,8);assert(invalid.empty());
    for(int i=0;i<100;++i){assert(renderer.poll(invalid).empty());std::this_thread::yield();}
    assert(d.graph().finite()==mass);
    std::cout<<"V3_HYBRID_R1_PASS layers=2 baseline_support_equivalent=1 dry_island_physics=1 mass="<<mass<<" triangles="<<v.size()/3<<" stale_rejected=1\n";
}
