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
struct Sample {V p,gradient;double value;};
// Field on column centres and half-metre vertical steps. Interior full
// stacks have no interface. Partial top height follows fill fraction;
// only visual reconstruction, never used for occupancy or volume accounting.
template<class At> double field(At at,Cell origin,int x,int half_y,int z,int type) {
    const int y=half_y>=0?half_y/2:(half_y-1)/2;
    const auto a=at({origin.x+x,origin.y+y,origin.z+z});
    const auto below=at({origin.x+x,origin.y+y-1,origin.z+z});
    const double h=a.type==type?double(a.litres)/capacity:0.0;
    const double b=below.type==type?double(below.litres)/capacity:0.0;
    constexpr double eps=0.0001;
    if(half_y%2!=0) {
        const double v=h-0.5;
        return std::abs(v)<eps?eps:v;
    }
    if(h>0) {
        if(b>=1.0)return 0.5;
        return std::max(eps,std::min(h,0.15));
    }
    return b>0?std::min(-eps,b-1.0):-0.5;
}
inline Vertex edge(const Sample &a,const Sample &b) {
    // Fixed endpoint order gives identical boundary arithmetic.
    const Sample *p=&a,*q=&b;
    if(std::array{p->p.x,p->p.y,p->p.z}>std::array{q->p.x,q->p.y,q->p.z})std::swap(p,q);
    const double t=p->value/(p->value-q->value);
    return {add(p->p,mul(sub(q->p,p->p),t)),
        unit(mul(add(p->gradient,mul(sub(q->gradient,p->gradient),t)),-1))};
}
inline void tri(Mesh &m,Vertex a,Vertex b,Vertex c) {
    auto n=cross(sub(b.position,a.position),sub(c.position,a.position));
    // Keep tiny but non-degenerate triangles at nearly lattice-aligned
    // surfaces. Culling them independently creates unmatched tile edges.
    if(dot(n,n)<1e-26)return;
    const auto outward=add(a.normal,add(b.normal,c.normal));
    // Godot front faces are clockwise.
    if(dot(n,outward)>0){std::swap(b,c);n=mul(n,-1);}
    const auto fallback=unit(mul(n,-1));
    for(auto v:{a,b,c}){if(dot(v.normal,v.normal)<1e-8)v.normal=fallback;m.vertices.push_back(v);}
}
inline void tetra(Mesh &m,const std::array<Sample,8>& s,const std::array<int,4>& ids) {
    std::array<int,4> in{},out{};int ni=0,no=0;
    for(int i:ids)if(s[i].value>0)in[ni++]=i;else out[no++]=i;
    if(ni==0||ni==4)return;
    auto e=[&](int a,int b){return edge(s[a],s[b]);};
    if(ni==1){tri(m,e(in[0],out[0]),e(in[0],out[1]),e(in[0],out[2]));return;}
    if(ni==3){tri(m,e(out[0],in[0]),e(out[0],in[1]),e(out[0],in[2]));return;}
    const auto a=e(in[0],out[0]),b=e(in[0],out[1]),c=e(in[1],out[0]),d=e(in[1],out[1]);
    tri(m,a,b,c);tri(m,b,d,c);
}
template<class At> Mesh build(At at,Cell origin,int type) {
    Mesh result{type,{}};
    // Halo supplies central-difference gradients on both sides of each
    // shared tile boundary. Cubes have unique lower-corner ownership.
    constexpr int side=tile_size+3, height=tile_size*2+3;
    std::array<double,side*height*side> values{};
    auto idx=[](int x,int y,int z){return ((z+1)*height+y+1)*side+x+1;};
    for(int z=-1;z<=tile_size+1;++z)for(int y=-1;y<=tile_size*2+1;++y)for(int x=-1;x<=tile_size+1;++x)
        values[idx(x,y,z)]=field(at,origin,x,y,z,type);
    auto v=[&](int x,int y,int z){return values[idx(x,y,z)];};
    auto sample=[&](int x,int y,int z){
        return Sample{{x+0.5,y*0.5,z+0.5},
            {(v(x+1,y,z)-v(x-1,y,z))*0.5,v(x,y+1,z)-v(x,y-1,z),
             (v(x,y,z+1)-v(x,y,z-1))*0.5},v(x,y,z)};
    };
    constexpr std::array<std::array<int,4>,6> tets{{{{0,1,3,7}},{{0,3,2,7}},{{0,2,6,7}},{{0,6,4,7}},{{0,4,5,7}},{{0,5,1,7}}}};
    for(int z=0;z<tile_size;++z)for(int y=0;y<tile_size*2;++y)for(int x=0;x<tile_size;++x) {
        std::array<Sample,8> s{};
        int inside=0;
        for(int i=0;i<8;++i) {
            s[i]=sample(x+(i&1),y+((i>>1)&1),z+((i>>2)&1));
            if(s[i].value>0)++inside;
        }
        if(inside==0||inside==8)continue;
        for(const auto &t:tets)tetra(result,s,t);
    }
    return result;
}
}
