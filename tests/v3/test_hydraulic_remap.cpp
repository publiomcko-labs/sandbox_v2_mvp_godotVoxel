#include "core/hydraulic_remap.hpp"
#include "core/hydraulic_worker.hpp"
#include <cassert>
#include <iostream>
#include <thread>
using namespace sandbox::hydraulic;
namespace tp=topology;
int main(){
    tp::Snapshot s{{0,0,0},9,6,4,1,1,std::vector<std::uint8_t>(9*6*4,1)};
    const auto whole=tp::extract(s);
    const auto id=whole.compartments[0].id;
    auto cut=s;cut.revision=2;
    for(int z=0;z<4;++z)for(int y=0;y<6;++y)cut.air[static_cast<std::size_t>((z*9+4)*6+y)]=0;
    const auto split=tp::extract(cut);
    assert(split.compartments.size()==2);
    const std::map<Id,tp::Content> water{{id,{0,72000}}};
    auto separated=tp::remap(whole,split,water);
    assert(separated&&separated->finite==72000&&separated->contents.size()==2);
    for(const auto &[key,a]:separated->contents){(void)key;assert(a.litres>=32000);}
    auto open=s;open.revision=3;const auto merged=tp::extract(open);
    auto reunited=tp::remap(split,merged,separated->contents);
    assert(reunited&&reunited->contents.size()==1&&reunited->finite==72000);
    auto mixed=separated->contents;mixed.rbegin()->second.type=1;
    assert(!tp::remap(split,merged,mixed));
    const std::map<Id,tp::Content> full{{id,{0,216000}}};
    assert(!tp::remap(whole,split,full));
    auto solid=s;solid.revision=4;solid.air.assign(solid.air.size(),0);
    assert(!tp::remap(whole,tp::extract(solid),water));
    // Newly carved disconnected capacity starts dry.
    const auto dry=tp::remap(split,merged,{});
    assert(dry&&dry->finite==0&&dry->contents.empty());
    tp::Worker worker;
    assert(worker.submit(s));
    assert(worker.submit(cut)); // invalidates the first result even if complete
    assert(!worker.submit(s));
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    std::optional<tp::Result> result;
    while(worker.busy()&&std::chrono::steady_clock::now()<deadline) {
        if(auto v=worker.poll())result=std::move(v);
        std::this_thread::yield();
    }
    assert(!worker.busy()&&result&&result->revision==2&&result->compartments.size()==2);
    assert(worker.submit(open));worker.invalidate(open.origin);
    while(worker.busy()&&std::chrono::steady_clock::now()<deadline){assert(!worker.poll());std::this_thread::yield();}
    assert(!worker.busy());
    std::cout<<"V3_HYDRAULIC_REMAP_PASS split merge exact_mass displaced_capacity mixed_reject stale_worker\n";
}
