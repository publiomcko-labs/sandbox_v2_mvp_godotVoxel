#include "core/fluids.hpp"
#include <cassert>
#include <iostream>
using namespace sandbox::fluid;
int main(){
    Solver s({{500,1000},{50,2800}});
    bool barrier=true,loaded=true;
    auto probe=[&](Cell p) {
        if(p.x<0||p.x>5||p.z!=0||p.y<0||p.y>1)return Passage::solid;
        if(p.x==3&&!loaded)return Passage::unavailable;
        if(p.x==1&&barrier)return Passage::solid;
        return Passage::open;
    };
    assert(s.add({0,1,0},0,1000,probe,true));
    assert(s.add({0,0,0},0,1000,probe,true));
    assert(!s.add({1,0,0},0,100,probe,true));
    for(int i=0;i<4;++i)s.tick(probe);
    assert(s.at({2,0,0}).litres==0&&s.volume()==2000&&s.backlog()==0);
    barrier=false;s.invalidate({1,0,0},{1,1,0});
    auto a=s.tick(probe);
    assert(a.transferred>0&&s.at({1,0,0}).litres>0&&s.at({2,0,0}).litres==0);
    loaded=false;for(int i=0;i<10;++i)s.tick(probe);
    assert(s.volume()==2000&&s.at({3,0,0}).litres==0&&s.backlog()>0);
    loaded=true;for(int i=0;i<20;++i)s.tick(probe);
    assert(s.at({3,0,0}).litres>0&&s.volume()==2000);
    Solver r({{500,1000},{50,2800}});r.restore(s.cells(),s.initial(),s.injected(),s.drained());
    assert(r.cells()==s.cells()&&r.volume()==2000);
    assert(r.drain({0,0,0},100)>0&&r.volume()==r.initial()+r.injected()-r.drained());
    auto open=[](Cell p){return p.x>=0&&p.x<=2&&p.y==0&&p.z==0?Passage::open:Passage::solid;};
    Solver water({{500,1000},{50,2800}}),lava({{500,1000},{50,2800}});
    assert(water.add({0,0,0},0,1000,open,true)&&lava.add({0,0,0},1,1000,open,true));
    water.tick(open);lava.tick(open);
    assert(water.at({1,0,0}).litres==500&&lava.at({1,0,0}).litres==50);
    assert(lava.add({2,0,0},0,1000,open,true));
    for(int i=0;i<10;++i)lava.tick(open);
    assert(lava.at({2,0,0}).type==0&&lava.volume()==2000);
    bool rejected=false;try{Solver bad({{500,1000}});bad.restore(water.cells(),1,0,0);}catch(const std::invalid_argument&){rejected=true;}
    assert(rejected);
    // Same per-substep budget and terrain: one accelerated macro tick
    // is exactly five original water ticks; lava still executes once.
    auto shaft=[](Cell p){return p.x>=0&&p.x<=1&&p.z==0&&p.y>=0&&p.y<=10?Passage::open:Passage::solid;};
    Solver fast({{500,1000,5}}),normal({{500,1000,1}});
    assert(fast.add({0,10,0},0,1000,shaft,true)&&normal.add({0,10,0},0,1000,shaft,true));
    auto accelerated=fast.tick(shaft);
    for(int i=0;i<5;++i)normal.tick(shaft);
    assert(accelerated.substeps==5&&fast.cells()==normal.cells()&&fast.volume()==1000);
    bool reached_lower=false;
    for(const auto &[p,amount]:fast.cells())if(p.y<=8&&amount.litres>0)reached_lower=true;
    assert(reached_lower);
    Solver combined({{500,1000,5},{50,2800,1}}),slow({{500,1000,1},{50,2800,1}});
    assert(combined.add({1,10,0},1,1000,shaft,true)&&slow.add({1,10,0},1,1000,shaft,true));
    combined.tick(shaft);slow.tick(shaft);
    assert(combined.cells()==slow.cells()&&combined.falling_at({1,10,0}).litres==50);
    std::cout<<"V3_FLUID_5X_PASS five_water_substeps one_lava_substep same_mass\n";
    std::cout<<"V3_FLUID_CONSERVATION_PASS integer_litres progressive_flow blocked_boundary restore lava_rate no_mixing\n";
}
