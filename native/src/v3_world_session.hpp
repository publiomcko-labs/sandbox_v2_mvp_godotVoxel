#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <memory>
#include <cstdint>

namespace godot {
class WorldBootstrap;
class V3WorldSession : public RefCounted {
    GDCLASS(V3WorldSession, RefCounted)
    struct State;
    std::unique_ptr<State> state_;
    String last_error_;
    bool open_impl(const String &first_party,const String &external,const String &world_root,
                   const String &world_id,int64_t seed,const String &geology_root,const String &profile,
                   const String &cave_root,const String &cave_profile,const String &hydraulic_root);
    String submit_impl(WorldBootstrap *world,int64_t command,const Vector3 &center,bool add,double radius,int slot);
protected:
    static void _bind_methods();
public:
    V3WorldSession();
    ~V3WorldSession() override;
    bool open(const String &first_party, const String &external, const String &world_root,
              const String &world_id, int64_t seed);
    bool open_geology(const String &first_party,const String &external,const String &world_root,
                      const String &world_id,int64_t seed,const String &geology_root,const String &profile);
    bool open_caves(const String &first_party,const String &external,const String &world_root,
                    const String &world_id,int64_t seed,const String &geology_root,const String &profile,
                    const String &cave_root,const String &cave_profile);
    bool open_hydraulic(const String &first_party,const String &external,const String &world_root,
                    const String &world_id,int64_t seed,const String &geology_root,const String &profile,
                    const String &cave_root,const String &cave_profile,const String &hydraulic_root);
    String get_hydraulic_json() const;
    bool hydraulic_frame(WorldBootstrap *world,const Vector3 &position,int64_t elapsed_ns);
    Dictionary hydraulic_at(const Vector3 &point) const;
    Array hydraulic_surfaces() const;
    Array hydraulic_mesh(int64_t id) const;
    Dictionary hydraulic_report() const;
    bool flush_hydraulic();
    String get_geology_json() const;
    String get_cave_json() const;
    String submit_material(WorldBootstrap *world,int64_t command,const Vector3 &center,bool add,double radius,const String &material_id);
    bool bind_world(WorldBootstrap *world);
    String get_last_error() const;
    String get_world_path() const;
    Array get_content_ids() const;
    String get_record_json(const String &id) const;
    Dictionary get_state() const;
    Dictionary inspect_hydraulic_tile(WorldBootstrap *world,const Vector3i &origin,const Vector3i &extent);
    String submit(WorldBootstrap *world, int64_t command, const Vector3 &center,
                  bool add, double radius);
    Dictionary peek_terrain_event() const;
    bool ack_terrain_event(int64_t revision);
    bool update_interest(const Vector3 &position);
    int64_t advance_ticks(int64_t elapsed_ns, int64_t budget);
    bool finish(bool terrain_saved, bool rocks_saved);
};
}
