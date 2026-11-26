#include "content_registry/loader.hpp"
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
    std::cout << "V3_LOADER_CONTRACT_PASS\n";
}
