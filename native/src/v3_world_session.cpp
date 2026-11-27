#include "v3_world_session.hpp"
#include "world_bootstrap.hpp"
#include <godot_cpp/classes/voxel_lod_terrain.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/voxel_stream.hpp>
#include <godot_cpp/classes/voxel_stream_sq_lite.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include "persistence/checkpoint.hpp"
#include "content_registry/geology.hpp"
#include "content_registry/caves.hpp"
#include "hydraulic_voxel_snapshot.hpp"
#include "hydraulic_runtime.hpp"
#include "persistence/hydraulic_domain_store.hpp"
#include <chrono>
#include <godot_cpp/classes/voxel_buffer.hpp>
#include <godot_cpp/classes/voxel_tool.hpp>
#include <godot_cpp/classes/voxel_format.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {
namespace sc = sandbox::core;
namespace ct = sandbox::content;
namespace ps = sandbox::persistence;
namespace fs = std::filesystem;

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
        const double old=buffer->get_voxel_f(x,y,z,sdf);
        const double next=sandbox::hydraulic::brush_sdf(Vector3(origin+Vector3i(x,y,z)),{center,b.radius_m,b.add},old);
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
    std::unique_ptr<sandbox::hydraulic::Runtime> hydraulic;
    std::unique_ptr<sc::WorldCore<>> core;
    uint64_t bound_world=0;
};
V3WorldSession::V3WorldSession()=default;
V3WorldSession::~V3WorldSession()=default;
void V3WorldSession::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open","first_party","external","world_root","world_id","seed"), &V3WorldSession::open);
    ClassDB::bind_method(D_METHOD("open_geology","first_party","external","world_root","world_id","seed","geology_root","profile"), &V3WorldSession::open_geology);
    ClassDB::bind_method(D_METHOD("open_caves","first_party","external","world_root","world_id","seed","geology_root","profile","cave_root","cave_profile"), &V3WorldSession::open_caves);
    ClassDB::bind_method(D_METHOD("open_hydraulic","first_party","external","world_root","world_id","seed","geology_root","profile","cave_root","cave_profile","hydraulic_root"), &V3WorldSession::open_hydraulic);
    ClassDB::bind_method(D_METHOD("get_hydraulic_json"), &V3WorldSession::get_hydraulic_json);
    ClassDB::bind_method(D_METHOD("hydraulic_frame","world","position","elapsed_ns"), &V3WorldSession::hydraulic_frame);
    ClassDB::bind_method(D_METHOD("hydraulic_at","point"), &V3WorldSession::hydraulic_at);
    ClassDB::bind_method(D_METHOD("hydraulic_column_mass","point"), &V3WorldSession::hydraulic_column_mass);
    ClassDB::bind_method(D_METHOD("hydraulic_surfaces"), &V3WorldSession::hydraulic_surfaces);
    ClassDB::bind_method(D_METHOD("hydraulic_mesh","id"), &V3WorldSession::hydraulic_mesh);
    ClassDB::bind_method(D_METHOD("hydraulic_report"), &V3WorldSession::hydraulic_report);
    ClassDB::bind_method(D_METHOD("hydraulic_hybrid"), &V3WorldSession::hydraulic_hybrid);
    ClassDB::bind_method(D_METHOD("flush_hydraulic"), &V3WorldSession::flush_hydraulic);
    ClassDB::bind_method(D_METHOD("get_cave_json"), &V3WorldSession::get_cave_json);
    ClassDB::bind_method(D_METHOD("get_geology_json"), &V3WorldSession::get_geology_json);
    ClassDB::bind_method(D_METHOD("submit_material","world","command","center","add","radius","material_id"), &V3WorldSession::submit_material);
    ClassDB::bind_method(D_METHOD("bind_world","world"), &V3WorldSession::bind_world);
    ClassDB::bind_method(D_METHOD("get_last_error"), &V3WorldSession::get_last_error);
    ClassDB::bind_method(D_METHOD("get_world_path"), &V3WorldSession::get_world_path);
    ClassDB::bind_method(D_METHOD("get_content_ids"), &V3WorldSession::get_content_ids);
    ClassDB::bind_method(D_METHOD("get_record_json","id"), &V3WorldSession::get_record_json);
    ClassDB::bind_method(D_METHOD("get_state"), &V3WorldSession::get_state);
    ClassDB::bind_method(D_METHOD("inspect_hydraulic_tile","world","origin","extent"), &V3WorldSession::inspect_hydraulic_tile);
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
bool V3WorldSession::open_hydraulic(const String &first_party,const String &external,
                         const String &world_root,const String &world_id,int64_t seed,
                         const String &geology_root,const String &profile,const String &cave_root,
                         const String &cave_profile,const String &hydraulic_root) {
    if(geology_root.is_empty()||profile.is_empty()||cave_root.is_empty()||cave_profile.is_empty()||hydraulic_root.is_empty())return false;
    return open_impl(first_party,external,world_root,world_id,seed,geology_root,profile,cave_root,cave_profile,hydraulic_root);
}
bool V3WorldSession::open_impl(const String &first_party,const String &external,
                         const String &world_root,const String &world_id,int64_t seed,
                         const String &geology_root,const String &profile,
                         const String &cave_root,const String &cave_profile,const String &hydraulic_root) {
    try {
        ct::require(!state_ && seed>=0,"invalid or already initialized session");
        auto next=std::make_unique<State>();
        std::vector<fs::path> roots{path_of(first_party),path_of(external)};
        if(!geology_root.is_empty()) roots.push_back(path_of(geology_root));
        if(!cave_root.is_empty()) roots.push_back(path_of(cave_root));
        if(!hydraulic_root.is_empty())roots.push_back(path_of(hydraulic_root));
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
        const bool coupled=OS::get_singleton()->get_environment("V3_HYBRID_SOLVER")=="1";
        std::optional<ct::HydraulicProfile> hydraulic_profile;
        if(!hydraulic_root.is_empty()) {
            hydraulic_profile=ct::compile_hydraulic(*next->snapshot);
            generator=(coupled?"v3_4_hybrid_runtime_v1:":"v3_4_hydraulic_v2:")+generator;
        }
        next->store.begin(path_of(world_root),narrow(world_id),static_cast<uint64_t>(seed),next->snapshot->pins,generator);
        if(hydraulic_profile) {
            if(next->store.header().generation>0) {
                if(coupled) {
                    const auto file=next->store.path()/"hydraulic_domain.json";ps::plain_unique_file(file);
                    const auto n=fs::file_size(file);ct::require(n<=ps::hydraulic_archive_limit,"hybrid archive bounds");
                    std::ifstream in(file,std::ios::binary);std::string bytes(static_cast<std::size_t>(n),'\0');
                    in.read(bytes.data(),static_cast<std::streamsize>(n));ct::require(bool(in),"hybrid archive read");
                    next->hydraulic=std::make_unique<sandbox::hydraulic::Runtime>(std::move(*hydraulic_profile),ct::strict_json(bytes));
                }else {
                    auto domain=ps::load_domain(next->store.path(),hydraulic_profile->types);
                    next->hydraulic=std::make_unique<sandbox::hydraulic::Runtime>(std::move(*hydraulic_profile),std::move(domain));
                }
            }else next->hydraulic=std::make_unique<sandbox::hydraulic::Runtime>(std::move(*hydraulic_profile),coupled);
        }
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
String V3WorldSession::get_hydraulic_json() const {
    return state_&&state_->hydraulic?String::utf8(state_->hydraulic->profile().config.dump().c_str()):String();
}
bool V3WorldSession::hydraulic_frame(WorldBootstrap *world,const Vector3 &position,int64_t elapsed_ns) {
    try {
        ct::require(state_&&state_->hydraulic&&state_->store.is_open()&&world&&state_->bound_world==world->get_instance_id()&&elapsed_ns>=0,"invalid hydraulic frame");
        auto *terrain=Object::cast_to<VoxelLodTerrain>(world->get_node_or_null(NodePath("Terrain")));
        ct::require(terrain!=nullptr,"missing terrain");
        state_->hydraulic->frame(terrain->get_voxel_tool(),{position.x,position.y,position.z},state_->core->revision(),static_cast<uint64_t>(elapsed_ns));
        return true;
    }catch(const std::exception &e){last_error_=String::utf8(e.what());return false;}
}
int64_t V3WorldSession::hydraulic_column_mass(const Vector3 &point) const {
    return state_&&state_->hydraulic?state_->hydraulic->column_mass({point.x,point.y,point.z}):-1;
}
Dictionary V3WorldSession::hydraulic_at(const Vector3 &point) const {
    return state_&&state_->hydraulic?state_->hydraulic->at({point.x,point.y,point.z}):Dictionary();
}
Array V3WorldSession::hydraulic_surfaces() const {
    return state_&&state_->hydraulic?state_->hydraulic->surfaces():Array();
}
Array V3WorldSession::hydraulic_mesh(int64_t id) const {
    if(!state_||!state_->hydraulic||id<=0||id>std::numeric_limits<sandbox::hydraulic::Id>::max())return {};
    return state_->hydraulic->mesh(static_cast<sandbox::hydraulic::Id>(id));
}
Dictionary V3WorldSession::hydraulic_hybrid() {
    return state_&&state_->hydraulic?state_->hydraulic->hybrid_render():Dictionary();
}
Dictionary V3WorldSession::hydraulic_report() const {
    return state_&&state_->hydraulic?state_->hydraulic->report():Dictionary();
}
bool V3WorldSession::flush_hydraulic() {
    try {
        ct::require(state_&&state_->store.is_open(),"closed hydraulic session");
        if(state_->hydraulic) {
            if(!state_->hydraulic->integrated_mode())ps::save_domain(state_->store.path(),state_->hydraulic->domain());
            else {
                const auto tmp=state_->store.path()/"session_pending"/"hydraulic_domain.tmp";
                const auto bytes=state_->hydraulic->archive().dump();
                ct::require(bytes.size()<=ps::hydraulic_archive_limit&&!fs::exists(fs::symlink_status(tmp)),"hybrid archive bounds");
                std::ofstream out(tmp,std::ios::binary);ct::require(bool(out),"hybrid archive open");
                out.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));out.flush();ct::require(bool(out),"hybrid archive write");
                out.close();ct::require(bool(out),"hybrid archive close");ps::replace_file(tmp,state_->store.path()/"hydraulic_domain.json");
            }
        }
        return true;
    }catch(const std::exception &e){last_error_=String::utf8(e.what());return false;}
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
Dictionary V3WorldSession::inspect_hydraulic_tile(WorldBootstrap *world,const Vector3i &origin,const Vector3i &extent) {
    namespace hy=sandbox::hydraulic;
    Dictionary out;
    out["status"]="rejected";
    try {
        ct::require(state_&&state_->store.is_open()&&world&&state_->bound_world==world->get_instance_id(),"unbound hydraulic snapshot");
        auto *terrain=Object::cast_to<VoxelLodTerrain>(world->get_node_or_null(NodePath("Terrain")));
        ct::require(terrain!=nullptr,"terrain missing");
        const auto start=std::chrono::steady_clock::now();
        auto snapshot=hy::copy_air_snapshot(terrain->get_voxel_tool(),origin,extent,state_->core->revision());
        if(!snapshot){out["status"]="deferred";return out;}
        const auto copied=std::chrono::steady_clock::now();
        const auto geometry=hy::topology::extract(*snapshot);
        const auto end=std::chrono::steady_clock::now();
        hy::Litres capacity=0;
        for(const auto &c:geometry.compartments)capacity+=c.curve.capacity();
        out["status"]="ready";
        out["revision"]=static_cast<int64_t>(geometry.revision);
        out["compartments"]=static_cast<int64_t>(geometry.compartments.size());
        out["portals"]=static_cast<int64_t>(geometry.openings.size());
        out["boundary_intervals"]=static_cast<int64_t>(geometry.boundaries.size());
        out["capacity_litres"]=capacity;
        out["snapshot_usec"]=static_cast<int64_t>(std::chrono::duration_cast<std::chrono::microseconds>(copied-start).count());
        out["extract_usec"]=static_cast<int64_t>(std::chrono::duration_cast<std::chrono::microseconds>(end-copied).count());
    }catch(const std::exception &e){last_error_=String::utf8(e.what());out["error"]=last_error_;}
    return out;
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
    if(state_->hydraulic){
        Ref<VoxelTool> tool;
        if(state_->hydraulic->integrated_mode()){
            auto *terrain=Object::cast_to<VoxelLodTerrain>(world->get_node_or_null(NodePath("Terrain")));
            if(!terrain)return "rejected";
            tool=terrain->get_voxel_tool();
        }
        if(!state_->hydraulic->allows_edit({center.x,center.y,center.z},radius,add,tool,state_->core->revision()+1,slot>=0))return "rejected";
    }
    state_->adapter.world=world;
    const auto r=state_->core->submit({static_cast<uint64_t>(command),{center.x,center.y,center.z},radius,add,slot});
    state_->adapter.world=nullptr;
    if(state_->hydraulic&&r==sc::CommandResult::accepted)state_->hydraulic->edited({center.x,center.y,center.z},radius,state_->core->revision(),add);
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
        // No simulation consumers yet; only scheduler cadence.
        return static_cast<int64_t>(s.drain(static_cast<size_t>(budget),[](uint64_t,bool){return true;}));
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return -1;}
}
bool V3WorldSession::finish(bool terrain_saved,bool rocks_saved) {
    try {
        ct::require(state_ && state_->bound_world,"unbound session");
        if(state_->hydraulic)ct::require(terrain_saved&&rocks_saved&&flush_hydraulic(),"hydraulic checkpoint save failed");
        state_->store.finish(state_->core->checkpoint(),terrain_saved,rocks_saved);
        last_error_=String();
        return true;
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return false;}
}
}
