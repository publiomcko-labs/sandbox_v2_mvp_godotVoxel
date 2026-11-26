#pragma once
#include "manifest.hpp"
#include "sha256.hpp"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>

namespace sandbox::content {
namespace fs = std::filesystem;
using Json = nlohmann::json;
inline constexpr std::size_t max_file_bytes = 256 * 1024;
inline constexpr std::size_t max_package_bytes = 4 * 1024 * 1024;
inline constexpr std::size_t max_total_bytes = 32 * 1024 * 1024;
inline constexpr std::size_t max_entries = 1024;
inline constexpr std::size_t max_records = 8192;

inline void require(bool ok, const char *reason) {
    if (!ok) throw std::invalid_argument(reason);
}
inline void fields(const Json &j, std::initializer_list<const char *> keys) {
    require(j.is_object() && j.size() == keys.size(), "unexpected object fields");
    for (const auto *key : keys) require(j.contains(key), "missing field");
}
inline std::string str(const Json &j) {
    require(j.is_string(), "expected string");
    return j.get<std::string>();
}
inline Json strict_json(const std::string &bytes) {
    std::vector<std::set<std::string>> objects;
    auto callback = [&](int depth, Json::parse_event_t event, Json &parsed) {
        require(depth <= 32, "JSON nesting limit");
        if (event == Json::parse_event_t::object_start) objects.emplace_back();
        if (event == Json::parse_event_t::key)
            require(!objects.empty() && objects.back().insert(parsed.get<std::string>()).second,
                    "duplicate JSON key");
        if (event == Json::parse_event_t::object_end) objects.pop_back();
        return true;
    };
    return Json::parse(bytes, callback, true, false);
}
inline Manifest manifest_from(const Json &j) {
    fields(j, {"mod_id","version","schema_version","script_policy","dependencies","content_roots"});
    Manifest m;
    m.mod_id = str(j.at("mod_id"));
    m.version = str(j.at("version"));
    require(j.at("schema_version").is_number_integer() && j.at("schema_version") == manifest_schema,
            "unknown schema");
    m.script_policy = str(j.at("script_policy"));
    const auto &deps = j.at("dependencies");
    const auto &roots = j.at("content_roots");
    require(deps.is_array() && deps.size() <= max_dependencies &&
            roots.is_array() && roots.size() <= max_roots, "manifest array limits");
    for (const auto &d : deps) {
        fields(d, {"mod_id","version"});
        m.dependencies.push_back({str(d.at("mod_id")), str(d.at("version"))});
    }
    for (const auto &r : roots) m.content_roots.push_back(str(r));
    validate(m);
    for (const auto &a : m.content_roots)
        for (const auto &b : m.content_roots)
            require(a == b || !b.starts_with(a + "/"), "overlapping content roots");
    return m;
}
inline bool safe_component(const fs::path &p) {
    const auto s = p.generic_string();
    if (!identifier(s)) return false;
    return s != "con" && s != "prn" && s != "aux" && s != "nul" &&
        !(s.size() == 4 && (s.starts_with("com") || s.starts_with("lpt")) &&
          s[3] >= '0' && s[3] <= '9');
}
inline void plain_path(const fs::path &p) {
    const auto status = fs::symlink_status(p);
    require(fs::exists(status) && !fs::is_symlink(status), "missing path or symlink");
#ifdef _WIN32
    const auto attrs = GetFileAttributesW(p.c_str());
    require(attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_REPARSE_POINT),
            "reparse point rejected");
#endif
}
inline fs::path checked_root(const fs::path &input) {
    // All ancestors, not just the final component, must be plain.
    const auto p = fs::absolute(input).lexically_normal();
    for (auto current = p; !current.empty();) {
        plain_path(current);
        const auto parent = current.parent_path();
        if (parent == current) break;
        current = parent;
    }
    require(fs::is_directory(p), "not directory");
    return fs::canonical(p);
}
inline bool contained(const fs::path &root, const fs::path &path) {
    const auto rel = fs::canonical(path).lexically_relative(root);
    return !rel.empty() && !rel.is_absolute() && *rel.begin() != "..";
}
inline std::string bounded_read(const fs::path &p, std::size_t &package, std::size_t &total) {
    plain_path(p);
    require(fs::is_regular_file(p) && fs::hard_link_count(p) == 1, "not a plain unique file");
    const auto n = fs::file_size(p);
    require(n <= max_file_bytes && n <= max_package_bytes - package &&
            n <= max_total_bytes - total, "content byte limit");
    std::ifstream stream(p, std::ios::binary);
    require(static_cast<bool>(stream), "file open failed");
    std::string bytes(static_cast<std::size_t>(n), '\0');
    stream.read(bytes.data(), static_cast<std::streamsize>(n));
    require(static_cast<std::uintmax_t>(stream.gcount()) == n && stream.peek() == EOF,
            "file changed or short read");
    package += static_cast<std::size_t>(n);
    total += static_cast<std::size_t>(n);
    return bytes;
}
struct Reference {
    std::string id, type;
};
using Handler = std::function<std::vector<Reference>(const Json &)>;
class Registry {
    std::map<std::string, Handler> handlers_;
public:
    void add(std::string type, Handler handler) {
        require(identifier(type) && static_cast<bool>(handler), "invalid handler");
        require(handlers_.emplace(std::move(type), std::move(handler)).second, "duplicate handler");
    }
    std::vector<Reference> validate(const std::string &type, const Json &data) const {
        const auto it = handlers_.find(type);
        require(it != handlers_.end(), "unsupported content type");
        return it->second(data);
    }
};
inline double positive(const Json &j, double limit) {
    require(j.is_number(), "expected number");
    const double n = j.get<double>();
    require(n > 0 && n <= limit, "number outside bounds");
    return n;
}
inline Registry initial_registry() {
    Registry r;
    r.add("material", [](const Json &j) {
        if(j.size()==2) fields(j, {"density","hardness"});
        else {
            fields(j, {"density","hardness","excavation_resistance","permeability","albedo","roughness"});
            positive(j.at("excavation_resistance"),100000);
            for(const auto *key : {"permeability","roughness"}) {
                const auto &v=j.at(key);
                require(v.is_number() && v.get<double>()>=0 && v.get<double>()<=1,"material ratio");
            }
            const auto &color=j.at("albedo");
            require(color.is_array() && color.size()==3,"material albedo RGB");
            for(const auto &v:color) require(v.is_number() && v.get<double>()>=0 && v.get<double>()<=1,"material color");
        }
        positive(j.at("density"), 100000); positive(j.at("hardness"), 100000);
        return std::vector<Reference>{};
    });
    r.add("procedural_rock", [](const Json &j) {
        fields(j, {"material","radius_m"});
        positive(j.at("radius_m"), 64);
        return std::vector<Reference>{{str(j.at("material")), "material"}};
    });
    r.add("liquid", [](const Json &j) {
        fields(j, {"density","viscosity"});
        positive(j.at("density"), 100000); positive(j.at("viscosity"), 100000);
        return std::vector<Reference>{};
    });
    r.add("entity_archetype", [](const Json &j) {
        fields(j, {"energy_capacity","speed_mps"});
        positive(j.at("energy_capacity"), 100000); positive(j.at("speed_mps"), 100);
        return std::vector<Reference>{};
    });
    r.add("geology_profile", [](const Json &j) {
        if(j.size()!=5) {
            fields(j, {"palette","soil_depth_m","bedrock_depth_m","deep_depth_m","sand_height_m","slope_limit","variation_m","grass_depth_m"});
            const auto &palette=j.at("palette");
            require(palette.is_array() && palette.size()==6,"geology requires six ordered material roles");
            std::set<std::string> ids;
            std::vector<Reference> refs;
            for(const auto &entry:palette) {
                auto id=str(entry);
                require(ids.insert(id).second,"duplicate palette material");
                refs.push_back({id,"material"});
            }
            const auto soil=positive(j.at("soil_depth_m"),128);
            const auto bed=positive(j.at("bedrock_depth_m"),2048);
            require(bed>soil && positive(j.at("deep_depth_m"),4096)>bed,"geology depth order");
            require(j.at("sand_height_m").is_number() && std::abs(j.at("sand_height_m").get<double>())<=128,"sand altitude");
            positive(j.at("slope_limit"),10);
            require(positive(j.at("variation_m"),32)<soil,"layer variation exceeds soil depth");
            require(positive(j.at("grass_depth_m"),8)<soil-j.at("variation_m").get<double>(),"grass depth");
            return refs;
        }
        fields(j, {"surface_material","subsurface_material","bedrock_material","soil_depth_m","bedrock_depth_m"});
        const auto soil=positive(j.at("soil_depth_m"),128);
        require(positive(j.at("bedrock_depth_m"),4096)>soil,"bedrock depth must exceed soil depth");
        return std::vector<Reference>{{str(j.at("surface_material")),"material"},
            {str(j.at("subsurface_material")),"material"},{str(j.at("bedrock_material")),"material"}};
    });
    r.add("cave_profile", [](const Json &j) {
        fields(j, {"period_m","radius_m","max_depth_m","threshold"});
        const auto period=positive(j.at("period_m"),4096);
        require(positive(j.at("radius_m"),128)<period,"cave radius must be smaller than period");
        positive(j.at("max_depth_m"),4096);
        positive(j.at("threshold"),1);
        return std::vector<Reference>{};
    });
    r.add("liquid_source_rule", [](const Json &j) {
        fields(j, {"liquid","source_kind","level_m","rate_per_tick"});
        const auto kind=str(j.at("source_kind"));
        require(kind=="surface_basin" || kind=="spring" || kind=="vent","unknown source kind");
        require(j.at("level_m").is_number() && std::abs(j.at("level_m").get<double>())<=4096,"source level limit");
        positive(j.at("rate_per_tick"),4096);
        return std::vector<Reference>{{str(j.at("liquid")),"liquid"}};
    });
    r.add("procedural_tree", [](const Json &j) {
        fields(j, {"trunk_material","foliage_material","height_m","crown_radius_m"});
        const auto height=positive(j.at("height_m"),64);
        require(positive(j.at("crown_radius_m"),32)<=height,"tree crown exceeds height");
        return std::vector<Reference>{{str(j.at("trunk_material")),"material"},
            {str(j.at("foliage_material")),"material"}};
    });
    r.add("static_population_rule", [](const Json &j) {
        fields(j, {"archetype","archetype_type","density_per_km2","max_slope_deg"});
        const auto type=str(j.at("archetype_type"));
        require(type=="procedural_rock" || type=="procedural_tree","invalid static archetype");
        positive(j.at("density_per_km2"),1000000);
        require(j.at("max_slope_deg").is_number() && j.at("max_slope_deg").get<double>()>=0 &&
                j.at("max_slope_deg").get<double>()<=90,"slope out of range");
        return std::vector<Reference>{{str(j.at("archetype")),type}};
    });
    r.add("terrain_interaction_rule", [](const Json &j) {
        fields(j, {"trigger","action","target_type","target"});
        require(str(j.at("trigger"))=="terrain_edited","unknown interaction trigger");
        const auto action=str(j.at("action")), type=str(j.at("target_type"));
        require((action=="wake_liquid" && type=="liquid") ||
                (action=="recheck_support" && (type=="procedural_rock" || type=="procedural_tree")),
                "unsupported declarative interaction");
        return std::vector<Reference>{{str(j.at("target")),type}};
    });
    r.add("simulation_profile", [](const Json &j) {
        fields(j, {"entity","active_update_ticks","aggregate_update_ticks","max_active"});
        const auto bounded_int=[](const Json &v, std::uint64_t limit) {
            require(v.is_number_unsigned() && v.get<std::uint64_t>()>0 &&
                    v.get<std::uint64_t>()<=limit,"invalid simulation integer");
            return v.get<std::uint64_t>();
        };
        const auto active=bounded_int(j.at("active_update_ticks"),100);
        require(bounded_int(j.at("aggregate_update_ticks"),10000)>=active,"aggregate cadence faster than active");
        bounded_int(j.at("max_active"),10000);
        return std::vector<Reference>{{str(j.at("entity")),"entity_archetype"}};
    });
    return r;
}
struct Record {
    std::string id, type;
    Json data;
    std::vector<Reference> refs;
};
struct Pin {
    std::string mod_id, version, sha256;
    bool operator==(const Pin &) const = default;
};
struct Snapshot {
    std::vector<Pin> pins;
    std::vector<Record> records; // Lexical ID order; runtime indices only.
    std::map<std::string, std::size_t> indices;
    std::vector<std::string> load_order;
};
struct Package {
    Manifest manifest;
    Pin pin;
    std::vector<Record> records;
};
inline Package read_package(const fs::path &path, const Registry &registry, std::size_t &total) {
    const auto root = checked_root(path);
    std::size_t bytes = 0, entries = 0;
    const auto manifest_json = strict_json(bounded_read(root / "manifest.json", bytes, total));
    const auto manifest = manifest_from(manifest_json);
    std::map<std::string, Json> documents;
    Package p;
    p.manifest = manifest;
    for (const auto &r : manifest.content_roots) {
        const fs::path declared = root / r;
        require(contained(root, checked_root(declared)), "root escapes package");
    }
    for (const auto &entry : fs::recursive_directory_iterator(root)) {
        require(++entries <= max_entries, "package entry limit");
        const auto f = entry.path();
        plain_path(f);
        require(contained(root, f), "path escapes package");
        const auto rel = f.lexically_relative(root).generic_string();
        require(rel.size() <= 240 && std::count(rel.begin(), rel.end(), '/') <= 16,
                "package path limit");
        if (fs::is_directory(f)) {
            require(safe_component(f.filename()), "invalid directory name");
            bool allowed = false;
            for (const auto &r : manifest.content_roots)
                allowed |= rel == r || rel.starts_with(r + "/") || r.starts_with(rel + "/");
            require(allowed, "unexpected directory");
            continue;
        }
        if (rel == "manifest.json") continue;
        require(fs::is_regular_file(f) && f.extension() == ".json" &&
                safe_component(f.stem()), "only plain JSON content allowed");
        bool allowed = false;
        for (const auto &r : manifest.content_roots) allowed |= rel.starts_with(r + "/");
        require(allowed, "file outside declared content roots");
        auto j = strict_json(bounded_read(f, bytes, total));
        fields(j, {"id","type","data"});
        const auto id = str(j.at("id"));
        const auto type = str(j.at("type"));
        require(content_id(id) && id.starts_with(manifest.mod_id + ":"), "foreign or invalid ID");
        auto refs = registry.validate(type, j.at("data"));
        p.records.push_back({id,type,j.at("data"),std::move(refs)});
        documents.emplace(rel, std::move(j));
    }
    require(!p.records.empty(), "empty package");
    // Canonical JSON v1: ordered object keys, sorted dependency/root sets,
    // lexical relative file names; content arrays retain their semantics.
    auto canonical_manifest = manifest_json;
    auto &deps = canonical_manifest["dependencies"];
    std::sort(deps.begin(), deps.end(), [](const Json &a, const Json &b) {
        return a.at("mod_id") < b.at("mod_id");
    });
    auto &roots = canonical_manifest["content_roots"];
    std::sort(roots.begin(), roots.end());
    const Json canonical = {{"format","sandbox_mod_canonical_v1"},
                            {"manifest",canonical_manifest},{"files",documents}};
    p.pin = {manifest.mod_id,manifest.version,sha256(canonical.dump(-1,' ',true))};
    return p;
}
inline std::shared_ptr<const Snapshot> load(const std::vector<fs::path> &install_roots,
                                            const Registry &registry,
                                            const std::vector<Pin> *expected_pins = nullptr) {
    std::size_t bytes = 0;
    std::vector<Package> packages;
    std::vector<Manifest> manifests;
    for (const auto &path : install_roots) {
        const auto root = checked_root(path);
        for (const auto &entry : fs::directory_iterator(root)) {
            require(packages.size() < max_mods, "mod count limit");
            plain_path(entry.path());
            require(entry.is_directory() && safe_component(entry.path().filename()), "invalid package entry");
            auto package = read_package(entry.path(), registry, bytes);
            require(entry.path().filename().generic_string() == package.manifest.mod_id, "package directory mismatch");
            manifests.push_back(package.manifest);
            packages.push_back(std::move(package));
        }
    }
    Snapshot s;
    s.load_order = resolve_order(manifests);
    std::map<std::string,std::set<std::string>> allowed;
    for (auto &p : packages) {
        auto &names = allowed[p.manifest.mod_id];
        names.insert(p.manifest.mod_id);
        for (const auto &d : p.manifest.dependencies) names.insert(d.mod_id);
        s.pins.push_back(p.pin);
        require(p.records.size() <= max_records - s.records.size(), "registry record limit");
        for (auto &r : p.records) s.records.push_back(std::move(r));
    }
    std::sort(s.pins.begin(), s.pins.end(), [](const Pin &a, const Pin &b){return a.mod_id < b.mod_id;});
    require(!expected_pins || s.pins == *expected_pins, "saved content pins mismatch");
    std::sort(s.records.begin(), s.records.end(), [](const Record &a, const Record &b){return a.id < b.id;});
    for (std::size_t i = 0; i < s.records.size(); ++i)
        require(s.indices.emplace(s.records[i].id, i).second, "duplicate content ID");
    for (const auto &r : s.records) {
        const auto owner = r.id.substr(0,r.id.find(':'));
        for (const auto &ref : r.refs) {
            require(content_id(ref.id) && allowed.at(owner).contains(ref.id.substr(0,ref.id.find(':'))),
                    "undeclared reference dependency");
            const auto found = s.indices.find(ref.id);
            require(found != s.indices.end() && s.records[found->second].type == ref.type,
                    "missing or wrong reference type");
        }
    }
    return std::make_shared<const Snapshot>(std::move(s));
}
}
