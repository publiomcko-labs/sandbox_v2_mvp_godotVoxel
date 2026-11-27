#include "../../experiments/v3/hybrid/virtual_pipes.hpp"
#include "core/hydraulic_domain.hpp"
#include <cassert>
#include <chrono>
#include <iostream>
using namespace sandbox::hydraulic;
namespace ex=experiment;
using Clock=std::chrono::steady_clock;
static tp::Snapshot terrain(int nx,int nz,int ny,int wall,bool layers,bool slope) {
    tp::Snapshot s{{0,0,0},nx,ny,nz,1,1,std::vector<std::uint8_t>(static_cast<std::size_t>(nx*nz*ny),0)};
    for(int z=0;z<nz;++z)for(int x=0;x<nx;++x)for(int y=0;y<ny;++y) {
        const int floor=slope?3-x/4:0;
        const bool open=layers?(y>=6||(x!=wall&&y<4)):(x!=wall&&y>=floor);
        s.air[static_cast<std::size_t>((z*nx+x)*ny+y)]=open?1:0;
    }
    return s;
}
static Graph reference(const ex::Local &local,const std::vector<Liquid>& types) {
    Graph g(types);
    for(std::size_t i=0;i<local.columns().size();++i) {
        const auto &c=local.columns()[i];
        g.add_volume({static_cast<Id>(i+1),c.type,Curve({{c.floor_mm,0},{c.ceiling_mm,c.capacity()}}),c.litres});
    }
    for(std::size_t i=0;i<local.pipes().size();++i) {
        const auto &p=local.pipes()[i];
        g.add_portal({static_cast<Id>(i+1),static_cast<Id>(p.a+1),static_cast<Id>(p.b+1),p.sill,
            p.width*(p.soffit-p.sill),0.62,p.enabled,1,p.soffit-p.sill});
    }
    return g;
}
static long long quantile(std::vector<long long> values,double fraction) {
    std::sort(values.begin(),values.end());
    return values.at(static_cast<std::size_t>(std::ceil(fraction*double(values.size())))-1);
}
static void seed_left(ex::Local &local,int x,std::size_t type,Litres amount,bool lower_only=false) {
    for(std::size_t i=0;i<local.columns().size();++i) {
        const auto &c=local.columns()[i];
        if(c.x<x&&(!lower_only||c.floor_mm<6000))local.seed(i,type,amount);
    }
}
static int dam(std::size_t type,const std::vector<Liquid>& types,bool aggregate) {
    const auto closed=terrain(16,4,10,7,false,false);
    auto open=terrain(16,4,10,-1,false,false);open.revision=2;
    ex::Local before(tp::extract(closed),types);seed_left(before,7,type,2000);
    ex::Local vp(tp::extract(open),types);vp.copy_unchanged(before);
    auto h14=reference(vp,types);
    const auto mass=vp.mass();assert(mass==56000);
    if(aggregate){
        Domain domain(types,16,4,1,0);
        assert(domain.publish(tp::extract(closed)));
        assert(domain.seed_finite("dam",{0.5,0.1,0.5},type,2,true));
        assert(domain.graph().finite()==mass);
        domain.invalidate(open.origin,2);assert(domain.publish(tp::extract(open)));
        assert(domain.wet_at({15.5,0.1,1.5})&&domain.graph().finite()==mass);
        std::cout<<"V3_R2_AGGREGATE instant_far_wet=1 moved_ticks=0 mass="<<mass<<"\n";
    }
    int first_vp=-1,first_h14=-1,near_vp=-1,flips=0,old_sign=0;
    std::vector<long long> va,ha;
    Litres transfer=0;
    for(int tick=1;tick<=2000;++tick) {
        auto t=Clock::now();const auto report=vp.tick();
        va.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-t).count());
        t=Clock::now();h14.tick(128);
        ha.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-t).count());
        assert(vp.mass()==mass&&h14.finite()==mass);
        transfer+=report.moved;
        if(near_vp<0&&vp.mass_right(8)>=50)near_vp=tick;
        if(first_vp<0&&vp.mass_right(15)>=50)first_vp=tick;
        Litres far=0;for(std::size_t i=0;i<vp.columns().size();++i)
            if(vp.columns()[i].x==15)far+=h14.volumes().at(static_cast<Id>(i+1)).litres;
        if(first_h14<0&&far>=50)first_h14=tick;
        const double diff=vp.columns().front().head()-vp.columns().back().head();
        const int sign=diff>0.02?1:diff< -0.02?-1:0;
        if(sign&&old_sign&&sign!=old_sign)++flips;
        if(sign)old_sign=sign;
    }
    double err=0,reference_err=0;
    for(std::size_t i=0;i<vp.columns().size();++i) {
        err=std::max(err,std::abs(vp.columns()[i].head()-0.875));
        reference_err=std::max(reference_err,std::abs(h14.volumes().at(static_cast<Id>(i+1)).level()-0.875));
    }
    std::cout<<"V3_R2_DAM type="<<types[type].id<<" mass="<<mass<<" near_tick="<<near_vp<<" far_tick="<<first_vp
        <<" h14_same_intervals_far_tick="<<first_h14<<" max_head_error="<<err<<" h14_error="<<reference_err<<" oscillation_sign_flips="<<flips
        <<" local_p50_ns="<<quantile(va,0.5)<<" local_p95_ns="<<quantile(va,0.95)<<" local_p99_ns="<<quantile(va,0.99)
        <<" h14_p95_ns="<<quantile(ha,0.95)<<" local_persistent_bytes="<<vp.bytes()<<" moved="<<transfer<<std::endl;
    assert(near_vp>0&&first_vp>near_vp&&first_h14>0&&err<0.15&&quantile(va,0.95)<5000000);
    return first_vp;
}
int main(){
    const std::vector<Liquid> types{{"water",1,1000},{"lava",10,2800}};
    const int water=dam(0,types,true),lava=dam(1,types,false);
    assert(lava>water);
    // Inclined passage and a zero-width barrier closing equivalent
    // certified pipe faces without deleting wet capacity.
    auto slope=terrain(16,2,12,-1,false,true);
    ex::Local vp(tp::extract(slope),types);seed_left(vp,4,0,1500);
    auto h14=reference(vp,types);const auto mass=vp.mass();
    for(int tick=0;tick<100;++tick){vp.tick();h14.tick(128);}
    const auto right=vp.mass_right(8);assert(right>0);
    vp.close_crossing(8);
    for(std::size_t i=0;i<vp.pipes().size();++i)if(!vp.pipes()[i].enabled)h14.invalidate_portal(static_cast<Id>(i+1),2);
    const auto h14_right=[&](){Litres sum=0;for(std::size_t i=0;i<vp.columns().size();++i)if(vp.columns()[i].x>=8)sum+=h14.volumes().at(static_cast<Id>(i+1)).litres;return sum;};
    const auto aright=h14_right();
    for(int tick=0;tick<200;++tick){vp.tick();h14.tick(128);assert(vp.mass_right(8)==right&&h14_right()==aright);}
    assert(vp.mass()==mass&&h14.finite()==mass);
    std::cout<<"V3_R2_BARRIER_PASS local_right="<<right<<" h14_right="<<aright<<" total="<<mass<<"\n";
    // Two overlapping Y layers, lower sealed cavity initially dry.
    const auto closed=terrain(8,2,12,3,true,false);auto opened=terrain(8,2,12,-1,true,false);opened.revision=2;
    ex::Local isolated(tp::extract(closed),types);seed_left(isolated,3,0,1500,true);
    auto ag=reference(isolated,types);
    for(int tick=0;tick<40;++tick){isolated.tick();ag.tick(128);}
    assert(isolated.mass_right(4)==0);
    for(std::size_t i=0;i<isolated.columns().size();++i)if(isolated.columns()[i].floor_mm>=6000)assert(!isolated.columns()[i].litres&&!ag.volumes().at(static_cast<Id>(i+1)).litres);
    ex::Local connected(tp::extract(opened),types);connected.copy_unchanged(isolated);
    auto bg=reference(connected,types);
    for(int tick=0;tick<400;++tick){connected.tick();bg.tick(128);}
    assert(connected.mass_right(4)>0&&connected.mass()==isolated.mass()&&bg.finite()==isolated.mass());
    for(std::size_t i=0;i<connected.columns().size();++i)if(connected.columns()[i].floor_mm>=6000)assert(!connected.columns()[i].litres&&!bg.volumes().at(static_cast<Id>(i+1)).litres);
    ex::Local flooded(tp::extract(opened),types);flooded.seed(0,0,flooded.columns()[0].capacity());
    const auto report=flooded.tick();assert(report.pressure_blocked>0&&report.moved==0);
    std::cout<<"V3_R2_MULTILAYER_PASS connected_right="<<connected.mass_right(4)<<" mass="<<connected.mass()<<" pressure_blocked="<<report.pressure_blocked<<"\n";
    std::cout<<"V3_R2_MICROBENCH_PASS\n";
}
