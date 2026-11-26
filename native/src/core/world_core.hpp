#pragma once
#include <array>
#include <cmath>
#include <compare>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>
#include <vector>

namespace sandbox::core {

struct Vec3 { double x{}, y{}, z{}; };
struct Bounds { Vec3 min, max; };
struct Region {
    std::int32_t x{}, y{}, z{};
    auto operator<=>(const Region &) const = default;
};
enum class Tier : std::uint8_t { active, aggregate, dormant };
inline constexpr double region_size_m = 64.0;
inline constexpr double coordinate_limit_m = 1'000'000'000.0;
inline bool valid_point(Vec3 p) {
    return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z) &&
        std::abs(p.x) <= coordinate_limit_m && std::abs(p.y) <= coordinate_limit_m &&
        std::abs(p.z) <= coordinate_limit_m;
}
inline bool valid_bounds(Bounds b) {
    return valid_point(b.min) && valid_point(b.max) &&
        b.min.x <= b.max.x && b.min.y <= b.max.y && b.min.z <= b.max.z;
}
inline Region region_at(Vec3 p) {
    if (!valid_point(p)) throw std::invalid_argument("invalid point");
    return {static_cast<std::int32_t>(std::floor(p.x / region_size_m)),
            static_cast<std::int32_t>(std::floor(p.y / region_size_m)),
            static_cast<std::int32_t>(std::floor(p.z / region_size_m))};
}
// A logical region index, never a terrain residency map. Unknown regions
// are absent, not implicitly loaded. Dormant regions are never tick-scanned.
class Regions {
    std::map<Region,Tier> resident_;
    std::set<Region> active_, aggregate_;
    std::size_t capacity_;
    void unindex(Region r, Tier t) {
        if (t == Tier::active) active_.erase(r);
        if (t == Tier::aggregate) aggregate_.erase(r);
    }
public:
    explicit Regions(std::size_t capacity = 65536) : capacity_(capacity) {}
    bool set(Region r, Tier t) {
        if (t != Tier::active && t != Tier::aggregate && t != Tier::dormant)
            throw std::invalid_argument("unknown tier");
        const auto old = resident_.find(r);
        if (old != resident_.end() && old->second == t) return true;
        if (old == resident_.end() && resident_.size() >= capacity_) return false;
        auto *target = t == Tier::active ? &active_ : t == Tier::aggregate ? &aggregate_ : nullptr;
        if (target) target->insert(r);
        if (old == resident_.end()) {
            try { resident_.emplace(r,t); }
            catch (...) { if (target) target->erase(r); throw; }
        } else {
            unindex(r,old->second);
            old->second = t;
        }
        return true;
    }
    void erase(Region r) {
        const auto it = resident_.find(r);
        if (it == resident_.end()) return;
        unindex(r,it->second); resident_.erase(it);
    }
    std::optional<Tier> get(Region r) const {
        const auto it = resident_.find(r);
        if (it == resident_.end()) return std::nullopt;
        return it->second;
    }
    std::size_t size() const { return resident_.size(); }
    std::size_t active_count() const { return active_.size(); }
    std::size_t aggregate_count() const { return aggregate_.size(); }
    std::size_t dormant_count() const { return size()-active_count()-aggregate_count(); }
    const std::set<Region> &active() const { return active_; }
    const std::set<Region> &aggregate() const { return aggregate_; }
    // Inclusive bounds, bounded at 4096 candidate cells regardless of world history.
    std::vector<Region> query(Bounds bounds) const {
        if (!valid_bounds(bounds)) throw std::invalid_argument("invalid bounds");
        const auto a = region_at(bounds.min), b = region_at(bounds.max);
        constexpr std::int64_t max_cells = 4096;
        const std::int64_t nx = std::int64_t(b.x)-a.x+1, ny = std::int64_t(b.y)-a.y+1,
            nz = std::int64_t(b.z)-a.z+1;
        if (nx > max_cells || ny > max_cells || nz > max_cells ||
            nx*ny > max_cells || nx*ny*nz > max_cells)
            throw std::invalid_argument("spatial query budget");
        std::vector<Region> result;
        for (std::int32_t x=a.x;x<=b.x;++x)
            for (std::int32_t y=a.y;y<=b.y;++y)
                for (std::int32_t z=a.z;z<=b.z;++z)
                    if (resident_.contains({x,y,z})) result.push_back({x,y,z});
        return result;
    }
};

