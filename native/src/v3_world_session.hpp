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
protected:
    static void _bind_methods();
public:
    V3WorldSession();
    ~V3WorldSession() override;
    bool open(const String &first_party, const String &external, const String &world_root,
              const String &world_id, int64_t seed);
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
    int64_t advance_ticks(int64_t elapsed_ns, int64_t budget);
    bool finish(bool terrain_saved, bool rocks_saved);
};
}
