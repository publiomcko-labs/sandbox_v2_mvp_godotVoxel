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
    // I2: a variable head shared edge is identical even when built
    // independently on each tile. A second layer stays independent,
    // and a dry open column receives no rendered primary triangle.
    tp::Snapshot left{{0,0,0},2,8,2,1,1,std::vector<std::uint8_t>(2*8*2,1)};
    auto right=left;right.origin.x=2;
    hybrid::Input il{left.origin,std::make_shared<const tp::Result>(tp::extract(left)),{},8,{}};
    hybrid::Input ir{right.origin,std::make_shared<const tp::Result>(tp::extract(right)),{},8,{}};
    hybrid::Cell u{1,0,0,8000,0,2.0,{2,2,2,2}},w{2,0,0,8000,0,2.5,{2.5,2.5,2.5,2.5}};
    il.cells={u};il.neighbors={w};ir.cells={w};ir.neighbors={u};
    const auto al=hybrid::build(il),ar=hybrid::build(ir);
    std::set<std::pair<double,double>> le,re;
    for(const auto &p:al.materials.at(0)){assert(p.x>=1&&p.x<=2);if(p.x==2)le.insert({p.z,p.y});}
    for(const auto &p:ar.materials.at(0)){assert(p.x>=2&&p.x<=3);if(p.x==2)re.insert({p.z,p.y});}
    assert(le==re&&le.size()==2&&le.begin()->second==2.25);
    // Distinct covered layer, different free surface, no accidental join.
    il.cells.push_back({1,0,0,1000,0,0.5,{0.5,0.5,0.5,0.5}});
    const auto layers=hybrid::build(il);
    bool has_lower=false;
    for(const auto &p:layers.materials.at(0))if(p.ceiling==1){has_lower=true;assert(p.y==0.5);}
    assert(has_lower);
    // I7: a changed dry-bank input with no visible output must become
    // current without requesting another empty Godot mesh publication.
    hybrid::Input empty{left.origin,il.geometry,{},8,{}};
    empty.layered=true;
    hybrid::Renderer cached_renderer;
    std::map<sandbox::core::Region,hybrid::Input> desired{{empty.tile,empty}};
    auto await_current=[&](std::size_t expected_updates){
        std::size_t updates=0;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
        while(!cached_renderer.current(desired.begin()->second)&&std::chrono::steady_clock::now()<deadline){
            updates+=cached_renderer.poll(desired).size();
            std::this_thread::yield();
        }
        assert(cached_renderer.current(desired.begin()->second));
        assert(updates==expected_updates);
    };
    await_current(1);
    desired.begin()->second.adjacent_geometry.insert(right.origin);
    await_current(0);
    desired.clear();cached_renderer.poll(desired);
    desired.emplace(empty.tile,empty);
    await_current(1);
    // I7b: only exposed border donors require a dry target. Dirty
    // groups include old ownership links and diagonal neighbors.
    assert(hybrid::bank_has_donor(il,right.origin));
    auto interior=il;
    interior.cells={{0,0,0,8000,0,2.0,{2,2,2,2}}};
    assert(!hybrid::bank_has_donor(interior,right.origin));
    interior.cells={{1,0,0,1000,0,0.5,{0.5,0.5,0.5,0.5}}};
    assert(!hybrid::bank_has_donor(interior,right.origin));
    auto a=il,b=ir,c=ir;
    c.tile.x=20;
    a.adjacent_geometry={};b.adjacent_geometry={};c.adjacent_geometry={};
    auto prev=a;prev.adjacent_geometry.insert(b.tile);
    const auto groups=hybrid::dirty_groups({a,b,c},{{a.tile,prev}});
    assert(groups.at(a.tile)==groups.at(b.tile)&&groups.at(a.tile)!=groups.at(c.tile));
    // I8: a solid bank beside two connected, unequal wet heads must
    // share exact edge elevations with both primary and adjacent bank
    // triangles, not a per-donor plane offset by 3mm.
    tp::Snapshot bank{{0,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,0)};
    for(int z=0;z<2;++z)for(int y=0;y<8;++y)bank.air[static_cast<std::size_t>(z*4*8+y)]=1;
    bank.surface_floor.assign(25,0.0f);
    hybrid::Input bi{bank.origin,std::make_shared<const tp::Result>(tp::extract(bank)),{},8,{}};
    bi.layered=true;
    bi.cells={{0,0,0,8000,0,2.0,{2,2,2,2}},{0,1,0,8000,0,2.5,{2.5,2.5,2.5,2.5}}};
    const auto bm=hybrid::build(bi);
    const auto &bv=bm.materials.at(0);
    assert(bv.size()>12);
    std::set<double> shared_heights,outer_heights;
    for(const auto &p:bv){
        if(p.x==1&&p.z==1)shared_heights.insert(p.y);
        if(p.x==2&&p.z==1)outer_heights.insert(p.y);
    }
    assert(shared_heights.size()==1&&*shared_heights.begin()==2.25);
    assert(outer_heights.size()==1&&*outer_heights.begin()==2.25);
    std::cout<<"V3_HYBRID_I8_BANK_EDGE_PASS\n";
    std::cout<<"V3_HYBRID_I7_GROUPS_PASS\n";
    std::cout<<"V3_HYBRID_I7_IDENTICAL_OUTPUT_PASS\n";
    std::cout<<"V3_HYBRID_I2_SURFACE_PASS shared_edge=1 dry_primary=1 independent_layer=1\n";
    std::cout<<"V3_HYBRID_R1_PASS layers=2 baseline_support_equivalent=1 dry_island_physics=1 mass="<<mass<<" triangles="<<v.size()/3<<" stale_rejected=1\n";
}
