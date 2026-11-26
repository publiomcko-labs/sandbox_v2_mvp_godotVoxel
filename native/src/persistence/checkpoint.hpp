#pragma once
#include "content_registry/loader.hpp"
#include "core/world_core.hpp"
#include <limits>

namespace sandbox::persistence {
namespace fs = std::filesystem;
using content::Json;
using content::Pin;
using content::require;
using core::CheckpointState;
inline constexpr std::string_view generator_version = "a5_cpu16_0c3fee95";
inline constexpr int schema_version = 1;

struct WorldHeader {
    std::string world_id;
    std::uint64_t seed{}, generation{};
    std::vector<Pin> pins;
    CheckpointState core;
};

inline Json encode(const WorldHeader &h) {
    Json pins = Json::array();
    for (const auto &p : h.pins)
        pins.push_back({{"mod_id",p.mod_id},{"version",p.version},{"sha256",p.sha256}});
    return {{"schema_version",schema_version},{"generator_version",generator_version},
            {"world_id",h.world_id},{"seed",h.seed},{"generation",h.generation},
            {"pins",pins},{"core",{{"terrain_revision",h.core.terrain_revision},
            {"last_command",h.core.last_command},{"completed_tick",h.core.completed_tick},
            {"pending_ns",h.core.pending_ns}}}};
}
inline std::uint64_t uint(const Json &j) {
    require(j.is_number_unsigned(), "expected unsigned checkpoint integer");
    return j.get<std::uint64_t>();
}
inline WorldHeader decode(const Json &j) {
    content::fields(j,{"schema_version","generator_version","world_id","seed","generation","pins","core"});
    require(j.at("schema_version").is_number_integer() && j.at("schema_version")==schema_version,
            "unknown world schema");
    require(j.at("generator_version")==generator_version, "generator version mismatch");
    WorldHeader h;
    h.world_id=content::str(j.at("world_id"));
    require(content::identifier(h.world_id), "invalid world ID");
    h.seed=uint(j.at("seed"));
    h.generation=uint(j.at("generation"));
    require(h.generation>0, "invalid checkpoint generation");
    const auto &pins=j.at("pins");
    require(pins.is_array() && pins.size()<=content::max_mods,"checkpoint pin limit");
    for (const auto &p : pins) {
        content::fields(p,{"mod_id","version","sha256"});
        Pin pin{content::str(p.at("mod_id")),content::str(p.at("version")),content::str(p.at("sha256"))};
        require(content::identifier(pin.mod_id) && content::version_pin(pin.version) &&
                pin.sha256.size()==64 && pin.sha256.find_first_not_of("0123456789abcdef")==std::string::npos,
                "invalid checkpoint pin");
        require(h.pins.empty() || h.pins.back().mod_id < pin.mod_id, "unsorted or duplicate pin");
        h.pins.push_back(std::move(pin));
    }
    const auto &c=j.at("core");
    content::fields(c,{"terrain_revision","last_command","completed_tick","pending_ns"});
    h.core={uint(c.at("terrain_revision")),uint(c.at("last_command")),
            uint(c.at("completed_tick")),uint(c.at("pending_ns"))};
    require(h.core.terrain_revision<=h.core.last_command,"invalid checkpoint counters");
    return h;
}
inline Json read_json(const fs::path &path) {
    std::size_t package=0,total=0;
    return content::strict_json(content::bounded_read(path,package,total));
}
inline void write_new(const fs::path &path, const Json &data) {
    require(!fs::exists(fs::symlink_status(path)), "refusing existing output");
    const auto bytes=data.dump(-1,' ',true)+"\n";
    require(bytes.size()<=content::max_file_bytes,"checkpoint byte limit");
    std::ofstream out(path,std::ios::binary);
    require(static_cast<bool>(out),"checkpoint file open failed");
    out.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));
    out.flush();
    require(static_cast<bool>(out),"checkpoint write failed");
    out.close();
    require(static_cast<bool>(out),"checkpoint close failed");
}
inline void replace_file(const fs::path &tmp,const fs::path &dst) {
#ifdef _WIN32
    require(MoveFileExW(tmp.c_str(),dst.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0,
            "checkpoint replacement failed");
#else
    fs::rename(tmp,dst);
#endif
}
inline void plain_unique_file(const fs::path &p) {
    content::plain_path(p);
    require(fs::is_regular_file(p) && fs::hard_link_count(p)==1,"invalid world file");
}

// Single-session, fail-closed protocol. No atomic transaction with Voxel SQLite
// or rock sidecar is implied. An interrupted/dirty session blocks reopening
// until a future explicit recovery tool can establish consistency.
class CheckpointStore {
    fs::path world_;
    WorldHeader header_;
    bool open_=false;
public:
    CheckpointStore()=default;
    CheckpointStore(const CheckpointStore &)=delete;
    CheckpointStore &operator=(const CheckpointStore &)=delete;
    void begin(const fs::path &root,const std::string &world_id,std::uint64_t seed,
               const std::vector<Pin> &pins) {
        require(!open_,"session already open");
        require(content::safe_component(fs::path(world_id)),"invalid world ID");
        const auto base=content::checked_root(root);
        world_=base/world_id;
        const bool fresh=fs::create_directory(world_);
        world_=content::checked_root(world_);
        require(content::contained(base,world_),"world path escaped");
        const auto marker=world_/"session_pending";
        require(!fs::exists(fs::symlink_status(marker)),"world has unresolved session intent");
        if (fresh) {
            header_={world_id,seed,0,pins,{}};
        } else {
            for (const auto &entry:fs::directory_iterator(world_))
                plain_unique_file(entry.path());
            header_=decode(read_json(world_/"checkpoint.json"));
            require(header_.world_id==world_id && header_.seed==seed && header_.pins==pins,
                    "world identity, seed or content pins mismatch");
            plain_unique_file(world_/"terrain.sqlite");
            plain_unique_file(world_/"rocks.json");
        }
        require(header_.generation<std::numeric_limits<std::uint64_t>::max(),"checkpoint generation overflow");
        // Atomic directory creation is the session exclusion gate.
        require(fs::create_directory(marker),"concurrent or unresolved world session");
        write_new(marker/"intent.json",{{"world_id",world_id},{"base_generation",header_.generation},
                  {"next_generation",header_.generation+1},{"state","OPEN_PENDING_EXTERNAL_STORES"}});
        open_=true;
    }
    const WorldHeader &header() const {return header_;}
    const fs::path &path() const {return world_;}
    bool is_open() const {return open_;}
    // Called only after external store completion/flush and no further writes
    // are possible. The marker remains on every failure.
    void finish(CheckpointState state,bool terrain_saved,bool rocks_saved) {
        require(open_ && terrain_saved && rocks_saved,"external save not confirmed");
        require(state.terrain_revision>=header_.core.terrain_revision &&
                state.last_command>=header_.core.last_command &&
                state.completed_tick>=header_.core.completed_tick &&
                state.terrain_revision<=state.last_command,"checkpoint counter regression");
        plain_unique_file(world_/"terrain.sqlite");
        plain_unique_file(world_/"rocks.json");
        auto next=header_;
        ++next.generation;
        next.core=state;
        const auto marker=world_/"session_pending";
        const auto tmp=marker/"checkpoint.tmp";
        write_new(tmp,encode(next));
        replace_file(tmp,world_/"checkpoint.json");
        // If interrupted here, marker still prevents a false clean reopen.
        require(fs::remove(marker/"intent.json"),"intent cleanup failed");
        require(fs::remove(marker),"session cleanup failed");
        header_=std::move(next);
        open_=false;
    }
};
}
