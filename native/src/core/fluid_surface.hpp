#pragma once
#include "fluids.hpp"

namespace sandbox::fluid::surface {
using V=core::Vec3;
inline constexpr int tile_size=8;
struct Vertex {V position,normal;};
struct Mesh {int type{};std::vector<Vertex> vertices;};
inline V add(V a,V b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline V sub(V a,V b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
inline V mul(V a,double k){return {a.x*k,a.y*k,a.z*k};}
inline double dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline V cross(V a,V b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline V unit(V a){const auto n=std::sqrt(dot(a,a));return n>1e-9?mul(a,1.0/n):V{};}
inline void tri(Mesh &m,Vertex a,Vertex b,Vertex c) {
    auto n=cross(sub(b.position,a.position),sub(c.position,a.position));
    if(dot(n,n)<1e-20)return;
    if(dot(n,add(a.normal,add(b.normal,c.normal)))>0)std::swap(b,c);
    m.vertices.insert(m.vertices.end(),{a,b,c});
}
struct Top {int y{};double height{},coverage{};V normal{0,1,0};};
inline constexpr std::array<Cell,4> lateral{{{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}}};
inline constexpr int film=100; // visual threshold only; all litres remain authoritative
template<class At> std::optional<double> raw_top(At at,Cell p,int type) {
    const auto a=at(p),above=at(plus(p,{0,1,0}));
    if(a.type!=type||a.litres<film||(above.type==type&&above.litres>=film))return {};
    return double(p.y)+double(a.litres)/capacity;
}
template<class At> std::optional<double> nearest_top(At at,Cell p,int type,double target) {
    std::optional<double> best;
    double distance=1.15;
    for(int dy=-1;dy<=1;++dy) {
        auto h=raw_top(at,plus(p,{0,dy,0}),type);
        if(h&&std::abs(*h-target)<distance){best=h;distance=std::abs(*h-target);}
    }
    return best;
}
template<class At> std::optional<Top> make_top(At at,Cell p,int type) {
    const auto h=raw_top(at,p,type);
    if(!h)return {};
    const auto a=at(p);
    // A free surface is a 2.5D sheet for each exposed vertical run,
    // not an isosurface enclosing the occupied voxel volume.
    std::array<double,4> heights{*h,*h,*h,*h};
    double sum=*h*3,weight=3;
    int support=0;
    for(std::size_t i=0;i<lateral.size();++i) {
        auto q=nearest_top(at,plus(p,lateral[i]),type,*h);
        if(q) {
            heights[i]=*q;++support;
            if(std::abs(*q-*h)<0.65){sum+=*q;weight+=1;}
        }
    }
    // Small unsupported filaments are not rendered as solid water walls.
    // Their motion is represented by transient flow curtains instead.
    if(a.litres<220&&support<2)return {};
    const double height=sum/weight;
    const V normal=unit({(heights[0]-heights[1])*0.35,1,(heights[2]-heights[3])*0.35});
    const double coverage=std::clamp(double(a.litres)/400.0,0.25,1.0);
    return Top{p.y,height,coverage,normal};
}
struct Column {int x{},z{};std::vector<Top> tops;};
inline Vertex at_top(const Column &c,const Top &t,Cell origin) {
    return {{c.x+0.5,t.height-origin.y,c.z+0.5},t.normal};
}
inline Vertex edge_to_dry(const Vertex &wet,const Column &dry,double coverage) {
    // Shared edge has the same interpolation independent of triangle or tile.
    const auto t=0.3+0.24*coverage;
    return {{wet.position.x+(dry.x+0.5-wet.position.x)*t,wet.position.y,
             wet.position.z+(dry.z+0.5-wet.position.z)*t},wet.normal};
}
// Clip one planar triangle per connected height band. Layers whose heights
// differ by more than 1.15m never create a tall artificial wall or ramp.
inline void sheet_triangle(Mesh &m,const std::array<const Column*,3>& cols,Cell origin) {
    std::array<std::vector<bool>,3> used;
    for(std::size_t i=0;i<3;++i)used[i].resize(cols[i]->tops.size());
    for(;;) {
        int first=-1;std::size_t start=0;double low=std::numeric_limits<double>::infinity();
        for(int i=0;i<3;++i)for(std::size_t j=0;j<cols[i]->tops.size();++j)
            if(!used[i][j]&&cols[i]->tops[j].height<low){first=i;start=j;low=cols[i]->tops[j].height;}
        if(first<0)break;
        std::array<const Top*,3> selected{};
        selected[first]=&cols[first]->tops[start];used[first][start]=true;
        int owner=selected[first]->y;
        for(int i=0;i<3;++i)if(i!=first) {
            for(std::size_t j=0;j<cols[i]->tops.size();++j)if(!used[i][j]) {
                const auto &t=cols[i]->tops[j];
                if(t.height-low<=1.15) {
                    selected[i]=&t;used[i][j]=true;owner=std::min(owner,t.y);break;
                }
            }
        }
        // A unique vertical owner, with halo on both sides of the tile.
        if(owner<origin.y||owner>=origin.y+tile_size)continue;
        std::vector<Vertex> polygon;
        for(int i=0;i<3;++i) {
            const int j=(i+1)%3;
            if(selected[i])polygon.push_back(at_top(*cols[i],*selected[i],origin));
            if(bool(selected[i])!=bool(selected[j])) {
                const int wet=selected[i]?i:j,dry=selected[i]?j:i;
                polygon.push_back(edge_to_dry(at_top(*cols[wet],*selected[wet],origin),*cols[dry],selected[wet]->coverage));
            }
        }
        for(std::size_t i=1;i+1<polygon.size();++i)tri(m,polygon[0],polygon[i],polygon[i+1]);
    }
}
template<class At> Mesh build(At at,Cell origin,int type) {
    Mesh result{type,{}};
    constexpr int side=tile_size+1;
    std::array<Column,side*side> columns;
    for(int z=0;z<=tile_size;++z)for(int x=0;x<=tile_size;++x) {
        auto &c=columns[z*side+x];c.x=x;c.z=z;
        for(int y=origin.y-2;y<origin.y+tile_size+2;++y)
            if(auto t=make_top(at,{origin.x+x,y,origin.z+z},type))c.tops.push_back(*t);
    }
    for(int z=0;z<tile_size;++z)for(int x=0;x<tile_size;++x) {
        const auto *a=&columns[z*side+x],*b=&columns[z*side+x+1],
                   *c=&columns[(z+1)*side+x],*d=&columns[(z+1)*side+x+1];
        // Alternating diagonal avoids a preferred direction over the world.
        if((origin.x+x+origin.z+z)%2==0) {
            sheet_triangle(result,{a,b,d},origin);sheet_triangle(result,{a,d,c},origin);
        }else{
            sheet_triangle(result,{a,b,c},origin);sheet_triangle(result,{b,d,c},origin);
        }
    }
    return result;
}
// Downward transfers become narrow animated curtains, not side faces of
// filled cells. Only show them when at least one horizontal side is exposed.
template<class At,class Falling> Mesh build_ribbons(At at,Falling falling,Cell origin,int type) {
    Mesh result{type,{}};
    for(int z=0;z<tile_size;++z)for(int y=0;y<tile_size;++y)for(int x=0;x<tile_size;++x) {
        const Cell p{origin.x+x,origin.y+y,origin.z+z};
        const auto f=falling(p);
        if(f.type!=type||f.litres<80)continue;
        int sides=0;
        for(auto d:lateral){auto a=at(plus(p,d));if(a.type==type&&a.litres>=400)++sides;}
        if(sides>=3)continue;
        const auto current=at(p);
        const auto below=at(plus(p,{0,-1,0}));
        const auto above_fall=falling(plus(p,{0,1,0}));
        const bool linked_above=above_fall.type==type&&above_fall.litres>=80;
        const auto next=falling(plus(p,{0,-1,0}));
        const bool linked_below=next.type==type&&next.litres>=80;
        const double top=double(y)+(linked_above?1.0:std::clamp(double(current.litres)/capacity,0.25,1.0));
        const double bottom=double(y)-1+(linked_below?1.0:(below.type==type?double(below.litres)/capacity:0.0));
        if(top-bottom<0.05)continue;
        // Two crossed narrow strips, continuous across successive falls.
        const double half=0.10+0.22*std::sqrt(double(f.litres)/capacity);
        for(const auto axis:{V{0.70710678,0,0.70710678},V{0.70710678,0,-0.70710678}}) {
            const V mid{x+0.5,0,z+0.5},n=unit({-axis.z,0,axis.x});
            auto make=[&](double h,double side){return Vertex{add(add(mid,{0,h,0}),mul(axis,side*half)),n};};
            tri(result,make(top,-1),make(bottom,-1),make(bottom,1));
            tri(result,make(top,-1),make(bottom,1),make(top,1));
        }
    }
    return result;
}
}
