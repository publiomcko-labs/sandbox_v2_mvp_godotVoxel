#pragma once

#include <cstdint>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class WorldBootstrap final : public Node3D {
    GDCLASS(WorldBootstrap, Node3D)

    bool voxel_ready_ = false;
    double seconds_ = 0.0;
    double worst_delta_ms_ = 0.0;
    uint64_t frame_count_ = 0;

    // Timestamps are monotonic. Acceptance and synchronous CPU apply timing
    // must never be mistaken for first rendered/presented frame.
    int64_t last_edit_started_usec_ = 0;
    double last_edit_apply_ms_ = 0.0;
    int64_t successful_edits_ = 0;

protected:
    static void _bind_methods();

public:
    void _ready() override;
    void _process(double delta) override;

    bool is_voxel_ready() const { return voxel_ready_; }
    bool can_edit_sphere(const Vector3 &center, double radius) const;
    bool edit_sphere(const Vector3 &center, bool add, double radius);
    int64_t get_last_edit_started_usec() const { return last_edit_started_usec_; }
    double get_last_edit_apply_ms() const { return last_edit_apply_ms_; }
    int64_t get_successful_edits() const { return successful_edits_; }
};

} // namespace godot
