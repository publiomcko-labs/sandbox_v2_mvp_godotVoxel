#include "content_registry/manifest.hpp"

#include <algorithm>
#include <cassert>
#include <iostream>
#include <stdexcept>

using namespace sandbox::content;

template<class F> void rejected(F operation) {
    bool failed = false;
    try { operation(); } catch (const std::invalid_argument &) { failed = true; }
    assert(failed);
}

Manifest mod(std::string id, std::vector<Dependency> dependencies = {}) {
    Manifest m;
    m.mod_id = id;
    m.version = "1.0.0";
    m.dependencies = dependencies;
    m.content_roots = {"content"};
    return m;
}

int main() {
    const auto base = mod("base");
    const auto geology = mod("geology", {{"base", "1.0.0"}});
    const auto water = mod("water", {{"base", "1.0.0"}});
    std::vector<Manifest> input{water, base, geology};
    const std::vector<std::string> expected{"base", "geology", "water"};
    assert(resolve_order(input) == expected);
    std::reverse(input.begin(), input.end());
    assert(resolve_order(input) == expected);
    assert(resolve_order({}).empty());
    assert(content_id("base:rock_1"));
    for (const auto *id : {"base", "base:", ":rock", "base:a:b", "Base:rock", "base:../rock"})
        assert(!content_id(id));
    rejected([&] { resolve_order({base, base}); });
    rejected([&] { resolve_order({geology}); });
    rejected([&] { resolve_order({base, mod("water", {{"base", "2.0.0"}})}); });
    rejected([&] { resolve_order({mod("a", {{"b", "1.0.0"}}), mod("b", {{"a", "1.0.0"}})}); });
    rejected([&] { validate(mod("a", {{"a", "1.0.0"}})); });
    rejected([&] { validate(mod("a", {{"base", "1.0.0"}, {"base", "1.0.0"}})); });
    for (const auto *path : {"../outside", "/absolute", "C:/drive", "x/../y", "x\\y", "x//y", "x/", "x.gd"}) {
        auto bad = base;
        bad.content_roots = {path};
        rejected([&] { validate(bad); });
    }
    auto bad = base;
    bad.content_roots = {"content", "content"};
    rejected([&] { validate(bad); });
    bad = base;
    bad.script_policy = "execute";
    rejected([&] { validate(bad); });
    bad = base;
    bad.schema_version = 2;
    rejected([&] { validate(bad); });
    bad = base;
    bad.version = ">=1.0";
    rejected([&] { validate(bad); });
    bad = base;
    bad.content_roots.clear();
    rejected([&] { validate(bad); });
    rejected([&] { resolve_order(std::vector<Manifest>(max_mods + 1, base)); });
    std::cout << "V3_MANIFEST_CONTRACT_PASS\n";
}
