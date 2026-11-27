#pragma once
#include "hydraulic_topology.hpp"
namespace sandbox::hydraulic::topology {
struct Content {std::size_t type{};Litres litres{};};
struct Remap {std::map<Id,Content> contents;Litres finite{};};
// Immutable local transaction. Old and new geometry share the same tile.
// Wet overlap preserves the old distribution as far as possible. Only
// residual displaced/rounded litres may be assigned to other overlapping
// descendants. No source is inferred and no liquid is silently discarded.
inline std::optional<Remap> remap(const Result &old,const Result &next,
                                 const std::map<Id,Content> &contents) {
    if(old.origin!=next.origin||old.nx!=next.nx||old.nz!=next.nz||
        old.step!=next.step||next.revision<=old.revision)
        throw std::invalid_argument("remap geometry identity");
    std::map<Id,const Curve*> previous,capacity;
    for(const auto &c:old.compartments)previous.emplace(c.id,&c.curve);
    for(const auto &c:next.compartments)capacity.emplace(c.id,&c.curve);
    for(const auto &[id,a]:contents)if(!previous.contains(id)||a.litres<0||
        a.litres>previous.at(id)->capacity()||a.type>=32)throw std::invalid_argument("remap contents");
    Remap result;
    std::map<Id,std::map<Id,Litres>> overlap;
    std::map<Id,std::set<Id>> descendants;
    std::map<Id,int> levels;
    for(const auto &[id,a]:contents)if(a.litres) {
        result.finite+=a.litres;
        levels[id]=static_cast<int>(std::floor(previous.at(id)->level(a.litres)*1000.0+1e-7));
    }
    const auto mm=[&](int y){return (old.origin.y+y*old.step)*1000;};
    const Litres area=Litres(old.step)*old.step;
    for(std::size_t col=0;col<old.column_runs.size();++col)
        for(const auto &a:old.column_runs[col]) {
            auto l=levels.find(a.compartment);if(l==levels.end())continue;
            for(const auto &b:next.column_runs[col]) {
                const int lo=std::max(span_floor_mm(old,a),span_floor_mm(next,b)),hi=mm(std::min(a.top,b.top));
                if(lo>=hi)continue;
                descendants[a.compartment].insert(b.compartment);
                const int wet=std::max(0,std::min(hi,l->second)-lo);
                overlap[a.compartment][b.compartment]+=Litres(wet)*area;
            }
        }
    std::map<Id,Litres> residual;
    auto assign=[&](Id id,std::size_t type,Litres amount)->Litres {
        if(amount<=0)return 0;
        auto &out=result.contents[id];
        if(out.litres&&out.type!=type)return 0;
        const auto n=std::min(amount,capacity.at(id)->capacity()-out.litres);
        if(n>0){out.type=type;out.litres+=n;}return n;
    };
    // Reserve retained wet intersections for all old bodies first.
    for(const auto &[id,a]:contents)if(a.litres) {
        auto remaining=a.litres;
        for(const auto &[target,wet]:overlap[id]) {
            if(!wet)continue;
            auto existing=result.contents.find(target);
            if(existing!=result.contents.end()&&existing->second.litres&&existing->second.type!=a.type)return {};
            remaining-=assign(target,a.type,std::min(wet,remaining));
        }
        residual[id]=remaining;
    }
    // Rounding and solid displacement: use only a spatial descendant,
    // ranked by wet overlap then stable ID. Reject if capacity is lost.
    for(auto [id,remaining]:residual) {
        if(!remaining)continue;
        std::vector<Id> candidates(descendants[id].begin(),descendants[id].end());
        std::sort(candidates.begin(),candidates.end(),[&](Id a,Id b){
            const auto x=overlap[id][a],y=overlap[id][b];return x!=y?x>y:a<b;
        });
        for(auto target:candidates) {
            remaining-=assign(target,contents.at(id).type,remaining);
            if(!remaining)break;
        }
        if(remaining)return {};
    }
    Litres sum=0;for(const auto &[id,a]:result.contents){(void)id;sum+=a.litres;}
    if(sum!=result.finite)throw std::logic_error("remap mass mismatch");
    return result;
}
}
