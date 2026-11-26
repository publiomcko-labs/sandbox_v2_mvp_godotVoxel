#pragma once
#include "hydraulic_graph.hpp"
#include <numeric>

namespace sandbox::hydraulic::topology {
// Transient geometric samples only. No simulation quantity is attached to
// a sample. Equal-floor, overlapping air intervals are compressed into
// compartments, retaining distinct basins when their floors differ.
struct Snapshot {
    core::Region origin; // metres; X/Z tile origin, lower Y sample plane
    int nx{},ny{},nz{},step=1;
    std::uint64_t revision{};
    std::vector<std::uint8_t> air;
    bool open(int x,int y,int z)const{
        return air.at(static_cast<std::size_t>((z*nx+x)*ny+y))==1;
    }
};
struct Span {int x{},z{},bottom{},top{};Id compartment{};};
struct Compartment {Id id{};Curve curve;std::vector<Span> spans;};
struct Opening {Id a{},b{};int sill_mm{},soffit_mm{};double area_m2{};};
struct Boundary {Id compartment{};int face{},along{},bottom_mm{},top_mm{};};
struct Result {
    core::Region origin;
    int nx{},nz{},step{};
    std::uint64_t revision{};
    std::vector<Compartment> compartments;
    std::vector<Opening> openings;
    std::vector<Boundary> boundaries;
};
inline Result extract(const Snapshot &s) {
    if(s.nx<1||s.nx>32||s.nz<1||s.nz>32||s.ny<1||s.ny>128||
        s.step<1||s.step>4||std::abs(std::int64_t(s.origin.y))>99000||
        s.air.size()!=static_cast<std::size_t>(s.nx*s.ny*s.nz))
        throw std::invalid_argument("hydraulic snapshot bounds");
    for(auto v:s.air)if(v>1)throw std::invalid_argument("invalid air classification");
    Result result{s.origin,s.nx,s.nz,s.step,s.revision,{},{},{}};
    std::vector<Span> spans;
    std::vector<std::vector<std::size_t>> columns(static_cast<std::size_t>(s.nx*s.nz));
    auto column=[&](int x,int z)->auto&{return columns[static_cast<std::size_t>(z*s.nx+x)];};
    for(int z=0;z<s.nz;++z)for(int x=0;x<s.nx;++x) {
        for(int y=0;y<s.ny;) {
            if(!s.open(x,y,z)){++y;continue;}
            const int bottom=y;
            while(y<s.ny&&s.open(x,y,z))++y;
            column(x,z).push_back(spans.size());
            spans.push_back({x,z,bottom,y,0});
        }
    }
    std::vector<std::size_t> parent(spans.size());
    std::iota(parent.begin(),parent.end(),std::size_t{0});
    auto root=[&](std::size_t v){while(parent[v]!=v){parent[v]=parent[parent[v]];v=parent[v];}return v;};
    auto pairs=[&](auto visit){
        for(int z=0;z<s.nz;++z)for(int x=0;x<s.nx;++x)
            for(auto d:{core::Region{1,0,0},core::Region{0,0,1}}) {
                if(x+d.x>=s.nx||z+d.z>=s.nz)continue;
                for(auto a:column(x,z))for(auto b:column(x+d.x,z+d.z)) {
                    const auto lo=std::max(spans[a].bottom,spans[b].bottom);
                    const auto hi=std::min(spans[a].top,spans[b].top);
                    if(lo<hi)visit(a,b,lo,hi);
                }
            }
    };
    pairs([&](std::size_t a,std::size_t b,int,int) {
        if(spans[a].bottom!=spans[b].bottom)return;
        a=root(a);b=root(b);
        if(a!=b)parent[std::max(a,b)]=std::min(a,b);
    });
    std::map<Id,std::vector<Span>> groups;
    for(std::size_t i=0;i<spans.size();++i) {
        auto &v=spans[i];v.compartment=static_cast<Id>(root(i)+1);
        groups[v.compartment].push_back(v);
    }
    if(groups.size()>volume_count_limit)throw std::length_error("compartment limit");
    const auto mm=[&](int y){return (s.origin.y+y*s.step)*1000;};
    const auto litres=Litres(s.step)*s.step*s.step*1000;
    for(auto &[id,group]:groups) {
        std::map<int,int> ends;
        for(auto v:group){++ends[v.bottom];--ends[v.top];}
        std::vector<Knot> knots;
        Litres capacity=0;int active=0,previous=ends.begin()->first;
        for(auto [y,delta]:ends) {
            capacity+=Litres(y-previous)*active*litres;
            if(knots.empty()||capacity>knots.back().litres)knots.push_back({mm(y),capacity});
            active+=delta;previous=y;
        }
        result.compartments.push_back({id,Curve(std::move(knots)),std::move(group)});
    }
    std::map<std::array<Id,4>,double> apertures;
    pairs([&](std::size_t a,std::size_t b,int lo,int hi) {
        auto x=spans[a].compartment,y=spans[b].compartment;
        if(x==y)return;
        if(x>y)std::swap(x,y);
        // Index height in local samples, avoiding unsigned world altitude.
        apertures[{x,y,static_cast<Id>(lo),static_cast<Id>(hi)}]+=double(hi-lo)*s.step*s.step;
    });
    if(apertures.size()>portal_count_limit)throw std::length_error("portal limit");
    for(auto [k,area]:apertures)result.openings.push_back({k[0],k[1],mm(static_cast<int>(k[2])),mm(static_cast<int>(k[3])),area});
    for(auto v:spans) {
        if(v.x==0)result.boundaries.push_back({v.compartment,0,v.z,mm(v.bottom),mm(v.top)});
        if(v.x==s.nx-1)result.boundaries.push_back({v.compartment,1,v.z,mm(v.bottom),mm(v.top)});
        if(v.z==0)result.boundaries.push_back({v.compartment,2,v.x,mm(v.bottom),mm(v.top)});
        if(v.z==s.nz-1)result.boundaries.push_back({v.compartment,3,v.x,mm(v.bottom),mm(v.top)});
    }
    return result;
}
// Finite snapshot occupation at a known level, independent of litres per
// sample. The caller must still reject unloaded/unknown terrain and solid
// sub-sample geometry; this query never invents ocean connectivity.
inline std::optional<Id> compartment_at(const Result &r,core::Vec3 point) {
    const double x=(point.x-r.origin.x)/r.step,y=(point.y-r.origin.y)/r.step,z=(point.z-r.origin.z)/r.step;
    if(x<0||z<0||x>=r.nx||z>=r.nz)return {};
    const int ix=static_cast<int>(x),iz=static_cast<int>(z);
    for(const auto &c:r.compartments)for(const auto &s:c.spans)
        if(s.x==ix&&s.z==iz&&y>=s.bottom&&y<s.top)return c.id;
    return {};
}
}
