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
    // H11: republishing the active side must retain certified geometry
    // of the inactive neighbour, without reopening its physical portal.
    Domain cached({{"water",1,1000}},4,4,1,0);
    auto ca=a,cb=a;cb.origin.x=4;
    assert(cached.publish(tp::extract(ca))&&cached.publish(tp::extract(cb)));
    assert(cached.seed_finite("a",{1,0.1,1},0,4,true));
    assert(cached.seed_finite("b",{5,0.1,1},0,3.974,true));
    const auto cached_mass=cached.graph().finite();
    cached.invalidate(cb.origin,1);
    cached.invalidate(ca.origin,2);ca.revision=2;
    assert(cached.publish(tp::extract(ca)));
    assert(cached.graph().portals().size()==1&&!cached.graph().portals().begin()->second.available);
    const auto c1=cached.tiles().at(ca.origin).ids.begin()->second,c2=cached.tiles().at(cb.origin).ids.begin()->second;
    const auto common=cached.graph().presentation_heads({c1,c2},0.15,true);
    assert(common.at(c1)==common.at(c2));
    assert(cached.tick().moved==0&&cached.graph().finite()==cached_mass);
    cached.invalidate(cb.origin,2);
    cached.invalidate(ca.origin,3);ca.revision=3;
    assert(cached.publish(tp::extract(ca))&&cached.graph().portals().empty());
    assert(cached.graph().finite()==cached_mass);
    std::cout<<"V3_HYDRAULIC_CACHED_RECONNECT_PASS visual_only closed_physics edited_neighbour_excluded\n";
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
    const auto high=*tp::compartment_at(divided,{3.5,5,0.5});
    auto falls=surface::flow_faces(divided,high,divided,low,4000,8000,8,6,1,64);
    assert(falls.size()==4);
    for(const auto &q:falls){assert(q.bottom==1&&q.top==6&&q.x0<2&&q.x0>1.9);}
    assert(surface::flow_faces(divided,high,divided,low,4000,8000,8,3,1,64).empty());
    assert(surface::flow_faces(divided,high,divided,low,4000,8000,8,6,6,64).empty());
    assert(surface::flow_faces(divided,high,divided,low,3000,8000,8,6,1,64).empty());
    assert(surface::flow_faces(divided,high,divided,low,4000,8000,8,6,1,1).size()==1);
    const auto ga=tp::extract(a),gb=tp::extract(b);
    const auto seam=surface::flow_faces(ga,ga.compartments.front().id,gb,gb.compartments.front().id,0,8000,8,3,1,64);
    assert(seam.size()==4);
    for(const auto &q:seam)assert(q.x0>4&&q.x0<4.1&&q.top==3&&q.bottom==1);
    const auto fine_seam=surface::flow_faces(ga,ga.compartments.front().id,gb,gb.compartments.front().id,0,8000,8,3.01,3,64,0.0005,0.0);
    assert(fine_seam.size()==4);
    for(const auto &q:fine_seam)assert(q.x0==4&&q.x1==4&&q.top==3.01&&q.bottom==3);
    assert(surface::flow_faces(ga,ga.compartments.front().id,gb,gb.compartments.front().id,0,8000,8,3,3,64,0.0005,0.0).empty());
    std::cout<<"V3_HYDRAULIC_FINE_SEAM_PASS exact_boundary sub_centimetre_drop\n";
    std::cout<<"V3_HYDRAULIC_FLOW_FACE_PASS exposed_drop actual_sill cross_tile bounded\n";
    // Four independent high-drop columns share a square. Their exposed
    // surfaces must tile the whole 2x2 footprint exactly once, including
    // the three-label junction inside a triangle. Ignore capped aprons.
    tp::Snapshot junction{{0,0,0},2,16,2,1,1,std::vector<std::uint8_t>(2*16*2,0)};
    const std::array<int,4> junction_floors{0,4,8,12};
    for(int z=0;z<2;++z)for(int x=0;x<2;++x)
        for(int y=junction_floors[z*2+x];y<16;++y)
            junction.air[static_cast<std::size_t>((z*2+x)*16+y)]=1;
    auto j=tp::extract(junction);
    assert(j.compartments.size()==4);
    double total_area=0;
    for(const auto &c:j.compartments)for(const auto &patch:surface::build(j,c))if(patch.ceiling==16)
        for(std::size_t i=0;i<patch.vertices.size();i+=3) {
            const auto a0=patch.vertices[i],b0=patch.vertices[i+1],c0=patch.vertices[i+2];
            total_area+=std::abs((b0.x-a0.x)*(c0.z-a0.z)-(b0.z-a0.z)*(c0.x-a0.x))*0.5;
        }
    assert(std::abs(total_area-4.0)<1e-8);
    std::cout<<"V3_HYDRAULIC_JUNCTION_PASS shared_diagonal three_owner_partition area="<<total_area<<"\n";
    // H6 primary exposed geometry must cover every certified open column,
    // including the diagonal corners the old binary contour cut away.
    tp::Snapshot footprint{{0,0,0},2,8,2,1,1,std::vector<std::uint8_t>(2*8*2,0)};
    for(int y=1;y<8;++y)footprint.air[static_cast<std::size_t>(y)]=1;
    auto foot=tp::extract(footprint);
    const auto full=surface::build(foot,foot.compartments.front(),8);
    assert(!full.empty()&&full.front().vertices.size()==6);
    double primary_area=0;
    for(std::size_t i=0;i<full.front().vertices.size();i+=3) {
        const auto a0=full.front().vertices[i],b0=full.front().vertices[i+1],c0=full.front().vertices[i+2];
        primary_area+=std::abs((b0.x-a0.x)*(c0.z-a0.z)-(b0.z-a0.z)*(c0.x-a0.x))*0.5;
        for(auto p:{a0,b0,c0})assert(p.x>=0&&p.x<=1&&p.z>=0&&p.z<=1&&p.floor<=1);
    }
    assert(primary_area==1);
    auto precise=footprint;
    precise.surface_floor={0.2f,0.4f,0.6f,0.4f,0.6f,0.8f,0.6f,0.8f,1.0f};
    auto pg=tp::extract(precise);
    const auto precise_patches=surface::build(pg,pg.compartments.front(),8);
    bool full_corner=false;
    for(const auto &patch:precise_patches)for(auto p:patch.vertices)
        if(p.x==2&&p.z==2&&p.floor==1.0)full_corner=true;
    assert(full_corner);
    std::cout<<"V3_HYDRAULIC_FULL_SDF_APRON_PASS complete_adjacent_column actual_corners\n";
    bool corner_apron=false;
    for(const auto &patch:full)for(auto p:patch.vertices)if(p.x>1&&p.z>1)corner_apron=true;
    assert(corner_apron);
    // The same SDF zero crossing produces exactly the same UV floor
    // on both independently extracted sides of a tile boundary.
    auto sa=a,sb=b;
    sa.surface_floor.assign(25,0.25f);sb.surface_floor.assign(25,0.25f);
    auto ra=tp::extract(sa),rb=tp::extract(sb);
    for(const auto &patch:surface::build(ra,ra.compartments.front(),8))
        for(auto p:patch.vertices)if(p.x==4)assert(p.floor==0.25);
    for(const auto &patch:surface::build(rb,rb.compartments.front(),8))
        for(auto p:patch.vertices)if(p.x==0)assert(p.floor==0.25);
    assert(ra.compartments.front().curve.capacity()==ga.compartments.front().curve.capacity());
    std::cout<<"V3_HYDRAULIC_SDF_SHORE_PASS shared_vertex_floor corner_apron unchanged_capacity\n";
    const auto full_slope=surface::build(sloped,sloped.compartments.front(),8);
    assert(full_slope.size()==1&&full_slope.front().vertices.size()==4*4*6);
    const auto full_low=surface::build(divided,*std::find_if(divided.compartments.begin(),divided.compartments.end(),[&](const auto &c){return c.id==low;}),8);
    bool full_bank=false;
    for(const auto &patch:full_low)if(patch.ceiling==4)
        for(auto p:patch.vertices)if(p.x>2)full_bank=true;
    assert(full_bank);
    // Two connected tiles initialize at the same declared head. A third
    // tile behind a sill above the head and an isolated cave remain dry.
    Domain initial({{"water",1,1000}},4,4,1,0);
    auto raised=b;raised.origin.x=8;
    for(int z=0;z<4;++z)for(int x=0;x<4;++x)for(int y=0;y<4;++y)
        raised.air[static_cast<std::size_t>((z*4+x)*8+y)]=0;
    auto initial_a=a;
    for(int y=2;y<4;++y)initial_a.air[static_cast<std::size_t>(y)]=0;
    assert(initial.publish(tp::extract(initial_a))&&initial.publish(tp::extract(b)));
    std::set<sandbox::core::Region> window{a.origin,b.origin,raised.origin};
    assert(!initial.seed_surface_basin("initial",{1,0.1,1},0,3,8,window));
    assert(initial.graph().finite()==0);
    assert(initial.publish(tp::extract(raised)));
    std::set<sandbox::core::Region> frontier;
    assert(!initial.seed_surface_basin("initial",{1,0.1,1},0,3,8,window,&frontier));
    assert(frontier.contains({-4,0,0})&&frontier.contains({4,0,4}));
    assert(!frontier.contains({12,0,0})&&initial.graph().finite()==0);
    std::cout<<"V3_HYDRAULIC_SOURCE_FRONTIER_PASS no_seed_before_boundary_survey\n";
    assert(initial.seed_surface_basin("initial",{1,0.1,1},0,3,8,window));
    const auto ia=*initial.volume_at({1,1,1}),ib=*initial.volume_at({5,1,1});
    assert(std::abs(initial.graph().volumes().at(ia).level()-3)<0.001);
    assert(std::abs(initial.graph().volumes().at(ib).level()-3)<0.001);
    assert(!initial.wet_at({0.5,0.5,0.5})&&!initial.wet_at({8.5,4.1,0.5}));
    const auto initial_mass=initial.graph().finite();
    assert(initial_mass>0&&!initial.seed_surface_basin("initial",{1,0.1,1},0,3,8,window));
    assert(initial.graph().finite()==initial_mass);
    std::cout<<"V3_HYDRAULIC_INITIAL_BASIN_PASS common_head cross_tile closed_sill covered_dry idempotent\n";
    std::cout<<"V3_HYDRAULIC_FULL_FOOTPRINT_PASS full_column no_diagonal_cut capped_apron\n";
    // An edit on a shared tile boundary: the higher dry bank is
    // carved below the pond head. Both old portals close until their
    // new topology is published. No source or mass is recreated.
    Domain bank({{"water",1,1000}},4,4,1,0);
    tp::Snapshot pond{{0,0,0},4,8,4,1,1,std::vector<std::uint8_t>(4*8*4,1)};
    auto dry_bank=pond;dry_bank.origin.x=4;
    for(int z=0;z<4;++z)for(int x=0;x<4;++x)for(int y=0;y<4;++y)
        dry_bank.air[static_cast<std::size_t>((z*4+x)*8+y)]=0;
    assert(bank.publish(tp::extract(pond))&&bank.publish(tp::extract(dry_bank)));
    assert(bank.seed_finite("bank_pond",{2,0.1,2},0,2,true));
    assert(bank.tick().moved==0&&!bank.wet_at({4.5,0.1,2.5}));
    const auto bank_mass=bank.graph().finite();
    bank.invalidate(pond.origin,2);bank.invalidate(dry_bank.origin,2);
    pond.revision=2;dry_bank.revision=2;
    for(int z=1;z<=2;++z)for(int x=0;x<=1;++x)for(int y=0;y<4;++y)
        dry_bank.air[static_cast<std::size_t>((z*4+x)*8+y)]=1;
    assert(bank.publish(tp::extract(pond))&&bank.tick().moved==0);
    assert(bank.publish(tp::extract(dry_bank)));
    assert(bank.tick().moved>0);
    for(int i=0;i<100;++i)bank.tick();
    assert(bank.wet_at({4.5,0.1,2.5})&&bank.wet_at({5.5,0.1,1.5}));
    assert(!bank.wet_at({7.5,0.1,2.5})&&bank.graph().finite()==bank_mass);
    std::cout<<"V3_HYDRAULIC_BANK_EDIT_PASS lateral_breach cross_tile conservative_reconnect\n";
    std::cout<<"V3_HYDRAULIC_BANK_APRON_PASS solid_overlap capped_at_neighbor_floor\n";
    std::cout<<"V3_HYDRAULIC_BASIN_SURFACE_PASS interpolated_floor one_static_sheet\n";
    std::cout<<"V3_HYDRAULIC_CONTOUR_PASS diagonal_edges tile_bounds retained_unloaded\n";
    std::cout<<"V3_HYDRAULIC_DOMAIN_PASS regional_publish boundary_flow unload mass_remap ocean_idempotent\n";
}
