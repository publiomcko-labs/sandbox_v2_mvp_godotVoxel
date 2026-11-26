#pragma once
#include "hydraulic_topology.hpp"
namespace sandbox::hydraulic::surface {
struct Point {double x{},z{};};
struct Patch {int ceiling{};std::vector<Point> vertices;};
// Contours are evaluated at column centers, with a ghost ring clamped
// to the edge of the tile. Triangular interpolation removes the square
// corners without generating a volume mesh or tracking wet samples.
inline std::vector<Patch> build(const topology::Result &g,const topology::Compartment &c) {
    std::map<int,std::set<std::pair<int,int>>> layers;
    for(const auto &s:c.spans)layers[s.top].insert({s.x,s.z});
    std::vector<Patch> out;
    const auto sample=[&](int x,int z) {
        return std::pair{std::clamp(x,0,g.nx-1),std::clamp(z,0,g.nz-1)};
    };
    const auto position=[&](int x,int z) {
        return Point{double(std::clamp(x+0.5,0.0,double(g.nx))),double(std::clamp(z+0.5,0.0,double(g.nz)))};
    };
    for(const auto &[ceiling,mask]:layers) {
        Patch p{g.origin.y+ceiling*g.step,{}};
        auto member=[&](int x,int z){return mask.contains(sample(x,z));};
        auto solid_margin=[&](int x,int z) {
            const auto [ix,iz]=sample(x,z);
            const auto &runs=g.column_runs[static_cast<std::size_t>(iz*g.nx+ix)];
            // A different open interval may own the neighboring surface.
            // Extend only toward the conservative solid classification.
            const auto floor=c.curve.knots().front().mm*0.001;
            const double y=(floor-g.origin.y)/g.step+0.5;
            for(const auto &s:runs)if(y>=s.bottom&&y<s.top)return false;
            return true;
        };
        for(int z=-1;z<g.nz;++z)for(int x=-1;x<g.nx;++x) {
            constexpr std::array<std::pair<int,int>,4> offsets{{{0,0},{1,0},{1,1},{0,1}}};
            std::array<Point,4> pos{};std::array<bool,4> wet{},solid{};
            int count=0;
            for(std::size_t i=0;i<4;++i) {
                const auto [dx,dz]=offsets[i];pos[i]=position(x+dx,z+dz);
                wet[i]=member(x+dx,z+dz);solid[i]=solid_margin(x+dx,z+dz);
                if(wet[i])++count;
            }
            if(!count)continue;
            const auto emit=[&](Point a,Point b,Point c0){
                const double area=(b.x-a.x)*(c0.z-a.z)-(b.z-a.z)*(c0.x-a.x);
                if(std::abs(area)<1e-10)return;
                if(area<0)std::swap(b,c0);
                p.vertices.insert(p.vertices.end(),{a,b,c0});
            };
            const auto clip=[&](std::array<int,3> tri) {
                std::vector<Point> poly;
                for(int i=0;i<3;++i) {
                    const auto a=static_cast<std::size_t>(tri[static_cast<std::size_t>(i)]);
                    const auto b=static_cast<std::size_t>(tri[static_cast<std::size_t>((i+1)%3)]);
                    if(wet[a])poly.push_back(pos[a]);
                    if(wet[a]!=wet[b]) {
                        const auto w=wet[a]?a:b,n=wet[a]?b:a;
                        // Extend a little into terrain to let actual terrain
                        // depth occlude the conservative sampled shoreline.
                        const double t=solid[n]?0.9:0.5;
                        poly.push_back({pos[w].x+(pos[n].x-pos[w].x)*t,pos[w].z+(pos[n].z-pos[w].z)*t});
                    }
                }
                for(std::size_t i=1;i+1<poly.size();++i)emit(poly[0],poly[i],poly[i+1]);
            };
            // Choose the diagonal between dry corners for a single wet
            // corner; equivalent complement rule prevents diagonal spikes.
            if(count==1||count==3) {
                const bool minority=count==1;
                const bool diagonal=(wet[1]==minority||wet[3]==minority);
                if(diagonal){clip({0,1,2});clip({0,2,3});}
                else{clip({0,1,3});clip({1,2,3});}
            }else{clip({0,1,2});clip({0,2,3});}
        }
        if(!p.vertices.empty())out.push_back(std::move(p));
    }
    return out;
}
}
