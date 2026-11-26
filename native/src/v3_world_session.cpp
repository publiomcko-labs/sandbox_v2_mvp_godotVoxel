#include "v3_world_session.hpp"
#include "world_bootstrap.hpp"
#include <godot_cpp/classes/voxel_lod_terrain.hpp>
#include <godot_cpp/classes/voxel_stream.hpp>
#include <godot_cpp/classes/voxel_stream_sqlite.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include "persistence/checkpoint.hpp"

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
class VoxelAdapter : public sc::TerrainAdapter {
public:
    WorldBootstrap *world=nullptr;
    sc::ApplyResult apply(const sc::Brush &b) noexcept override {
        if (!world) return sc::ApplyResult::rejected;
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
    std::unique_ptr<sc::WorldCore<>> core;
    uint64_t bound_world=0;
};
V3WorldSession::V3WorldSession()=default;
V3WorldSession::~V3WorldSession()=default;
void V3WorldSession::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open","first_party","external","world_root","world_id","seed"), &V3WorldSession::open);
    ClassDB::bind_method(D_METHOD("bind_world","world"), &V3WorldSession::bind_world);
    ClassDB::bind_method(D_METHOD("get_last_error"), &V3WorldSession::get_last_error);
    ClassDB::bind_method(D_METHOD("get_world_path"), &V3WorldSession::get_world_path);
    ClassDB::bind_method(D_METHOD("get_content_ids"), &V3WorldSession::get_content_ids);
    ClassDB::bind_method(D_METHOD("get_record_json","id"), &V3WorldSession::get_record_json);
    ClassDB::bind_method(D_METHOD("get_state"), &V3WorldSession::get_state);
    ClassDB::bind_method(D_METHOD("submit","world","command","center","add","radius"), &V3WorldSession::submit);
    ClassDB::bind_method(D_METHOD("peek_terrain_event"), &V3WorldSession::peek_terrain_event);
    ClassDB::bind_method(D_METHOD("ack_terrain_event","revision"), &V3WorldSession::ack_terrain_event);
    ClassDB::bind_method(D_METHOD("advance_ticks","elapsed_ns","budget"), &V3WorldSession::advance_ticks);
    ClassDB::bind_method(D_METHOD("finish","terrain_saved","rocks_saved"), &V3WorldSession::finish);
}
bool V3WorldSession::open(const String &first_party,const String &external,
                         const String &world_root,const String &world_id,int64_t seed) {
    try {
        ct::require(!state_ && seed>=0,"invalid or already initialized session");
        auto next=std::make_unique<State>();
        next->snapshot=ct::load({path_of(first_party),path_of(external)},ct::initial_registry());
        next->store.begin(path_of(world_root),narrow(world_id),static_cast<uint64_t>(seed),next->snapshot->pins);
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
    d["open"]=state_->store.is_open();
    return d;
}
String V3WorldSession::submit(WorldBootstrap *world,int64_t command,const Vector3 &center,bool add,double radius) {
    if(!state_ || !state_->store.is_open() || !world || !state_->bound_world ||
       state_->bound_world!=world->get_instance_id() || command<=0) return "rejected";
    state_->adapter.world=world;
    const auto r=state_->core->submit({static_cast<uint64_t>(command),{center.x,center.y,center.z},radius,add});
    state_->adapter.world=nullptr;
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
        state_->store.finish(state_->core->checkpoint(),terrain_saved,rocks_saved);
        last_error_=String();
        return true;
    } catch(const std::exception &e) {last_error_=String::utf8(e.what());return false;}
}
}
