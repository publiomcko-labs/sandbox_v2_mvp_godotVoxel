#include "content_registry/hydraulic_profile.hpp"
#include "content_registry/loader.hpp"
#include "content_registry/seed.hpp"
#include "content_registry/geology.hpp"
#include "content_registry/caves.hpp"
#include <cassert>
#include <chrono>
#include <iostream>

using namespace sandbox::content;
template<class F> void rejected(F f) {
    bool failed = false;
    try { f(); } catch (const std::exception &) { failed = true; }
    assert(failed);
}
void write(const fs::path &p, const std::string &s) {
    std::ofstream f(p, std::ios::binary); f << s; assert(f.good());
}
struct Temp {
    fs::path path = fs::temp_directory_path() / ("sandbox_v3_" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    Temp() { fs::create_directory(path); }
    ~Temp() { std::error_code ec; fs::remove_all(path,ec); }
};
int main(int argc, char **argv) {
    assert(argc == 2);
    const fs::path repo = argv[1];
    assert(sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    rejected([]{strict_json(R"({"a":1,"a":2})");});
    rejected([]{strict_json(R"({"a":{"b":1,"b":2}})");});
    rejected([]{strict_json("[1,]");});
    rejected([]{strict_json(std::string(40,'[')+"0"+std::string(40,']'));});
    Temp tmp;
    const auto base = tmp.path/"first";
    const auto external = tmp.path/"external";
    fs::copy(repo/"godot/mods/first-party",base,fs::copy_options::recursive);
    fs::copy(repo/"examples/v3/mods",external,fs::copy_options::recursive);
    auto reg = initial_registry();
    const auto s = load({base,external},reg);
    assert(s->pins.size() == 3 && s->records.size() == 5);
    assert(s->load_order == (std::vector<std::string>{"base","geology_demo","life_demo"}));
    const auto again = load({external,base},reg,&s->pins);
    assert(again->indices == s->indices);
    // Fixed cross-platform canonical fingerprints from Linux reference run.
    assert(s->pins[0].sha256 == "fdd067a198122e35fcb0df460bde68787dba82feb034caf4ba1b68ff597fb174");
    assert(s->pins[1].sha256 == "cf0462f5faa44ac328e69afcb3b6f089a131ea37523de8124e76e031ec4e9ee7");
    assert(s->pins[2].sha256 == "1aaf4cf81730f1a5b30f0d29f88d1c846c63249e1e5b6ca330754ef4cb59d9db");
    for (const auto &p : s->pins) std::cout << p.mod_id << " " << p.sha256 << "\n";
    const auto rock = external/"geology_demo/content/rock.json";
    auto original = strict_json([&]{std::ifstream f(rock);return std::string(std::istreambuf_iterator<char>(f),{});}());
    write(rock,original.dump());
    assert(load({base,external},reg,&s->pins)->pins == s->pins);
    auto altered = original;
    altered["data"]["radius_m"] = 2;
    write(rock,altered.dump());
    rejected([&]{load({base,external},reg,&s->pins);});
    assert(load({base,external},reg)->pins != s->pins);
    altered = original; altered["data"]["material"] = "life_demo:lava";
    write(rock,altered.dump());
    rejected([&]{load({base,external},reg);});
    altered = original; altered["data"]["material"] = "geology_demo:missing";
    write(rock,altered.dump());
    rejected([&]{load({base,external},reg);});
    altered = original; altered["type"] = "unknown";
    write(rock,altered.dump());
    rejected([&]{load({base,external},reg);});
    write(rock,original.dump());
    write(rock.parent_path()/"duplicate.json",original.dump());
    rejected([&]{load({base,external},reg);});
    fs::remove(rock.parent_path()/"duplicate.json");
    write(rock.parent_path()/"bad.gd","print(1)");
    rejected([&]{load({base,external},reg);});
    fs::remove(rock.parent_path()/"bad.gd");
    write(rock.parent_path()/"large.json",std::string(max_file_bytes+1,'x'));
    rejected([&]{load({base,external},reg);});
    fs::remove(rock.parent_path()/"large.json");
    std::error_code ec;
    fs::create_hard_link(rock,rock.parent_path()/"hard.json",ec);
    if (!ec) {
        rejected([&]{load({base,external},reg);});
        fs::remove(rock.parent_path()/"hard.json");
    }
    ec.clear();
    fs::create_symlink(rock,rock.parent_path()/"link.json",ec);
    if (!ec) {
        rejected([&]{load({base,external},reg);});
        fs::remove(rock.parent_path()/"link.json");
        std::cout << "SYMLINK_REJECTION_PASS\n";
    } else std::cout << "SYMLINK_FIXTURE_UNAVAILABLE " << ec.message() << "\n";
#ifdef _WIN32
    // Junction creation works without requiring Developer Mode on NTFS.
    const auto junction = external/"geology_demo/content/junction";
    const auto cmd = "cmd /c mklink /J \""+junction.string()+"\" \""+base.string()+"\" >nul";
    if (std::system(cmd.c_str()) == 0) {
        rejected([&]{load({base,external},reg);});
        fs::remove(junction);
        std::cout << "JUNCTION_REJECTION_PASS\n";
    } else std::cout << "JUNCTION_FIXTURE_UNAVAILABLE\n";
#endif
    assert(load({base,external},reg,&s->pins)->records.size() == 5);
    // All seven additional handlers are exercised using actual package files,
    // without changing the existing first-party/external compatibility pins.
    const auto content_dir=external/"geology_demo/content";
    auto add_record=[&](const char *name,const char *type,Json data) {
        write(content_dir/(std::string(name)+".json"),
              Json{{"id",std::string("geology_demo:")+name},{"type",type},{"data",data}}.dump());
    };
    add_record("geology","geology_profile",{{"surface_material","base:stone"},{"subsurface_material","geology_demo:granite"},{"bedrock_material","base:stone"},{"soil_depth_m",3},{"bedrock_depth_m",30}});
    add_record("cave","cave_profile",{{"period_m",100},{"radius_m",5},{"max_depth_m",100},{"threshold",0.5}});
    add_record("water","liquid",{{"density",1000},{"viscosity",1}});
    add_record("spring","liquid_source_rule",{{"liquid","geology_demo:water"},{"source_kind","spring"},{"level_m",-5},{"rate_per_tick",1}});
    add_record("tree","procedural_tree",{{"trunk_material","base:stone"},{"foliage_material","base:stone"},{"height_m",8},{"crown_radius_m",3}});
    add_record("forest","static_population_rule",{{"archetype","geology_demo:tree"},{"archetype_type","procedural_tree"},{"density_per_km2",100},{"max_slope_deg",45}});
    add_record("support","terrain_interaction_rule",{{"trigger","terrain_edited"},{"action","recheck_support"},{"target_type","procedural_tree"},{"target","geology_demo:tree"}});
    add_record("grazer","entity_archetype",{{"energy_capacity",100},{"speed_mps",3}});
    add_record("simulation","simulation_profile",{{"entity","geology_demo:grazer"},{"active_update_ticks",1},{"aggregate_update_ticks",10},{"max_active",1000}});
    auto extended=load({base,external},reg);
    assert(extended->records.size()==14);
    assert(load({external,base},reg,&extended->pins)->indices==extended->indices);
    rejected([&]{load({base,external},reg,&s->pins);});
    // Invalid rule vocabulary and mismatched references cannot be published.
    add_record("support","terrain_interaction_rule",{{"trigger","terrain_edited"},{"action","execute_script"},{"target_type","procedural_tree"},{"target","geology_demo:tree"}});
    rejected([&]{load({base,external},reg);});
    add_record("support","terrain_interaction_rule",{{"trigger","terrain_edited"},{"action","wake_liquid"},{"target_type","liquid"},{"target","geology_demo:tree"}});
    rejected([&]{load({base,external},reg);});
    rejected([&]{reg.validate("cave_profile",Json{{"period_m",10},{"radius_m",20},{"max_depth_m",100},{"threshold",0.5}});});
    const auto seed=composed_seed(20261119,"base:stone",-3,2,0,"generator_v1");
    assert(seed==composed_seed(20261119,"base:stone",-3,2,0,"generator_v1"));
    assert(seed!=composed_seed(20261119,"base:stone",-2,2,0,"generator_v1"));
    assert(seed!=composed_seed(20261119,"base:stone",-3,2,0,"generator_v2"));
    assert(seed!=composed_seed(20261119,"geology_demo:granite",-3,2,0,"generator_v1"));
    std::cout << "V3_ALL_11_HANDLERS_PASS seed=" << seed << "\n";
    auto geology=load({repo/"godot/mods/first-party",repo/"godot/mods/geology"},reg);
    auto temperate=compile_geology(*geology,"earth:temperate");
    auto coastal=compile_geology(*geology,"earth:coastal");
    assert(temperate.slot("earth:basalt")==5 && temperate.slot("earth:unknown")==-1);
    assert(temperate.config.at("materials").size()==6 && coastal.config.at("sand_height_m")!=temperate.config.at("sand_height_m"));
    rejected([&]{compile_geology(*geology,"base:stone");});
    std::cout << "V3_GEOLOGY_PALETTE_PASS\n";
    auto caves=load({repo/"godot/mods/first-party",repo/"godot/mods/geology",repo/"godot/mods/caves"},reg);
    auto natural=compile_caves(*caves,"karst:natural",20261119);
    auto wide=compile_caves(*caves,"karst:wide",20261119);
    assert(natural.at("noise_seeds").size()==7 && natural.at("noise_seeds")!=wide.at("noise_seeds"));
    assert(natural==compile_caves(*caves,"karst:natural",20261119));
    assert(natural.at("noise_seeds")!=compile_caves(*caves,"karst:natural",20261120).at("noise_seeds"));
    auto bad=natural; bad.erase("id"); bad.erase("noise_seeds"); bad["pocket_radius_m"]=16;
    rejected([&]{reg.validate("cave_profile",bad);});
    bad=natural; bad.erase("id"); bad.erase("noise_seeds"); bad["entrance_period_m"]=16;
    rejected([&]{reg.validate("cave_profile",bad);});
    bad=natural; bad.erase("id"); bad.erase("noise_seeds"); bad["entrance_cover_m"]=2;
    rejected([&]{reg.validate("cave_profile",bad);});
    bad=natural; bad.erase("id"); bad.erase("noise_seeds"); bad["entrance_elongation"]=1.0;
    rejected([&]{reg.validate("cave_profile",bad);});
    bad=natural; bad.erase("id"); bad.erase("noise_seeds"); bad["entrance_wall_relief_m"]=3;
    rejected([&]{reg.validate("cave_profile",bad);});
    rejected([&]{compile_caves(*caves,"earth:temperate",0);});
    std::cout << "V3_CAVE_PROFILE_PASS seeds=" << natural.at("noise_seeds").dump() << "\n";
    auto hydro=load({repo/"godot/mods/first-party",repo/"godot/mods/hydraulic"},reg);
    auto profile=compile_hydraulic(*hydro);
    assert(profile.types.size()==2&&profile.config.at("sources").size()==3);
    assert(profile.types[0].id=="hydro:lava"&&profile.types[1].id=="hydro:water");
    auto invalid=profile.config.at("sources")[0];invalid.erase("id");invalid.erase("slot");invalid["level_m"]=-100;
    rejected([&]{reg.validate("liquid_source_rule",invalid);});
    std::cout << "V3_HYDRAULIC_MOD_PASS two_types three_explicit_sources\n";
    std::cout << "V3_LOADER_CONTRACT_PASS\n";
}
