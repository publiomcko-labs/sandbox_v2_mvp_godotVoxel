#include "core/fluid_surface.hpp"
#include <cassert>
#include <iostream>
using namespace sandbox::fluid;
namespace sf=surface;
int main(){
    auto pool=[](Cell p)->Amount{
        if(p.x>=-2&&p.x<=17&&p.z>=-2&&p.z<=10&&p.y>=0&&p.y<=2)return {0,1000};
        return {};
    };
    const auto a=sf::build(pool,{0,0,0},0),b=sf::build(pool,{8,0,0},0);
    assert(!a.vertices.empty()&&a.vertices.size()%3==0);
    std::set<std::array<long long,5>> left,right;
    for(const auto &v:a.vertices){
        assert(std::isfinite(v.position.y)&&std::abs(sf::dot(v.normal,v.normal)-1)<1e-6);
        if(v.position.x>1&&v.position.x<7&&v.position.z>1&&v.position.z<7&&v.position.y>0.5)
            assert(std::abs(v.position.y-3)<0.001 && v.normal.y>0.99);
        if(std::abs(v.position.x-8.5)<1e-8)left.insert({std::llround(v.position.y*1e6),std::llround(v.position.z*1e6),std::llround(v.normal.x*1e6),std::llround(v.normal.y*1e6),std::llround(v.normal.z*1e6)});
    }
    for(const auto &v:b.vertices)if(std::abs(v.position.x-0.5)<1e-8)right.insert({std::llround(v.position.y*1e6),std::llround(v.position.z*1e6),std::llround(v.normal.x*1e6),std::llround(v.normal.y*1e6),std::llround(v.normal.z*1e6)});
    if(left!=right) {
        std::cerr<<"shared plane mismatch left="<<left.size()<<" right="<<right.size()<<"\n";
        for(const auto &p:left)if(!right.contains(p)) {std::cerr<<"left only "<<p[0]<<","<<p[1]<<"\n";break;}
        for(const auto &p:right)if(!left.contains(p)) {std::cerr<<"right only "<<p[0]<<","<<p[1]<<"\n";break;}
    }
    assert(!left.empty()&&left==right);
    auto patch=[](Cell p)->Amount {
        if(p.y!=1||p.z<1||p.z>5||p.x<1||p.x>5)return {};
        return {0,100+150*(p.x-1)};
    };
    const auto c=sf::build(patch,{0,0,0},0);
    bool slope=false;
    for(const auto &v:c.vertices)if(v.normal.y>0.2&&std::abs(v.normal.x)>0.05)slope=true;
    assert(!c.vertices.empty()&&slope);
    assert(sf::build(patch,{0,0,0},1).vertices.empty());
    assert(sf::build(patch,{24,0,0},0).vertices.empty());
    std::cout<<"V3_FLUID_SURFACE_PASS flat_pool no_internal_faces shared_boundary partial_slopes separate_types\n";
}
