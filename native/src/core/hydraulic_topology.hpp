#pragma once
#include "hydraulic_graph.hpp"
#include <numeric>
#include <tuple>

namespace sandbox::hydraulic::topology {
// Transient geometric samples only. No simulation quantity is attached to
// a sample. Plateaus drain into a single downhill surface basin; distinct
// minima, large drops and enclosed air intervals retain separate portals.
struct Snapshot {
    core::Region origin; // metres; X/Z tile origin, lower Y sample plane
    int nx{},ny{},nz{},step=1;
    std::uint64_t revision{};
    std::vector<std::uint8_t> air;
    // Optional presentation-only SDF zero crossings at shared XZ vertices.
    // No liquid state, capacity or topology depends on these heights.
    std::vector<float> surface_floor{};
    // Optional one-column geometric halo. Ring only; interior entries in
    // halo_air are unused. It never creates compartments or portals.
    std::vector<float> halo_floor{};
    std::vector<std::uint8_t> halo_air{};
    // Runtime SDF snapshots can certify a conservative sub-metre floor.
    // Legacy archives and synthetic binary fixtures default to coarse floors.
    bool refine_exposed=false;
    std::vector<std::int16_t> render_sdf{};
    int render_pad{};
    bool open(int x,int y,int z)const{
        return air.at(static_cast<std::size_t>((z*nx+x)*ny+y))==1;
    }
};
struct Span {int x{},z{},bottom{},top{};Id compartment{};int floor_mm=std::numeric_limits<int>::min();};
struct Compartment {Id id{};Curve curve;std::vector<Span> spans;};
struct Opening {Id a{},b{};int sill_mm{},soffit_mm{};double area_m2{};};
struct Boundary {Id compartment{};int face{},along{},bottom_mm{},top_mm{};int coarse_bottom_mm{};bool exposed=false;};
struct Result {
    core::Region origin;
    int nx{},nz{},step{};
    std::uint64_t revision{};
    std::vector<Compartment> compartments;
    std::vector<Opening> openings;
    std::vector<Boundary> boundaries;
    std::vector<std::vector<Span>> column_runs;
    std::vector<float> surface_floor{};
    std::vector<float> halo_floor{};
    std::vector<std::vector<Span>> halo_runs{};
    bool refine_exposed=false;
    std::vector<std::int16_t> render_sdf{};
    int render_pad{},render_ny{};
};
inline int span_floor_mm(const Result &r,const Span &s) {
    return s.floor_mm==std::numeric_limits<int>::min()?(r.origin.y+s.bottom*r.step)*1000:s.floor_mm;
}
inline Result extract(const Snapshot &s) {
    if(s.nx<1||s.nx>32||s.nz<1||s.nz>32||s.ny<1||s.ny>128||
        s.step<1||s.step>4||std::abs(std::int64_t(s.origin.y))>99000||
        s.air.size()!=static_cast<std::size_t>(s.nx*s.ny*s.nz))
        throw std::invalid_argument("hydraulic snapshot bounds");
    for(auto v:s.air)if(v>1)throw std::invalid_argument("invalid air classification");
    if(!s.surface_floor.empty()&&s.surface_floor.size()!=static_cast<std::size_t>((s.nx+1)*(s.nz+1)))
        throw std::invalid_argument("hydraulic visual floor size");
    for(auto h:s.surface_floor)if(!std::isfinite(h)||h<s.origin.y||h>s.origin.y+s.ny*s.step)
        throw std::invalid_argument("hydraulic visual floor range");
    if(s.halo_floor.empty()!=s.halo_air.empty()||(!s.halo_floor.empty()&&
        (s.halo_floor.size()!=static_cast<std::size_t>((s.nx+3)*(s.nz+3))||
         s.halo_air.size()!=static_cast<std::size_t>((s.nx+2)*(s.nz+2)*s.ny))))
        throw std::invalid_argument("hydraulic visual halo size");
    for(auto h:s.halo_floor)if(!std::isfinite(h)||h<s.origin.y||h>s.origin.y+s.ny*s.step)
        throw std::invalid_argument("hydraulic visual halo floor");
    for(auto v:s.halo_air)if(v>1)throw std::invalid_argument("hydraulic visual halo classification");
    if(s.refine_exposed&&s.surface_floor.empty())throw std::invalid_argument("refined exposed floor requires SDF");
    Result result{s.origin,s.nx,s.nz,s.step,s.revision,{},{},{},{},s.surface_floor,s.halo_floor,{},s.refine_exposed};
    if(!s.render_sdf.empty()) {
        if(s.render_pad<0||s.render_pad>1||s.render_sdf.size()!=static_cast<std::size_t>((s.nx+1+2*s.render_pad)*(s.nz+1+2*s.render_pad)*(s.ny+1)))
            throw std::invalid_argument("render SDF shape");
        result.render_sdf=s.render_sdf;result.render_pad=s.render_pad;result.render_ny=s.ny;
    }
    const auto mm=[&](int y){return (s.origin.y+y*s.step)*1000;};
    if(!s.halo_air.empty()) {
        result.halo_runs.resize(static_cast<std::size_t>((s.nx+2)*(s.nz+2)));
        for(int z=-1;z<=s.nz;++z)for(int x=-1;x<=s.nx;++x) {
            if(x>=0&&x<s.nx&&z>=0&&z<s.nz)continue;
            const auto index=static_cast<std::size_t>((z+1)*(s.nx+2)+x+1);
            for(int y=0;y<s.ny;) {
                if(!s.halo_air[index*s.ny+y]){++y;continue;}
                const int bottom=y;
                while(y<s.ny&&s.halo_air[index*s.ny+y])++y;
                result.halo_runs[index].push_back({x,z,bottom,y,0});
            }
        }
    }
    std::vector<Span> spans;
    std::vector<std::vector<std::size_t>> columns(static_cast<std::size_t>(s.nx*s.nz));
    auto column=[&](int x,int z)->auto&{return columns[static_cast<std::size_t>(z*s.nx+x)];};
    for(int z=0;z<s.nz;++z)for(int x=0;x<s.nx;++x) {
        for(int y=0;y<s.ny;) {
            if(!s.open(x,y,z)){++y;continue;}
            const int bottom=y;
            while(y<s.ny&&s.open(x,y,z))++y;
            column(x,z).push_back(spans.size());
            int floor=mm(bottom);
            if(s.refine_exposed&&y==s.ny&&bottom>0) {
                // The entire bilinearly interpolated column is open above
                // the highest of its four last SDF zero crossings. Round
                // upward and retain a 1cm margin; never lower by >1 sample.
                double highest=s.origin.y;
                for(int dz=0;dz<=1;++dz)for(int dx=0;dx<=1;++dx)
                    highest=std::max(highest,double(s.surface_floor.at(static_cast<std::size_t>((z+dz)*(s.nx+1)+x+dx))));
                const auto certified=static_cast<int>(std::ceil(highest*1000.0))+10;
                floor=std::clamp(certified,mm(bottom-1),mm(bottom));
            }
            spans.push_back({x,z,bottom,y,0,floor});
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
        if(spans[a].bottom!=spans[b].bottom||(spans[a].top==s.ny)!=(spans[b].top==s.ny))return;
        a=root(a);b=root(b);
        if(a!=b)parent[std::max(a,b)]=std::min(a,b);
    });
    // Preserve coarse plateau IDs and the monotonic downhill contract:
    // a whole connected equal-floor plateau uses the highest certified
    // floor of its members, so no sub-cell saddle is bypassed within it.
    std::map<std::size_t,int> plateau_floor;
    for(std::size_t i=0;i<spans.size();++i)if(spans[i].top==s.ny) {
        const auto p=root(i);
        auto [it,inserted]=plateau_floor.emplace(p,spans[i].floor_mm);
        if(!inserted)it->second=std::max(it->second,spans[i].floor_mm);
    }
    for(std::size_t i=0;i<spans.size();++i)if(spans[i].top==s.ny)spans[i].floor_mm=plateau_floor.at(root(i));
    // First form equal-floor plateaus, then give each exposed plateau one
    // strictly descending outlet. Every path to its basin minimum stays
    // at or below its own floor: one free head is valid within the basin.
    // A saddle can belong to only one basin; other minima stay behind
    // portals at the actual saddle elevation. Never merge a roofed cave
    // into a surface basin or collapse a large waterfall into a plane.
    std::map<std::size_t,std::size_t> downhill;
    pairs([&](std::size_t a,std::size_t b,int,int) {
        if(spans[a].top!=s.ny||spans[b].top!=s.ny)return;
        a=root(a);b=root(b);
        if(a==b||spans[a].bottom==spans[b].bottom)return;
        if(spans[a].bottom<spans[b].bottom)std::swap(a,b);
        if((spans[a].bottom-spans[b].bottom)*s.step>2)return;
        auto it=downhill.find(a);
        if(it==downhill.end()||
            std::pair{spans[b].bottom,b}<std::pair{spans[it->second].bottom,it->second})
            downhill[a]=b;
    });
    for(auto [a,b]:downhill)parent[a]=b;
    std::map<Id,std::set<int>> events;
    for(std::size_t i=0;i<spans.size();++i) {
        auto &v=spans[i];v.compartment=static_cast<Id>(root(i)+1);
        events[v.compartment].insert(v.floor_mm);
        events[v.compartment].insert(mm(v.top));
    }
    std::map<Id,std::vector<Span>> groups;
    for(auto &v:spans) {
        // Keep the existing bounded curve representation on pathological
        // terrain; binary intervals remain a conservative fallback.
        if(events.at(v.compartment).size()>256)v.floor_mm=mm(v.bottom);
        groups[v.compartment].push_back(v);
    }
    if(groups.size()>volume_count_limit)throw std::length_error("compartment limit");
    const auto area=Litres(s.step)*s.step;
    for(auto &[id,group]:groups) {
        std::map<int,int> ends;
        for(auto v:group){++ends[v.floor_mm];--ends[mm(v.top)];}
        std::vector<Knot> knots;
        Litres capacity=0;int active=0,previous=ends.begin()->first;
        for(auto [y,delta]:ends) {
            capacity+=Litres(y-previous)*active*area;
            if(knots.empty()||capacity>knots.back().litres)knots.push_back({y,capacity});
            active+=delta;previous=y;
        }
        result.compartments.push_back({id,Curve(std::move(knots)),std::move(group)});
    }
    std::map<std::tuple<Id,Id,int,int>,double> apertures;
    pairs([&](std::size_t a,std::size_t b,int lo,int hi) {
        auto x=spans[a].compartment,y=spans[b].compartment;
        if(x==y)return;
        if(x>y)std::swap(x,y);
        // Refine only the exposed/exposed aperture. Roofed intervals
        // keep the exact conservative binary opening; no new cave portal.
        const int floor=spans[a].top==s.ny&&spans[b].top==s.ny?
            std::max(spans[a].floor_mm,spans[b].floor_mm):mm(lo);
        apertures[{x,y,floor,mm(hi)}]+=double(mm(hi)-floor)*0.001*s.step;
    });
    if(apertures.size()>portal_count_limit)throw std::length_error("portal limit");
    for(auto [k,opening_area]:apertures)result.openings.push_back({std::get<0>(k),std::get<1>(k),std::get<2>(k),std::get<3>(k),opening_area});
    result.column_runs.resize(static_cast<std::size_t>(s.nx*s.nz));
    for(auto v:spans) {
        result.column_runs[static_cast<std::size_t>(v.z*s.nx+v.x)].push_back(v);
        if(v.x==0)result.boundaries.push_back({v.compartment,0,v.z,v.floor_mm,mm(v.top),mm(v.bottom),v.top==s.ny});
        if(v.x==s.nx-1)result.boundaries.push_back({v.compartment,1,v.z,v.floor_mm,mm(v.top),mm(v.bottom),v.top==s.ny});
        if(v.z==0)result.boundaries.push_back({v.compartment,2,v.x,v.floor_mm,mm(v.top),mm(v.bottom),v.top==s.ny});
        if(v.z==s.nz-1)result.boundaries.push_back({v.compartment,3,v.x,v.floor_mm,mm(v.top),mm(v.bottom),v.top==s.ny});
    }
    return result;
}
// Finite snapshot occupation at a known level, independent of litres per
// sample. The caller must still reject unloaded/unknown terrain and solid
// sub-sample geometry; this query never invents ocean connectivity.
inline const Span* span_at(const Result &r,core::Vec3 point) {
    if(!core::valid_point(point))return {};
    const double x=(point.x-r.origin.x)/r.step,y=(point.y-r.origin.y)/r.step,z=(point.z-r.origin.z)/r.step;
    if(x<0||z<0||x>=r.nx||z>=r.nz)return {};
    const int ix=static_cast<int>(x),iz=static_cast<int>(z);
    for(const auto &s:r.column_runs.at(static_cast<std::size_t>(iz*r.nx+ix)))
        if(point.y*1000.0>=span_floor_mm(r,s)&&y<s.top)return &s;
    return nullptr;
}
inline std::optional<Id> compartment_at(const Result &r,core::Vec3 point) {
    if(const auto *s=span_at(r,point))return s->compartment;
    return {};
}
// Match only adjacent, simultaneously known tiles. No implicit connectivity
// to the ocean or unloaded region. IDs are local to each returned endpoint.
inline std::vector<Opening> connect_faces(const Result &a,const Result &b,int face) {
    if(face<0||face>3||a.step!=b.step)throw std::invalid_argument("face alignment");
    const int opposite=face^1;
    const bool xface=face<2;
    const auto aedge=xface?a.origin.x+(face==1?a.nx*a.step:0):a.origin.z+(face==3?a.nz*a.step:0);
    const auto bedge=xface?b.origin.x+(opposite==1?b.nx*b.step:0):b.origin.z+(opposite==3?b.nz*b.step:0);
    if(aedge!=bedge)throw std::invalid_argument("nonadjacent tiles");
    const int offset_a=xface?a.origin.z:a.origin.x,offset_b=xface?b.origin.z:b.origin.x;
    if((offset_a-offset_b)%a.step)throw std::invalid_argument("unaligned tile grids");
    std::multimap<int,Boundary> right;
    for(auto v:b.boundaries)if(v.face==opposite)right.emplace(offset_b+v.along*b.step,v);
    std::map<std::tuple<Id,Id,int,int>,double> merged;
    for(auto v:a.boundaries)if(v.face==face) {
        auto [first,last]=right.equal_range(offset_a+v.along*a.step);
        for(auto it=first;it!=last;++it) {
            const auto w=it->second;
            const int lo=v.exposed&&w.exposed?std::max(v.bottom_mm,w.bottom_mm):
                std::max(v.coarse_bottom_mm,w.coarse_bottom_mm);
            const int hi=std::min(v.top_mm,w.top_mm);
            if(lo<hi)merged[{v.compartment,w.compartment,lo,hi}]+=double(hi-lo)*0.001*a.step;
        }
    }
    if(merged.size()>portal_count_limit)throw std::length_error("boundary portal limit");
    std::vector<Opening> out;
    for(auto [k,area]:merged)out.push_back({std::get<0>(k),std::get<1>(k),std::get<2>(k),std::get<3>(k),area});
    return out;
}

}
