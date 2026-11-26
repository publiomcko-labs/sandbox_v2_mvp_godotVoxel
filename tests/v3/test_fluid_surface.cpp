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
        assert(std::abs(v.position.y-3)<1e-8&&v.normal.y>0.99); // top only: no bottoms or sidewalls
        if(std::abs(v.position.x-8.5)<1e-8)left.insert({std::llround(v.position.y*1e6),std::llround(v.position.z*1e6),std::llround(v.normal.x*1e6),std::llround(v.normal.y*1e6),std::llround(v.normal.z*1e6)});
    }
    for(const auto &v:b.vertices)if(std::abs(v.position.x-0.5)<1e-8)right.insert({std::llround(v.position.y*1e6),std::llround(v.position.z*1e6),std::llround(v.normal.x*1e6),std::llround(v.normal.y*1e6),std::llround(v.normal.z*1e6)});
    assert(!left.empty()&&left==right);
    auto patch=[](Cell p)->Amount {
        if(p.y!=1||p.z<1||p.z>5||p.x<1||p.x>5)return {};
        return {0,100+150*(p.x-1)};
    };
    const auto c=sf::build(patch,{0,0,0},0);
    bool slope=false;
    for(const auto &v:c.vertices){assert(v.normal.y>0.8);if(std::abs(v.normal.x)>0.02)slope=true;}
    assert(!c.vertices.empty()&&slope);
    assert(sf::build(patch,{0,0,0},1).vertices.empty());
    assert(sf::build(patch,{24,0,0},0).vertices.empty());
    auto stacked=[](Cell p)->Amount {
        if(p.x>=-1&&p.x<=9&&p.z>=-1&&p.z<=9&&(p.y==1||p.y==8))return {0,1000};
        return {};
    };
    auto lower=sf::build(stacked,{0,0,0},0),upper=sf::build(stacked,{0,8,0},0);
    assert(!lower.vertices.empty()&&!upper.vertices.empty());
    for(auto v:lower.vertices)assert(std::abs(v.position.y-2)<1e-8);
    for(auto v:upper.vertices)assert(std::abs(v.position.y-1)<1e-8);
    auto thin=[](Cell p)->Amount {return p.y==2&&p.z==3&&p.x==3?Amount{0,150}:Amount{};};
    assert(sf::build(thin,{0,0,0},0).vertices.empty());
    auto fall=[](Cell p)->Amount{return p.x==3&&p.y==4&&p.z==3?Amount{0,500}:Amount{};};
    const auto ribbon=sf::build_ribbons(thin,fall,{0,0,0},0);
    assert(ribbon.vertices.size()==12);
    for(auto v:ribbon.vertices){assert(std::abs(v.position.x-3.5)<0.4&&std::abs(v.position.z-3.5)<0.4);}
    assert(sf::build_ribbons(pool,fall,{0,0,0},1).vertices.empty());
    std::cout<<"V3_FLUID_SURFACE_PASS top_only shared_boundary partial_slopes stacked_layers thin_filter flow_ribbons separate_types\n";
}
