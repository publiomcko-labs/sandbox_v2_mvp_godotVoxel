#include "v3_world_session.hpp"
#include "world_bootstrap.hpp"
#include <godot_cpp/classes/voxel_lod_terrain.hpp>
#include <godot_cpp/classes/voxel_stream.hpp>
#include <godot_cpp/classes/voxel_stream_sq_lite.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include "persistence/checkpoint.hpp"
#include "content_registry/geology.hpp"
#include "content_registry/caves.hpp"
#include "content_registry/fluid_profile.hpp"
#include "persistence/fluid_store.hpp"
#include "core/fluid_surface.hpp"
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/classes/voxel_buffer.hpp>
#include <godot_cpp/classes/voxel_tool.hpp>
#include <godot_cpp/classes/voxel_format.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {
namespace sc = sandbox::core;
namespace ct = sandbox::content;
namespace ps = sandbox::persistence;
namespace fs = std::filesystem;
namespace fl = sandbox::fluid;

namespace {
std::string narrow(const String &s) { return s.utf8().get_data(); }
fs::path path_of(const String &s) { return fs::u8path(narrow(s)); }
String gd_path(const fs::path &p) {
    const auto utf8=p.generic_u8string();
    return String::utf8(reinterpret_cast<const char *>(utf8.c_str()));
}
bool same_path(const String &p,const fs::path &expected) {
    const auto actual=fs::absolute(path_of(p)).lexically_normal();
    return actual==expected && ct::checked_root(actual.parent_path())==expected.parent_path();
}
// Read-modify-paste both authoritative voxel channels together. Only newly
// solid samples receive the selected material; carving preserves geology.
sc::ApplyResult material_brush(WorldBootstrap *world,const sc::Brush &b) {
    if (!world->can_edit_sphere(Vector3(b.center.x,b.center.y,b.center.z),b.radius_m))
        return sc::ApplyResult::deferred;
    auto *terrain=Object::cast_to<VoxelLodTerrain>(world->get_node_or_null(NodePath("Terrain")));
    if(!terrain) return sc::ApplyResult::rejected;
    auto tool=terrain->get_voxel_tool();
    if(tool.is_null()) return sc::ApplyResult::rejected;
    const Vector3 center(b.center.x,b.center.y,b.center.z);
    const Vector3 extent(b.radius_m+1,b.radius_m+1,b.radius_m+1);
    const Vector3i origin((center-extent).floor());
    const Vector3i end((center+extent).ceil());
    const Vector3i size=end-origin+Vector3i(1,1,1);
    if(!tool->is_area_editable(AABB(Vector3(origin),Vector3(size)))) return sc::ApplyResult::deferred;
    Ref<VoxelBuffer> buffer;
    buffer.instantiate();
    buffer->set_channel_depth(VoxelBuffer::CHANNEL_INDICES,VoxelBuffer::DEPTH_8_BIT);
    buffer->create(size.x,size.y,size.z);
    constexpr int sdf=VoxelBuffer::CHANNEL_SDF, indices=VoxelBuffer::CHANNEL_INDICES;
    constexpr int mask=(1<<sdf)|(1<<indices);
    tool->copy(origin,buffer,mask,false);
    bool changed=false;
    for(int z=0;z<size.z;++z) for(int x=0;x<size.x;++x) for(int y=0;y<size.y;++y) {
        const double shape=Vector3(origin+Vector3i(x,y,z)).distance_to(center)-b.radius_m;
        if(shape>1) continue;
        const double old=buffer->get_voxel_f(x,y,z,sdf);
        const double next=b.add?std::min(old,shape):std::max(old,-shape);
        if(next==old) continue;
        const auto raw=buffer->get_voxel(x,y,z,sdf);
        buffer->set_voxel_f(next,x,y,z,sdf);
        if(buffer->get_voxel(x,y,z,sdf)!=raw) {
            changed=true;
            if(b.add && old>=0 && buffer->get_voxel_f(x,y,z,sdf)<0)
                buffer->set_voxel(b.material_slot,x,y,z,indices);
        }
    }
    if(!changed) return sc::ApplyResult::no_effect;
    tool->paste(origin,buffer,mask);
    return sc::ApplyResult::applied;
}
class VoxelAdapter : public sc::TerrainAdapter {
public:
    WorldBootstrap *world=nullptr;
    sc::ApplyResult apply(const sc::Brush &b) noexcept override {
        if (!world) return sc::ApplyResult::rejected;
        if(b.material_slot>=0) return material_brush(world,b);
        const Vector3 center(b.center.x,b.center.y,b.center.z);
        if (!world->can_edit_sphere(center,b.radius_m)) return sc::ApplyResult::deferred;
        return world->edit_sphere(center,b.add,b.radius_m)
            ? sc::ApplyResult::applied : sc::ApplyResult::deferred;
    }
};
fl::Cell fluid_cell(Vector3 p) {return {static_cast<int>(std::floor(p.x)),static_cast<int>(std::floor(p.y)),static_cast<int>(std::floor(p.z))};}
fl::Passage probe_cell(const Ref<VoxelTool> &tool,fl::Cell p) {
    if(tool.is_null()||!fl::valid(p))return fl::Passage::unavailable;
    const Vector3i base(p.x,p.y,p.z);
    if(!tool->is_area_editable(AABB(Vector3(base),Vector3(2,2,2))))return fl::Passage::unavailable;
    // All eight corners of a 1m cell must be air. Subcell apertures
    // are deliberately impermeable at this resolution.
    for(int x=0;x<=1;++x)for(int y=0;y<=1;++y)for(int z=0;z<=1;++z)
        if(tool->get_voxel_f(base+Vector3i(x,y,z))<=0.1)return fl::Passage::solid;
    return fl::Passage::open;
}
Ref<VoxelTool> fluid_tool(WorldBootstrap *world) {
    if(!world)return {};
    auto *terrain=Object::cast_to<VoxelLodTerrain>(world->get_node_or_null(NodePath("Terrain")));
    if(!terrain)return {};
    auto tool=terrain->get_voxel_tool();
    if(tool.is_valid())tool->set_channel(VoxelBuffer::CHANNEL_SDF);
    return tool;
}
const char *status_name(sc::CommandResult r) {
    switch(r) {
        case sc::CommandResult::accepted: return "accepted";
        case sc::CommandResult::no_effect: return "no_effect";
        case sc::CommandResult::deferred: return "deferred";
        case sc::CommandResult::rejected: return "rejected";
        case sc::CommandResult::duplicate: return "duplicate";
        case sc::CommandResult::out_of_order: return "out_of_order";
        case sc::CommandResult::backpressure: return "backpressure";
    }
    return "rejected";
}
}
struct V3WorldSession::State {
    std::shared_ptr<const ct::Snapshot> snapshot;
    ps::CheckpointStore store;
    VoxelAdapter adapter;
    sc::InterestWindow interest;
    std::optional<ct::GeologyPalette> geology;
    ct::Json caves;
    std::optional<ct::FluidProfile> fluid_profile;
    std::unique_ptr<fl::Solver> fluids;
    std::set<std::string> seeded;
    Vector3 interest_position;
    fl::TickReport fluid_report;
    std::unique_ptr<sc::WorldCore<>> core;
    uint64_t bound_world=0;
};
V3WorldSession::V3WorldSession()=default;
V3WorldSession::~V3WorldSession()=default;
void V3WorldSession::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open","first_party","external","world_root","world_id","seed"), &V3WorldSession::open);
    ClassDB::bind_method(D_METHOD("open_geology","first_party","external","world_root","world_id","seed","geology_root","profile"), &V3WorldSession::open_geology);
    ClassDB::bind_method(D_METHOD("open_caves","first_party","external","world_root","world_id","seed","geology_root","profile","cave_root","cave_profile"), &V3WorldSession::open_caves);
    ClassDB::bind_method(D_METHOD("open_fluids","first_party","external","world_root","world_id","seed","geology_root","profile","cave_root","cave_profile","fluid_root"), &V3WorldSession::open_fluids);
    ClassDB::bind_method(D_METHOD("get_fluid_json"), &V3WorldSession::get_fluid_json);
    ClassDB::bind_method(D_METHOD("get_seeded_reservoirs"), &V3WorldSession::get_seeded_reservoirs);
    ClassDB::bind_method(D_METHOD("seed_reservoir","world","id","cells"), &V3WorldSession::seed_reservoir);
    ClassDB::bind_method(D_METHOD("fluid_at","point"), &V3WorldSession::fluid_at);
    ClassDB::bind_method(D_METHOD("fluid_cells","lo","hi"), &V3WorldSession::fluid_cells);
    ClassDB::bind_method(D_METHOD("fluid_surface_tile","origin"), &V3WorldSession::fluid_surface_tile);
    ClassDB::bind_method(D_METHOD("take_fluid_dirty","budget"), &V3WorldSession::take_fluid_dirty);
    ClassDB::bind_method(D_METHOD("flush_fluids"), &V3WorldSession::flush_fluids);
    ClassDB::bind_method(D_METHOD("get_cave_json"), &V3WorldSession::get_cave_json);
    ClassDB::bind_method(D_METHOD("get_geology_json"), &V3WorldSession::get_geology_json);
    ClassDB::bind_method(D_METHOD("submit_material","world","command","center","add","radius","material_id"), &V3WorldSession::submit_material);
    ClassDB::bind_method(D_METHOD("bind_world","world"), &V3WorldSession::bind_world);
    ClassDB::bind_method(D_METHOD("get_last_error"), &V3WorldSession::get_last_error);
    ClassDB::bind_method(D_METHOD("get_world_path"), &V3WorldSession::get_world_path);
    ClassDB::bind_method(D_METHOD("get_content_ids"), &V3WorldSession::get_content_ids);
    ClassDB::bind_method(D_METHOD("get_record_json","id"), &V3WorldSession::get_record_json);
    ClassDB::bind_method(D_METHOD("get_state"), &V3WorldSession::get_state);
    ClassDB::bind_method(D_METHOD("submit","world","command","center","add","radius"), &V3WorldSession::submit);
    ClassDB::bind_method(D_METHOD("peek_terrain_event"), &V3WorldSession::peek_terrain_event);
    ClassDB::bind_method(D_METHOD("ack_terrain_event","revision"), &V3WorldSession::ack_terrain_event);
    ClassDB::bind_method(D_METHOD("update_interest","position"), &V3WorldSession::update_interest);
    ClassDB::bind_method(D_METHOD("advance_ticks","elapsed_ns","budget"), &V3WorldSession::advance_ticks);
    ClassDB::bind_method(D_METHOD("finish","terrain_saved","rocks_saved"), &V3WorldSession::finish);
}
bool V3WorldSession::open(const String &first_party,const String &external,
                         const String &world_root,const String &world_id,int64_t seed) {
    return open_impl(first_party,external,world_root,world_id,seed,String(),String(),String(),String(),String());
}
bool V3WorldSession::open_geology(const String &first_party,const String &external,
                         const String &world_root,const String &world_id,int64_t seed,
                         const String &geology_root,const String &profile) {
    if(geology_root.is_empty() || profile.is_empty()) return false;
    return open_impl(first_party,external,world_root,world_id,seed,geology_root,profile,String(),String(),String());
}
bool V3WorldSession::open_caves(const String &first_party,const String &external,
                         const String &world_root,const String &world_id,int64_t seed,
                         const String &geology_root,const String &profile,
                         const String &cave_root,const String &cave_profile) {
    if(geology_root.is_empty() || profile.is_empty() || cave_root.is_empty() || cave_profile.is_empty()) return false;
    return open_impl(first_party,external,world_root,world_id,seed,geology_root,profile,cave_root,cave_profile,String());
}
bool V3WorldSession::open_fluids(const String &first_party,const String &external,const String &world_root,
                         const String &world_id,int64_t seed,const String &geology_root,const String &profile,
                         const String &cave_root,const String &cave_profile,const String &fluid_root) {
    if(geology_root.is_empty()||profile.is_empty()||cave_root.is_empty()||cave_profile.is_empty()||fluid_root.is_empty())return false;
    return open_impl(first_party,external,world_root,world_id,seed,geology_root,profile,cave_root,cave_profile,fluid_root);
}
bool V3WorldSession::open_impl(const String &first_party,const String &external,
                         const String &world_root,const String &world_id,int64_t seed,
                         const String &geology_root,const String &profile,
                         const String &cave_root,const String &cave_profile,const String &fluid_root) {
    try {
        ct::require(!state_ && seed>=0,"invalid or already initialized session");
        auto next=std::make_unique<State>();
        std::vector<fs::path> roots{path_of(first_party),path_of(external)};
        if(!geology_root.is_empty()) roots.push_back(path_of(geology_root));
        if(!cave_root.is_empty()) roots.push_back(path_of(cave_root));
        if(!fluid_root.is_empty())roots.push_back(path_of(fluid_root));
        next->snapshot=ct::load(roots,ct::initial_registry());
        std::string generator(ps::generator_version);
        if(!geology_root.is_empty()) {
            next->geology=ct::compile_geology(*next->snapshot,narrow(profile));
            generator="v3_2_single_s4_v1:"+next->geology->profile_id;
        }
        if(!cave_root.is_empty()) {
            next->caves=ct::compile_caves(*next->snapshot,narrow(cave_profile),static_cast<uint64_t>(seed));
            generator="v3_3_caves_v3:"+next->geology->profile_id+":"+narrow(cave_profile);
        }
        if(!fluid_root.is_empty()) {
            next->fluid_profile=ct::compile_fluids(*next->snapshot);
            next->fluids=std::make_unique<fl::Solver>(next->fluid_profile->types);
            generator="v3_4_fluids_v2:"+generator;
        }
        next->store.begin(path_of(world_root),narrow(world_id),static_cast<uint64_t>(seed),next->snapshot->pins,generator);
        if(next->fluids && next->store.header().generation>0)
            next->seeded=ps::load_fluid(next->store.path(),*next->fluids,next->fluid_profile->config);
        const auto c=next->store.header().core;
        constexpr auto limit=static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
        ct::require(c.last_command<limit && c.terrain_revision<limit && c.completed_tick<limit &&
                    c.pending_ns<=limit && next->store.header().generation<limit,
                    "checkpoint exceeds signed Godot API range");
        next->core=std::make_unique<sc::WorldCore<>>(next->adapter,c);
        state_=std::move(next);
        last_error_=String();
        return true;
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return false;}
}
bool V3WorldSession::bind_world(WorldBootstrap *world) {
    try {
        ct::require(state_ && state_->store.is_open() && world && world->is_voxel_ready() &&
                    !state_->bound_world,"invalid world binding");
        auto *terrain=Object::cast_to<VoxelLodTerrain>(world->get_node_or_null(NodePath("Terrain")));
        ct::require(terrain!=nullptr,"terrain missing");
        if(state_->geology) {
            const Ref<VoxelFormat> format=terrain->get_format();
            ct::require(format.is_valid() && format->get_channel_depth(VoxelBuffer::CHANNEL_INDICES)==VoxelBuffer::DEPTH_8_BIT,"wrong geology voxel format");
        }
        const Ref<VoxelStream> stream=terrain->get_stream();
        auto *sqlite=Object::cast_to<VoxelStreamSQLite>(stream.ptr());
        ct::require(sqlite && same_path(sqlite->get_database_path(),state_->store.path()/"terrain.sqlite"),
                    "wrong terrain save path");
        ct::require(static_cast<int64_t>(terrain->get("world_seed"))==static_cast<int64_t>(state_->store.header().seed),
                    "world seed mismatch");
        auto *rocks=world->get_node_or_null(NodePath("RockManager"));
        ct::require(rocks && same_path(static_cast<String>(rocks->get("_save_path")),state_->store.path()/"rocks.json"),
                    "wrong rock save path");
        state_->bound_world=world->get_instance_id();
        last_error_=String();
        return true;
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return false;}
}
String V3WorldSession::get_fluid_json() const {
    if(!state_||!state_->fluid_profile)return {};
    return String::utf8(state_->fluid_profile->config.dump().c_str());
}
Array V3WorldSession::get_seeded_reservoirs() const {
    Array out;
    if(state_)for(const auto &id:state_->seeded)out.push_back(String::utf8(id.c_str()));
    return out;
}
String V3WorldSession::seed_reservoir(WorldBootstrap *world,const String &id,const Array &cells) {
    if(!state_||!state_->fluids||!state_->store.is_open()||!world||
        state_->bound_world!=world->get_instance_id()||cells.size()>4096)return "rejected";
    try {
        const auto key=narrow(id);
        if(state_->seeded.contains(key))return "seeded";
        const ct::Json *rule=nullptr;
        for(const auto &r:state_->fluid_profile->config.at("reservoirs"))
            if(ct::str(r.at("id"))==key)rule=&r;
        if(!rule)return "rejected";
        const int type=rule->at("slot").get<int>();
        const int ax=rule->at("anchor_x").get<int>(),az=rule->at("anchor_z").get<int>();
        auto tool=fluid_tool(world);
        std::set<fl::Cell> candidates;
        for(int64_t i=0;i<cells.size();++i) {
            if(cells[i].get_type()!=Variant::VECTOR3I)return "rejected";
            const Vector3i v=cells[i];
            const fl::Cell p{v.x,v.y,v.z};
            if(!fl::valid(p)||std::abs(p.x-ax)>32||std::abs(p.z-az)>32||p.y< -32||p.y>32)return "rejected";
            const auto pass=probe_cell(tool,p);
            if(pass==fl::Passage::unavailable)return "deferred";
            if(pass==fl::Passage::open && !state_->fluids->at(p).litres)candidates.insert(p);
        }
        if(candidates.empty())return "empty";
        if(state_->fluids->cells().size()+candidates.size()>fl::cell_limit)return "rejected";
        auto open=[](fl::Cell){return fl::Passage::open;};
        for(auto p:candidates)if(!state_->fluids->add(p,type,fl::capacity,open,true))throw std::logic_error("reservoir commit");
        state_->seeded.insert(key);
        return "seeded";
    }catch(const std::exception &e){last_error_=String::utf8(e.what());return "rejected";}
}
Dictionary V3WorldSession::fluid_at(const Vector3 &point) const {
    Dictionary d;
    if(!state_||!state_->fluids||!sc::valid_point({point.x,point.y,point.z}))return d;
    const auto p=fluid_cell(point);const auto a=state_->fluids->at(p);
    if(!a.litres||point.y>=p.y+double(a.litres)/fl::capacity)return d;
    d["slot"]=a.type;d["litres"]=a.litres;d["density"]=state_->fluids->types()[static_cast<std::size_t>(a.type)].density;
    return d;
}
Array V3WorldSession::fluid_cells(const Vector3 &lo,const Vector3 &hi) const {
    Array out;
    if(!state_||!state_->fluids||!sc::valid_point({lo.x,lo.y,lo.z})||!sc::valid_point({hi.x,hi.y,hi.z}))return out;
    try {
        for(auto [p,a]:state_->fluids->query(fluid_cell(lo),fluid_cell(hi),4096)) {
            Array row;row.push_back(Vector3i(p.x,p.y,p.z));row.push_back(a.type);row.push_back(a.litres);out.push_back(row);
        }
    }catch(const std::exception &){}
    return out;
}
Array V3WorldSession::fluid_surface_tile(const Vector3 &origin) const {
    Array out;
    if(!state_||!state_->fluids||!sc::valid_point({origin.x,origin.y,origin.z}))return out;
    const auto base=fluid_cell(origin);
    if(!fl::valid(base)||base.x%8||base.y%8||base.z%8)return out;
    try {
        std::set<int> types;
        for(auto [p,a]:state_->fluids->query(fl::plus(base,{-1,-2,-1}),fl::plus(base,{9,9,9}))) {
            (void)p;types.insert(a.type);
        }
        auto at=[&](fl::Cell p){return state_->fluids->at(p);};
        for(auto type:types) {
            auto m=fl::surface::build(at,base,type);
            if(m.vertices.empty())continue;
            PackedVector3Array vertices,normals;
            vertices.resize(static_cast<int64_t>(m.vertices.size()));
            normals.resize(static_cast<int64_t>(m.vertices.size()));
            for(std::size_t i=0;i<m.vertices.size();++i) {
                const auto &v=m.vertices[i];
                vertices.set(static_cast<int64_t>(i),Vector3(v.position.x,v.position.y,v.position.z));
                normals.set(static_cast<int64_t>(i),Vector3(v.normal.x,v.normal.y,v.normal.z));
            }
            Array row;row.push_back(type);row.push_back(vertices);row.push_back(normals);out.push_back(row);
        }
    }catch(const std::exception &){}
    return out;
}
Array V3WorldSession::take_fluid_dirty(int64_t budget) {
    Array out;
    if(!state_||!state_->fluids||budget<0||budget>4096)return out;
    for(auto p:state_->fluids->take_dirty(static_cast<std::size_t>(budget)))out.push_back(Vector3i(p.x,p.y,p.z));
    return out;
}
bool V3WorldSession::flush_fluids() {
    if(!state_||!state_->store.is_open())return false;
    if(!state_->fluids)return true;
    try {ps::save_fluid(state_->store.path(),*state_->fluids,state_->seeded);return true;}
    catch(const std::exception &e){last_error_=String::utf8(e.what());return false;}
}
String V3WorldSession::get_cave_json() const {
    if(!state_ || state_->caves.is_null()) return {};
    return String::utf8(state_->caves.dump().c_str());
}
String V3WorldSession::get_geology_json() const {
    if(!state_ || !state_->geology) return {};
    return String::utf8(state_->geology->config.dump().c_str());
}
String V3WorldSession::get_last_error() const {return last_error_;}
String V3WorldSession::get_world_path() const {return state_?gd_path(state_->store.path()):String();}
Array V3WorldSession::get_content_ids() const {
    Array a;
    if(state_) for(const auto &r:state_->snapshot->records) a.push_back(String::utf8(r.id.c_str()));
    return a;
}
String V3WorldSession::get_record_json(const String &id) const {
    if(!state_) return {};
    auto it=state_->snapshot->indices.find(narrow(id));
    if(it==state_->snapshot->indices.end()) return {};
    const auto &r=state_->snapshot->records[it->second];
    const auto value=ct::Json{{"id",r.id},{"type",r.type},{"data",r.data}}.dump();
    return String::utf8(value.c_str());
}
Dictionary V3WorldSession::get_state() const {
    Dictionary d;
    if(!state_) return d;
    const auto &core=*state_->core;
    d["terrain_revision"]=static_cast<int64_t>(core.revision());
    d["last_command"]=static_cast<int64_t>(core.last_command());
    d["completed_tick"]=static_cast<int64_t>(core.scheduler().completed());
    d["backlog_ticks"]=static_cast<int64_t>(core.scheduler().backlog());
    d["queued_events"]=static_cast<int64_t>(core.queued_events());
    d["checkpoint_generation"]=static_cast<int64_t>(state_->store.header().generation);
    const auto &regions=state_->interest.regions();
    d["active_regions"]=static_cast<int64_t>(regions.active_count());
    d["aggregate_regions"]=static_cast<int64_t>(regions.aggregate_count());
    d["dormant_regions"]=static_cast<int64_t>(regions.dormant_count());
    if(state_->fluids) {
        d["fluid_litres"]=static_cast<int64_t>(state_->fluids->volume());
        d["fluid_initial_litres"]=static_cast<int64_t>(state_->fluids->initial());
        d["fluid_cells"]=static_cast<int64_t>(state_->fluids->cells().size());
        d["fluid_backlog"]=static_cast<int64_t>(state_->fluids->backlog());
        d["fluid_blocked"]=static_cast<int64_t>(state_->fluid_report.blocked);
        d["fluid_transferred"]=static_cast<int64_t>(state_->fluid_report.transferred);
        d["fluid_substeps"]=static_cast<int64_t>(state_->fluid_report.substeps);
    }
    d["open"]=state_->store.is_open();
    return d;
}
String V3WorldSession::submit(WorldBootstrap *world,int64_t command,const Vector3 &center,bool add,double radius) {
    if(state_ && state_->geology) return "rejected";
    return submit_impl(world,command,center,add,radius,-1);
}
String V3WorldSession::submit_material(WorldBootstrap *world,int64_t command,const Vector3 &center,bool add,double radius,const String &material_id) {
    if(!state_ || !state_->geology) return "rejected";
    const auto slot=state_->geology->slot(narrow(material_id));
    if(slot<0) return "rejected";
    return submit_impl(world,command,center,add,radius,slot);
}
String V3WorldSession::submit_impl(WorldBootstrap *world,int64_t command,const Vector3 &center,bool add,double radius,int slot) {
    if(!state_ || !state_->store.is_open() || !world || !state_->bound_world ||
       state_->bound_world!=world->get_instance_id() || command<=0) return "rejected";
    if(state_->fluids && add && sc::valid_point({center.x,center.y,center.z}) && std::isfinite(radius)&&radius>=0.5&&radius<=8.0) {
        const Vector3 extent(radius+2,radius+2,radius+2);
        try {if(!state_->fluids->query(fluid_cell(center-extent),fluid_cell(center+extent)).empty())return "rejected";}
        catch(const std::exception &){return "rejected";}
    }
    state_->adapter.world=world;
    const auto r=state_->core->submit({static_cast<uint64_t>(command),{center.x,center.y,center.z},radius,add,slot});
    state_->adapter.world=nullptr;
    if(state_->fluids&&r==sc::CommandResult::accepted) {
        const Vector3 extent(radius+2,radius+2,radius+2);
        try {state_->fluids->invalidate(fluid_cell(center-extent),fluid_cell(center+extent));}
        catch(const std::exception &){/* outside bounded fluid domain */}
    }
    return String(status_name(r));
}
Dictionary V3WorldSession::peek_terrain_event() const {
    Dictionary d;
    if(!state_) return d;
    const auto e=state_->core->peek();
    if(!e) return d;
    const auto a=e->bounds.min,b=e->bounds.max;
    d["revision"]=static_cast<int64_t>(e->revision);
    d["command"]=static_cast<int64_t>(e->command);
    d["bounds"]=AABB(Vector3(a.x,a.y,a.z),Vector3(b.x-a.x,b.y-a.y,b.z-a.z));
    return d;
}
bool V3WorldSession::ack_terrain_event(int64_t revision) {
    return state_ && state_->store.is_open() && revision>0 &&
           state_->core->acknowledge(static_cast<uint64_t>(revision));
}
bool V3WorldSession::update_interest(const Vector3 &position) {
    if(!state_ || !state_->store.is_open()) return false;
    try {
        state_->interest.update({position.x,position.y,position.z});
        state_->interest_position=position;
        return true;
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return false;}
}
int64_t V3WorldSession::advance_ticks(int64_t elapsed_ns,int64_t budget) {
    if(!state_ || !state_->store.is_open() || elapsed_ns<0 || budget<0 || budget>64) return -1;
    try {
        auto &s=state_->core->scheduler();
        constexpr auto limit=static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
        ct::require(static_cast<uint64_t>(elapsed_ns)<=limit-s.pending_ns() &&
                    static_cast<uint64_t>(budget)<=limit-s.completed(),"scheduler signed API limit");
        s.accrue(static_cast<uint64_t>(elapsed_ns));
        return static_cast<int64_t>(s.drain(static_cast<size_t>(budget),[&](uint64_t,bool){
            if(state_->fluids) {
                auto *world=Object::cast_to<WorldBootstrap>(ObjectDB::get_instance(ObjectID(state_->bound_world)));
                auto tool=fluid_tool(world);
                const auto pos=state_->interest_position;
                state_->fluid_report=state_->fluids->tick([&](fl::Cell p) {
                    if(Vector3(p.x,p.y,p.z).distance_squared_to(pos)>96.0*96.0)return fl::Passage::unavailable;
                    return probe_cell(tool,p);
                },128);
            }
            return true;
        }));
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return -1;}
}
bool V3WorldSession::finish(bool terrain_saved,bool rocks_saved) {
    try {
        ct::require(state_ && state_->bound_world,"unbound session");
        if(state_->fluids) {
            ct::require(terrain_saved&&rocks_saved,"external stores not saved");
            ct::require(flush_fluids(),"fluid checkpoint save failed");
            ps::plain_unique_file(state_->store.path()/"fluids.json");
        }
        state_->store.finish(state_->core->checkpoint(),terrain_saved,rocks_saved);
        last_error_=String();
        return true;
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return false;}
}
}
