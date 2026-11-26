#include "core/hydraulic_domain.hpp"
#include "core/hydraulic_surface.hpp"
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
    assert(!d.tiles().at(b.origin).renderable()); // edited revision: no stale surface
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
    const auto equilibrium=d.graph().finite();
    std::cout<<"V3_HYDRAULIC_DOMAIN_EQUILIBRIUM litres="<<equilibrium<<" target=160000\n";
    // Discrete litres cannot always equalize two heads without reversing
    // their ordering. The ledger is exact; allow two litres of residual
    // difference from the continuous target across these two tanks.
    assert(std::abs(equilibrium-160000)<=2&&equilibrium==d.graph().initial()+d.graph().injected()-d.graph().drained());
    assert(!d.add_ocean("sea",{1,0,1},0,5,2,true));
    auto same=a;same.revision=4;d.invalidate(a.origin,4);
    assert(d.publish(tp::extract(same))&&d.graph().finite()==equilibrium);
    assert(d.graph().portals().size()==2);
    // Unchanged unloaded geometry remains renderable; physics is closed.
    assert(d.tiles().at(b.origin).renderable());
    // Unload a neighbour whose own revision is older than its shared portal.
    d.invalidate(b.origin,3);
    for(const auto &[id,p]:d.graph().portals()) {
        (void)id;
        for(const auto &[local,node]:d.tiles().at(b.origin).ids) {
            (void)local;
            if(p.a==node||p.b==node)assert(!p.available);
        }
    }
    assert(d.tiles().at(b.origin).renderable());
    tp::Snapshot shape{{0,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
    for(int z=1;z<=2;++z)for(int x=1;x<=2;++x)for(int y=1;y<8;++y)
        shape.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
    auto geo=tp::extract(shape);
    const auto patches=surface::build(geo,geo.compartments.front());
    bool apron=false;
    for(const auto &patch:patches)for(auto p:patch.vertices)if(p.x<1.0||p.x>3.0||p.z<1.0||p.z>3.0)apron=true;
    assert(apron);
    assert(!patches.empty());
    bool diagonal=false;
    for(const auto &patch:patches)for(std::size_t i=0;i<patch.vertices.size();i+=3)
        for(std::size_t j=0;j<3;++j) {
            const auto a0=patch.vertices[i+j],b0=patch.vertices[i+(j+1)%3];
            assert(a0.x>=0&&a0.x<=4&&a0.z>=0&&a0.z<=4);
            if(std::abs(a0.x-b0.x)>0.01&&std::abs(a0.z-b0.z)>0.01)diagonal=true;
        }
    assert(diagonal);
    // The mesh is static across levels but its UV floor varies
    // continuously across the basin. Shader clips at the current head.
    tp::Snapshot slope{{0,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
    for(int z=0;z<4;++z)for(int x=0;x<4;++x)for(int y=x;y<8;++y)
        slope.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
    auto sloped=tp::extract(slope);
    assert(sloped.compartments.size()==1);
    auto sheet=surface::build(sloped,sloped.compartments.front());
    assert(sheet.size()==1);
    double min_floor=100,max_floor=-100;bool interpolates=false;
    for(std::size_t i=0;i<sheet.front().vertices.size();i+=3) {
        const auto &v=sheet.front().vertices;
        for(std::size_t j=0;j<3;++j){
            min_floor=std::min(min_floor,v[i+j].floor);max_floor=std::max(max_floor,v[i+j].floor);
            if(std::abs(v[i+j].floor-v[i+(j+1)%3].floor)>0.1)interpolates=true;
        }
    }
    assert(min_floor==0&&max_floor==3&&interpolates);
    // Adjacent higher basin: apron is limited by the neighboring floor,
    // not allowed to remain as a second surface above its open space.
    tp::Snapshot cliff{{0,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
    for(int z=0;z<4;++z)for(int x=0;x<4;++x)for(int y=x<2?0:4;y<8;++y)
        cliff.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
    auto divided=tp::extract(cliff);
    const auto low=*tp::compartment_at(divided,{0.5,1,0.5});
    bool capped=false;
    for(const auto &c:divided.compartments)if(c.id==low)
        for(const auto &patch:surface::build(divided,c)) {
            if(patch.ceiling==4)for(auto v:patch.vertices)if(v.x>2.0)capped=true;
            if(patch.ceiling==8)for(auto v:patch.vertices)assert(v.x<=2.0+1e-8);
        }
    assert(capped);
    std::cout<<"V3_HYDRAULIC_BANK_APRON_PASS solid_overlap capped_at_neighbor_floor\n";
    std::cout<<"V3_HYDRAULIC_BASIN_SURFACE_PASS interpolated_floor one_static_sheet\n";
    std::cout<<"V3_HYDRAULIC_CONTOUR_PASS diagonal_edges tile_bounds retained_unloaded\n";
    std::cout<<"V3_HYDRAULIC_DOMAIN_PASS regional_publish boundary_flow unload mass_remap ocean_idempotent\n";
}
