#include "clipper2/clipper.h"
#include "clipper2/clipper.triangulation.h"
#include <cassert>
#include <chrono>
#include <iostream>
using namespace Clipper2Lib;
int main(){
    Paths64 cells;
    for(int z=0;z<16;++z)for(int x=0;x<16;++x)
        if(!(x>=6&&x<10&&z>=6&&z<10))
            cells.push_back(MakePath({x*1000,z*1000,(x+1)*1000,z*1000,(x+1)*1000,(z+1)*1000,x*1000,(z+1)*1000}));
    const auto begin=std::chrono::steady_clock::now();
    auto polygon=Union(cells,FillRule::NonZero);
    Paths64 triangles;
    assert(Triangulate(polygon,triangles)==TriangulateResult::success);
    double area=0;
    for(const auto &tri:triangles)area+=std::abs(Area(tri));
    assert(area==240000000.0);
    assert(polygon.size()==2);
    std::cout<<"V3_R1_CLIPPER_PASS area="<<area<<" clipper_triangles="<<triangles.size()
        <<" local_grid_triangles="<<cells.size()*2<<" union_triangulate_us="
        <<std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-begin).count()<<"\n";
}
