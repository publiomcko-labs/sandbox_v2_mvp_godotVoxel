#pragma once

#include <cstdint>
#include <map>
#include <queue>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace sandbox::content {

inline constexpr std::uint32_t manifest_schema = 1;
inline constexpr std::size_t max_mods = 256;
inline constexpr std::size_t max_dependencies = 64;
inline constexpr std::size_t max_roots = 16;

struct Dependency {
    std::string mod_id;
    std::string version;
};

struct Manifest {
    std::string mod_id;
    std::string version;
    std::uint32_t schema_version = manifest_schema;
    std::string script_policy = "data_only";
    std::vector<Dependency> dependencies;
    std::vector<std::string> content_roots;
};

inline bool identifier(std::string_view value) {
    if (value.empty() || value.size() > 64 || value.front() < 'a' || value.front() > 'z')
        return false;
    for (const char c : value) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
            return false;
    }
    return true;
}

inline bool content_id(std::string_view value) {
    const auto split = value.find(':');
    return split != std::string_view::npos &&
           identifier(value.substr(0, split)) && identifier(value.substr(split + 1));
}

// Exact version pins only. No range resolver or implicit upgrades.
inline bool version_pin(std::string_view value) {
    if (value.empty() || value.size() > 64) return false;
    if (value.front() < '0' || value.front() > '9') return false;
    for (const char c : value) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == '.' || c == '-' || c == '+')) return false;
    }
    return true;
}

// Lexical screening only; the filesystem loader must separately enforce
// canonical containment, reject symlinks/reparse points and executable files.
inline bool relative_root(std::string_view value) {
    if (value.empty() || value.size() > 240) return false;
    while (true) {
        const auto slash = value.find('/');
        const auto part = value.substr(0, slash);
        if (!identifier(part)) return false;
        if (slash == std::string_view::npos) return true;
        value.remove_prefix(slash + 1);
    }
}

inline void validate(const Manifest &m) {
    if (!identifier(m.mod_id) || !version_pin(m.version))
        throw std::invalid_argument("invalid mod identity or version");
    if (m.schema_version != manifest_schema || m.script_policy != "data_only")
        throw std::invalid_argument("unsupported manifest schema or script policy");
    if (m.dependencies.size() > max_dependencies || m.content_roots.empty() ||
        m.content_roots.size() > max_roots)
        throw std::invalid_argument("manifest resource limit");
    std::set<std::string> deps, roots;
    for (const auto &dep : m.dependencies) {
        if (!identifier(dep.mod_id) || !version_pin(dep.version) ||
            dep.mod_id == m.mod_id || !deps.insert(dep.mod_id).second)
            throw std::invalid_argument("invalid or duplicate dependency");
    }
    for (const auto &root : m.content_roots) {
        if (!relative_root(root) || !roots.insert(root).second)
            throw std::invalid_argument("invalid or duplicate content root");
    }
}

// Pure deterministic dependency order. Lexical tie-break independent of
// discovery order. Returns IDs only after every manifest/dependency validates.
inline std::vector<std::string> resolve_order(const std::vector<Manifest> &mods) {
    if (mods.size() > max_mods) throw std::invalid_argument("mod count limit");
    std::map<std::string, const Manifest *> by_id;
    std::map<std::string, std::size_t> indegree;
    std::map<std::string, std::vector<std::string>> outgoing;
    for (const auto &mod : mods) {
        validate(mod);
        if (!by_id.emplace(mod.mod_id, &mod).second)
            throw std::invalid_argument("duplicate mod ID");
        indegree.emplace(mod.mod_id, mod.dependencies.size());
    }
    for (const auto &mod : mods) {
        for (const auto &dep : mod.dependencies) {
            const auto found = by_id.find(dep.mod_id);
            if (found == by_id.end() || found->second->version != dep.version)
                throw std::invalid_argument("missing or mismatched dependency pin");
            outgoing[dep.mod_id].push_back(mod.mod_id);
        }
    }
    std::priority_queue<std::string, std::vector<std::string>,
                        std::greater<std::string>> ready;
    for (const auto &[id, count] : indegree)
        if (count == 0) ready.push(id);
    std::vector<std::string> result;
    result.reserve(mods.size());
    while (!ready.empty()) {
        const auto id = ready.top();
        ready.pop();
        result.push_back(id);
        for (const auto &dependent : outgoing[id])
            if (--indegree.at(dependent) == 0) ready.push(dependent);
    }
    if (result.size() != mods.size()) throw std::invalid_argument("dependency cycle");
    return result;
}

} // namespace sandbox::content
