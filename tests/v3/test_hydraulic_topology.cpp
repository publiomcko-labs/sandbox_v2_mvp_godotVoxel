#include "core/hydraulic_topology.hpp"
#include <cassert>
#include <iostream>
using namespace sandbox::hydraulic;
namespace tp=topology;
int main(){
    tp::Snapshot s{{0,-4,0},16,16,16,1,1,std::vector<std::uint8_t>(16*16*16,0)};
    auto air=[&](int x,int y,int z){s.air[static_cast<std::size_t>((z*s.nx+x)*s.ny+y)]=1;};
    for(int z=0;z<16;++z)for(int x=0;x<16;++x) {
        for(int y=4;y<12;++y)air(x,y,z);
    }
    auto flat=tp::extract(s);
    assert(flat.compartments.size()==1&&flat.openings.empty());
    assert(flat.compartments[0].curve.capacity()==2048000);
    assert(flat.compartments[0].curve.at_level(2)==512000);
    assert(tp::compartment_at(flat,{3,2,3})==flat.compartments[0].id);
    assert(!tp::compartment_at(flat,{3,-1,3}));
    auto neighbor=s;neighbor.origin.x=16;
    auto adjacent=tp::extract(neighbor);
    auto boundary=tp::connect_faces(flat,adjacent,1);
    assert(boundary.size()==1&&boundary[0].area_m2==128);
    // Two bowls with a higher doorway; lower cave is separate from the
    // above-ground air, even when the surface ocean has the same XZ.
    s.air.assign(s.air.size(),0);
    for(int z=2;z<8;++z)for(int x=1;x<7;++x)for(int y=4;y<12;++y)air(x,y,z);
    for(int z=2;z<8;++z)for(int x=8;x<14;++x)for(int y=4;y<12;++y)air(x,y,z);
    for(int z=3;z<5;++z)for(int y=7;y<10;++y)air(7,y,z);
    for(int z=3;z<5;++z)for(int x=3;x<5;++x)for(int y=0;y<2;++y)air(x,y,z);
    auto rooms=tp::extract(s);
    assert(rooms.compartments.size()==4&&rooms.openings.size()==2);
    auto left=*tp::compartment_at(rooms,{2,1,3}),right=*tp::compartment_at(rooms,{10,1,3});
    auto cave=*tp::compartment_at(rooms,{3,-3,3});
    assert(left!=right&&cave!=left&&cave!=right);
    Graph graph({{"water",1,1000}});
    for(const auto &c:rooms.compartments)graph.add_volume({c.id,0,c.curve,c.id==left?c.curve.at_level(5):0});
    Id id=1;
    for(const auto &p:rooms.openings) {
        assert(p.sill_mm==3000&&p.soffit_mm==6000&&p.area_m2==6);
        graph.add_portal({id++,p.a,p.b,double(p.sill_mm)/1000,p.area_m2,0.62,true,rooms.revision});
    }
    for(int i=0;i<500;++i)graph.tick();
    assert(graph.volumes().at(right).litres>0&&graph.volumes().at(cave).litres==0);
    assert(graph.finite()==graph.initial());
    // Opening removed in a newer terrain snapshot.
    for(int z=3;z<5;++z)for(int y=7;y<10;++y)s.air[static_cast<std::size_t>((z*s.nx+7)*s.ny+y)]=0;
    ++s.revision;auto closed=tp::extract(s);
    assert(closed.openings.empty()&&closed.revision==2);
    // Open slope: five formerly separate height bands, one basin.
    tp::Snapshot slope{{0,0,0},5,10,4,1,1,std::vector<std::uint8_t>(5*10*4,0)};
    for(int z=0;z<4;++z)for(int x=0;x<5;++x)for(int y=x;y<10;++y)
        slope.air[static_cast<std::size_t>((z*5+x)*10+y)]=1;
    auto basin=tp::extract(slope);
    assert(basin.compartments.size()==1&&basin.openings.empty());
    assert(basin.compartments.front().curve.at_level(2)==12000);
    assert(basin.compartments.front().curve.capacity()==160000);
    assert(tp::span_at(basin,{3.5,4,1.5})->bottom==3);
    // A saddle cannot communicate two lower minima before overtopping.
    const std::array<int,5> floors{0,1,2,1,0};
    slope.air.assign(slope.air.size(),0);
    for(int z=0;z<4;++z)for(int x=0;x<5;++x)for(int y=floors[static_cast<std::size_t>(x)];y<10;++y)
        slope.air[static_cast<std::size_t>((z*5+x)*10+y)]=1;
    auto saddle=tp::extract(slope);
    assert(saddle.compartments.size()==2&&saddle.openings.size()==1&&saddle.openings.front().sill_mm==2000);
    const auto l=*tp::compartment_at(saddle,{0.5,0.5,1.5}),r=*tp::compartment_at(saddle,{4.5,0.5,1.5});
    assert(l!=r);
    Graph isolated({{"water",1,1000}});
    for(const auto &c:saddle.compartments)isolated.add_volume({c.id,0,c.curve,c.id==l?c.curve.at_level(1):0});
    const auto &opening=saddle.openings.front();
    isolated.add_portal({1,opening.a,opening.b,2,opening.area_m2,0.62,true,1});
    assert(isolated.tick().moved==0&&isolated.volumes().at(r).litres==0);
    // A large drop stays a transfer portal.
    slope.air.assign(slope.air.size(),0);
    for(int z=0;z<4;++z)for(int x=0;x<5;++x)for(int y=x<2?0:4;y<10;++y)
        slope.air[static_cast<std::size_t>((z*5+x)*10+y)]=1;
    auto drop=tp::extract(slope);
    assert(drop.compartments.size()==2&&drop.openings.size()==1);
    std::cout<<"V3_HYDRAULIC_BASIN_PASS five_terraces_one_head independent_minima elevated_saddle waterfall_portal\n";
    std::cout<<"V3_HYDRAULIC_TOPOLOGY_PASS flat_2048m3_one_compartment elevated_sill isolated_cave closed_breach\n";
}
