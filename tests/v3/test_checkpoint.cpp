#include "persistence/checkpoint.hpp"
#include <cassert>
#include <chrono>
#include <iostream>
using namespace sandbox::persistence;
template<class F> void rejected(F f) {
    bool failed=false;
    try { f(); } catch(const std::exception &) {failed=true;}
    assert(failed);
}
struct Temp {
    fs::path path=fs::temp_directory_path()/("v3_checkpoint_"+std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()));
    Temp(){fs::create_directory(path);}
    ~Temp(){std::error_code ec; fs::remove_all(path,ec);}
};
void external_fixture(const fs::path &p) {
    std::ofstream(p/"terrain.sqlite")<<"fixture, not actual SQLite";
    std::ofstream(p/"rocks.json")<<"{}";
}
int main() {
    Temp t;
    const std::vector<Pin> pins{{"base","1.0.0",std::string(64,'a')}};
    CheckpointStore first;
    first.begin(t.path,"world",42,pins);
    assert(first.is_open() && first.header().generation==0);
    CheckpointStore concurrent;
    rejected([&]{concurrent.begin(t.path,"world",42,pins);});
    rejected([&]{first.finish({1,1,10,123},true,false);});
    assert(fs::exists(first.path()/"session_pending/intent.json"));
    external_fixture(first.path());
    first.finish({1,1,10,123},true,true);
    assert(!first.is_open() && first.header().generation==1);
    assert(!fs::exists(first.path()/"session_pending"));
    CheckpointStore wrong;
    rejected([&]{wrong.begin(t.path,"world",43,pins);});
    auto changed=pins;
    changed[0].sha256=std::string(64,'b');
    rejected([&]{wrong.begin(t.path,"world",42,changed);});
    CheckpointStore reopen;
    reopen.begin(t.path,"world",42,pins);
    assert(reopen.header().core.terrain_revision==1 && reopen.header().core.completed_tick==10);
    assert(reopen.header().core.pending_ns==123);
    rejected([&]{reopen.finish({0,1,10,123},true,true);});
    reopen.finish({2,2,11,0},true,true);
    assert(reopen.header().generation==2);
    CheckpointStore crashed;
    crashed.begin(t.path,"world",42,pins);
    CheckpointStore retry;
    rejected([&]{retry.begin(t.path,"world",42,pins);});
    // Simulate interruption after checkpoint replacement but before marker cleanup.
    auto next=crashed.header();
    ++next.generation;
    write_new(crashed.path()/"session_pending"/"checkpoint.tmp",encode(next));
    replace_file(crashed.path()/"session_pending"/"checkpoint.tmp",crashed.path()/"checkpoint.json");
    rejected([&]{retry.begin(t.path,"world",42,pins);});
    auto invalid=encode(next); invalid["schema_version"]=2;
    rejected([&]{decode(invalid);});
    invalid=encode(next); invalid["core"]["last_command"]=-1;
    rejected([&]{decode(invalid);});
    rejected([&]{retry.begin(t.path,"../escape",42,pins);});
    CheckpointStore geology;
    geology.begin(t.path,"geology",42,pins,"v3_2_single_s4_v1:earth:temperate");
    external_fixture(geology.path());
    geology.finish({},true,true);
    CheckpointStore mismatch;
    rejected([&]{mismatch.begin(t.path,"geology",42,pins);});
    rejected([&]{mismatch.begin(t.path,"geology",42,pins,"v3_2_single_s4_v1:earth:coastal");});
    CheckpointStore geo_reopen;
    geo_reopen.begin(t.path,"geology",42,pins,"v3_2_single_s4_v1:earth:temperate");
    geo_reopen.finish({},true,true);
    std::cout<<"V3_CHECKPOINT_CONTRACT_PASS\n";
}
