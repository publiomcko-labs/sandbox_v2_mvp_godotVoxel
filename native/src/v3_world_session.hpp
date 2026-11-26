#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>
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
                   const String &cave_root,const String &cave_profile,const String &fluid_root);
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
    bool open_fluids(const String &first_party,const String &external,const String &world_root,
                    const String &world_id,int64_t seed,const String &geology_root,const String &profile,
                    const String &cave_root,const String &cave_profile,const String &fluid_root);
    String get_fluid_json() const;
    Array get_seeded_reservoirs() const;
    String seed_reservoir(WorldBootstrap *world,const String &id,const Array &cells);
    Dictionary fluid_at(const Vector3 &point) const;
    Array fluid_cells(const Vector3 &lo,const Vector3 &hi) const;
    Array take_fluid_dirty(int64_t budget);
    bool flush_fluids();
    String get_geology_json() const;
    String get_cave_json() const;
    String submit_material(WorldBootstrap *world,int64_t command,const Vector3 &center,bool add,double radius,const String &material_id);
    bool bind_world(WorldBootstrap *world);
    String get_last_error() const;
    String get_world_path() const;
    Array get_content_ids() const;
    String get_record_json(const String &id) const;
    Dictionary get_state() const;
    String submit(WorldBootstrap *world, int64_t command, const Vector3 &center,
                  bool add, double radius);
    Dictionary peek_terrain_event() const;
    bool ack_terrain_event(int64_t revision);
    bool update_interest(const Vector3 &position);
    int64_t advance_ticks(int64_t elapsed_ns, int64_t budget);
    bool finish(bool terrain_saved, bool rocks_saved);
};
}