inline constexpr std::uint64_t tick_period_ns = 100'000'000; // 10 Hz
inline constexpr std::uint64_t aggregate_every_ticks = 10; // 1 Hz initial
class FixedScheduler {
    std::uint64_t completed_{}, elapsed_ns_{};
public:
    explicit FixedScheduler(std::uint64_t completed = 0, std::uint64_t pending_ns = 0)
        : completed_(completed), elapsed_ns_(pending_ns) {}
    void accrue(std::uint64_t elapsed_ns) {
        if (elapsed_ns > std::numeric_limits<std::uint64_t>::max() - elapsed_ns_)
            throw std::overflow_error("tick debt overflow; caller must stop");
        elapsed_ns_ += elapsed_ns;
    }
    std::uint64_t completed() const { return completed_; }
    std::uint64_t pending_ns() const { return elapsed_ns_; }
    std::uint64_t backlog() const { return elapsed_ns_ / tick_period_ns; }
    // Callback commits the entire tick or returns false without state mutation.
    // No elapsed time dropped when budget exhausted or callback defers.
    template<class Tick> std::size_t drain(std::size_t budget, Tick run) {
        std::size_t done = 0;
        while (done < budget && backlog() > 0) {
            if (completed_ == std::numeric_limits<std::uint64_t>::max())
                throw std::overflow_error("tick ID overflow");
            const auto next = completed_ + 1;
            if (!run(next, next % aggregate_every_ticks == 0)) break;
            ++completed_; ++done; elapsed_ns_ -= tick_period_ns;
        }
        return done;
    }
};

// One ordered command stream for initial single-player runtime.
// Command IDs and revisions are distinct: no-effect consumes a command ID
// but never advances the terrain revision. No history scan or unbounded log.
struct Brush {
    std::uint64_t sequence{};
    Vec3 center;
    double radius_m{};
    bool add{};
};
enum class ApplyResult : std::uint8_t { applied, no_effect, deferred, rejected };
enum class CommandResult : std::uint8_t {
    accepted, no_effect, deferred, rejected, duplicate, out_of_order, backpressure
};
class TerrainAdapter {
public:
    virtual ~TerrainAdapter() = default;
    // Must not throw. "applied" means adapter accepted/applied synchronously,
    // not that visible geometry changed, nor collider/durability/pixel ready.
    // On no_effect/deferred/rejected no terrain mutation may have occurred.
    virtual ApplyResult apply(const Brush &) noexcept = 0;
};
struct TerrainEdited {
    Bounds bounds;
    std::uint64_t revision{}, command{};
};
struct FluidChanged { Region region; std::uint64_t revision{}; };
struct EntityChanged { std::uint64_t entity_id{}, revision{}; Region region; };
struct CheckpointState {
    std::uint64_t terrain_revision{}, last_command{}, completed_tick{}, pending_ns{};
};

template<std::size_t EventCapacity = 1024>
class WorldCore {
    static_assert(EventCapacity > 0);
    TerrainAdapter &terrain_;
    std::uint64_t revision_{}, last_command_{};
    std::array<TerrainEdited,EventCapacity> events_{};
    std::size_t head_{}, count_{};
    FixedScheduler scheduler_;
public:
    explicit WorldCore(TerrainAdapter &terrain, CheckpointState state = {})
        : terrain_(terrain), revision_(state.terrain_revision), last_command_(state.last_command),
          scheduler_(state.completed_tick,state.pending_ns) {
        if (revision_ > last_command_) throw std::invalid_argument("invalid checkpoint counters");
    }
    CommandResult submit(const Brush &brush) {
        if (brush.sequence == 0) return CommandResult::rejected;
        if (brush.sequence <= last_command_) return CommandResult::duplicate;
        if (brush.sequence != last_command_ + 1) return CommandResult::out_of_order;
        if (!valid_point(brush.center) || !std::isfinite(brush.radius_m) ||
            brush.radius_m < .5 || brush.radius_m > 8.0) return CommandResult::rejected;
        const double extent = brush.radius_m + 2.0;
        const Bounds bounds{{brush.center.x-extent,brush.center.y-extent,brush.center.z-extent},
                            {brush.center.x+extent,brush.center.y+extent,brush.center.z+extent}};
        if (!valid_bounds(bounds)) return CommandResult::rejected;
        if (count_ == EventCapacity || revision_ == std::numeric_limits<std::uint64_t>::max())
            return CommandResult::backpressure;
        const auto status = terrain_.apply(brush);
        if (status == ApplyResult::deferred) return CommandResult::deferred;
        if (status == ApplyResult::no_effect) { last_command_ = brush.sequence; return CommandResult::no_effect; }
        if (status != ApplyResult::applied) return CommandResult::rejected;
        last_command_ = brush.sequence;
        ++revision_;
        events_[(head_+count_)%EventCapacity] = {bounds,revision_,last_command_};
        ++count_;
        return CommandResult::accepted;
    }
    std::size_t queued_events() const { return count_; }
    std::optional<TerrainEdited> peek() const {
        if (!count_) return std::nullopt;
        return events_[head_];
    }
    bool acknowledge(std::uint64_t revision) {
        if (!count_ || events_[head_].revision != revision) return false;
        head_ = (head_+1)%EventCapacity; --count_; return true;
    }
    std::uint64_t revision() const { return revision_; }
    std::uint64_t last_command() const { return last_command_; }
    FixedScheduler &scheduler() { return scheduler_; }
    const FixedScheduler &scheduler() const { return scheduler_; }
    CheckpointState checkpoint() const {
        if (count_) throw std::logic_error("pending events must be acknowledged before checkpoint");
        return {revision_,last_command_,scheduler_.completed(),scheduler_.pending_ns()};
    }
};
}
