#include "world_bootstrap.hpp"

#include <cmath>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/voxel_lod_terrain.hpp>
#include <godot_cpp/classes/voxel_tool.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

void WorldBootstrap::_bind_methods() {
    ClassDB::bind_method(D_METHOD("is_voxel_ready"), &WorldBootstrap::is_voxel_ready);
    ClassDB::bind_method(D_METHOD("can_edit_sphere", "center", "radius"), &WorldBootstrap::can_edit_sphere);
    ClassDB::bind_method(D_METHOD("edit_sphere", "center", "add", "radius"), &WorldBootstrap::edit_sphere);
    ClassDB::bind_method(D_METHOD("get_last_edit_started_usec"), &WorldBootstrap::get_last_edit_started_usec);
    ClassDB::bind_method(D_METHOD("get_last_edit_apply_ms"), &WorldBootstrap::get_last_edit_apply_ms);
    ClassDB::bind_method(D_METHOD("get_successful_edits"), &WorldBootstrap::get_successful_edits);
}

void WorldBootstrap::_ready() {
    set_process(true);
    auto *terrain = Object::cast_to<VoxelLodTerrain>(get_node_or_null(NodePath("Terrain")));
    if (terrain == nullptr) {
        UtilityFunctions::push_error("A0_FAIL: Terrain is not a VoxelLodTerrain");
        return;
    }
    Ref<VoxelTool> tool = terrain->get_voxel_tool();
    if (!tool.is_valid()) {
        UtilityFunctions::push_error("A0_FAIL: VoxelLodTerrain.get_voxel_tool() unavailable");
        return;
    }
    voxel_ready_ = true;
    UtilityFunctions::print("A0_VOXEL_CPP_API_OK");
}

bool WorldBootstrap::can_edit_sphere(const Vector3 &center, double radius) const {
    if (!voxel_ready_ || !std::isfinite(radius) || radius < 0.5 || radius > 8.0 ||
        !std::isfinite(center.x) || !std::isfinite(center.y) || !std::isfinite(center.z)) {
        return false;
    }
    auto *terrain = Object::cast_to<VoxelLodTerrain>(get_node_or_null(NodePath("Terrain")));
    if (terrain == nullptr) {
        return false;
    }
    Ref<VoxelTool> tool = terrain->get_voxel_tool();
    if (!tool.is_valid()) {
        return false;
    }
    const double extent = radius + 2.0; // Includes interpolation/mesh neighbors.
    const Vector3 r(extent, extent, extent);
    return tool->is_area_editable(AABB(center - r, r * 2.0));
}

bool WorldBootstrap::edit_sphere(const Vector3 &center, bool add, double radius) {
    if (!can_edit_sphere(center, radius)) {
        return false; // No edits to unloaded LOD0 regions, no silent partial writes.
    }
    auto *terrain = Object::cast_to<VoxelLodTerrain>(get_node_or_null(NodePath("Terrain")));
    if (terrain == nullptr) {
        return false;
    }
    Ref<VoxelTool> tool = terrain->get_voxel_tool();
    if (!tool.is_valid()) {
        return false;
    }
    const int64_t started = static_cast<int64_t>(Time::get_singleton()->get_ticks_usec());
    tool->set_mode(add ? VoxelTool::MODE_ADD : VoxelTool::MODE_REMOVE);
    tool->do_sphere(center, static_cast<float>(radius));
    const int64_t finished = static_cast<int64_t>(Time::get_singleton()->get_ticks_usec());
    last_edit_started_usec_ = started;
    last_edit_apply_ms_ = static_cast<double>(finished - started) / 1000.0;
    ++successful_edits_;
    return true;
}

void WorldBootstrap::_process(double delta) {
    ++frame_count_;
    seconds_ += delta;
    const double delta_ms = delta * 1000.0;
    if (delta_ms > worst_delta_ms_) worst_delta_ms_ = delta_ms;
    if (seconds_ >= 5.0) {
        // Diagnostic only: delta is not a CPU+GPU/present-time benchmark.
        UtilityFunctions::print("A0_FRAMES samples=", frame_count_,
            " delta_max_ms=", worst_delta_ms_);
        seconds_ = 0.0;
        frame_count_ = 0;
        worst_delta_ms_ = 0.0;
    }
}

} // namespace godot
