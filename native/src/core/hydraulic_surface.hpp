#pragma once
#include "hydraulic_topology.hpp"
namespace sandbox::hydraulic::surface {
struct Point {double x{},z{},floor{};};
struct Patch {int ceiling{};std::vector<Point> vertices;};
// Contours are evaluated at column centers, with a ghost ring clamped
// to the edge of the tile. Triangular interpolation removes the square
// corners without generating a volume mesh or tracking wet samples.
inline std::vector<Patch> build(const topology::Result &g,const topology::Compartment &c) {
    std::map<int,std::map<std::pair<int,int>,int>> layers;
    for(const auto &s:c.spans)layers[s.top].emplace(std::pair{s.x,s.z},s.bottom);
    std::vector<Patch> out;
    const auto sample=[&](int x,int z) {
        return std::pair{std::clamp(x,0,g.nx-1),std::clamp(z,0,g.nz-1)};
    };
    const auto position=[&](int x,int z) {
        return Point{double(std::clamp(x+0.5,0.0,double(g.nx))),double(std::clamp(z+0.5,0.0,double(g.nz)))};
    };
    for(const auto &[ceiling,mask]:layers) {
        Patch p{g.origin.y+ceiling*g.step,{}};
        auto owner=[&](int x,int z)->Id {
            const auto [ix,iz]=sample(x,z);
            for(const auto &run:g.column_runs[static_cast<std::size_t>(iz*g.nx+ix)])
                if(run.top==ceiling)return run.compartment;
            return 0;
        };
        auto member=[&](int x,int z){return owner(x,z)==c.id;};
        auto floor_at=[&](int x,int z){return double(g.origin.y+mask.at(sample(x,z))*g.step);};
        auto bank_cap=[&](int x,int z,double floor) {
            const auto [ix,iz]=sample(x,z);
            const auto &runs=g.column_runs[static_cast<std::size_t>(iz*g.nx+ix)];
            // A different open interval may own the neighboring surface.
            // Extend only toward the conservative solid classification.
            const double y=(floor-g.origin.y)/g.step+0.5;
            int cap=p.ceiling;
            for(const auto &s:runs) {
                if(y>=s.bottom&&y<s.top)return 0.0; // open neighbour: no apron
                if(s.bottom>y)cap=std::min(cap,g.origin.y+s.bottom*g.step);
            }
            return double(cap)-floor;
        };
        for(int z=-1;z<g.nz;++z)for(int x=-1;x<g.nx;++x) {
            constexpr std::array<std::pair<int,int>,4> offsets{{{0,0},{1,0},{1,1},{0,1}}};
            std::array<Point,4> pos{};std::array<bool,4> wet{};
            std::array<Id,4> owners{};
            int count=0;
            for(std::size_t i=0;i<4;++i) {
                const auto [dx,dz]=offsets[i];pos[i]=position(x+dx,z+dz);
                owners[i]=owner(x+dx,z+dz);
                wet[i]=member(x+dx,z+dz);
                if(wet[i]){++count;pos[i].floor=floor_at(x+dx,z+dz);}
                else if(owners[i]) {
                    const auto [ix,iz]=sample(x+dx,z+dz);
                    for(const auto &run:g.column_runs[static_cast<std::size_t>(iz*g.nx+ix)])
                        if(run.top==ceiling){pos[i].floor=g.origin.y+run.bottom*g.step;break;}
                }
            }
            if(!count)continue;
            const auto emit=[&](Patch &target,Point a,Point b,Point c0){
                const double area=(b.x-a.x)*(c0.z-a.z)-(b.z-a.z)*(c0.x-a.x);
                if(std::abs(area)<1e-10)return;
                if(area<0)std::swap(b,c0);
                target.vertices.insert(target.vertices.end(),{a,b,c0});
            };
            const auto clip=[&](std::array<int,3> tri) {
                // Three different labels cannot be represented by three
                // independent binary midpoint contours: they leave a hole
                // (or overlap with incompatible diagonals). Partition the
                // shared triangle at its centroid and edge midpoints.
                const auto i0=static_cast<std::size_t>(tri[0]),i1=static_cast<std::size_t>(tri[1]),i2=static_cast<std::size_t>(tri[2]);
                auto midpoint=[&](std::size_t a,std::size_t b){
                    const double floor=owners[a]&&owners[b]?(pos[a].floor+pos[b].floor)*0.5:
                        (owners[a]?pos[a].floor:pos[b].floor);
                    return Point{(pos[a].x+pos[b].x)*0.5,(pos[a].z+pos[b].z)*0.5,floor};
                };
                if(owners[i0]!=owners[i1]&&owners[i1]!=owners[i2]&&owners[i0]!=owners[i2]) {
                    double floor=0;int n=0;
                    for(auto i:{i0,i1,i2})if(owners[i]){floor+=pos[i].floor;++n;}
                    const Point center{(pos[i0].x+pos[i1].x+pos[i2].x)/3.0,
                        (pos[i0].z+pos[i1].z+pos[i2].z)/3.0,n?floor/n:0};
                    for(int i=0;i<3;++i) {
                        const auto a=static_cast<std::size_t>(tri[i]);
                        if(!wet[a])continue;
                        const auto b=static_cast<std::size_t>(tri[(i+1)%3]),d=static_cast<std::size_t>(tri[(i+2)%3]);
                        emit(p,pos[a],midpoint(a,b),center);
                        emit(p,pos[a],center,midpoint(d,a));
                    }
                    return;
                }
                std::vector<Point> poly;
                std::array<Point,2> mid{},outer{};
                int crossings=0,cap=p.ceiling;
                bool extended=false;
                for(int i=0;i<3;++i) {
                    const auto a=static_cast<std::size_t>(tri[static_cast<std::size_t>(i)]);
                    const auto b=static_cast<std::size_t>(tri[static_cast<std::size_t>((i+1)%3)]);
                    if(wet[a])poly.push_back(pos[a]);
                    if(wet[a]!=wet[b]) {
                        const auto w=wet[a]?a:b,n=wet[a]?b:a;
                        const auto [dx,dz]=offsets[n];
                        const auto clearance=bank_cap(x+dx,z+dz,pos[w].floor);
                        const auto blend=[&](double t) {
                            return Point{pos[w].x+(pos[n].x-pos[w].x)*t,
                                pos[w].z+(pos[n].z-pos[w].z)*t,pos[w].floor};
                        };
                        const auto j=static_cast<std::size_t>(crossings++);
                        mid[j]=midpoint(w,n);outer[j]=mid[j];
                        poly.push_back(mid[j]);
                        if(clearance>0) {
                            // Visual-only apron reaches the solid column
                            // center. When the head overtops the next air
                            // interval, the apron disappears; the other
                            // basin owns its own water instead.
                            outer[j]=blend(1.0);
                            cap=std::min(cap,static_cast<int>(std::lround(pos[w].floor+clearance)));
                            extended=true;
                        }
                    }
                }
                for(std::size_t i=1;i+1<poly.size();++i)emit(p,poly[0],poly[i],poly[i+1]);
                if(extended&&crossings==2) {
                    Patch apron{cap,{}};
                    emit(apron,mid[0],outer[0],outer[1]);
                    emit(apron,mid[0],outer[1],mid[1]);
                    if(!apron.vertices.empty())out.push_back(std::move(apron));
                }
            };
            // Choose ONE diagonal for every owner in this square. Preserve
            // the smooth single-corner shoreline rule for binary labels,
            // but never choose a diagonal independently for each basin.
            std::map<Id,int> counts;
            for(auto id:owners)++counts[id];
            bool diagonal=true;
            if(counts.size()==2)for(const auto &[label,n]:counts)if(n==1)
                diagonal=owners[1]==label||owners[3]==label;
            if(diagonal){clip({0,1,2});clip({0,2,3});}
            else{clip({0,1,3});clip({1,2,3});}
        }
        if(!p.vertices.empty())out.push_back(std::move(p));
    }
    return out;
}
}
