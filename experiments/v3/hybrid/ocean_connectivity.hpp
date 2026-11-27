#pragma once
#include "core/hydraulic_topology.hpp"
#include <deque>
#include <memory>
#include <set>
#include <optional>
#include <map>

namespace sandbox::hydraulic::experiment {
namespace tp = sandbox::hydraulic::topology;
// A certificate is a local witness of a continuous exposed, submerged path
// from one explicit source. It is NOT an occupancy mask or terrain authority.
// All neighbors must have been certified for the SAME world revision.
// A terrain edit invalidates reachability proofs globally until re-proven;
// stored finite liquid is never discarded as a consequence.
struct OceanReach {
    std::string source;
    std::uint64_t world_revision{},geometry_revision{};
    core::Region key;
    double head{};
    int ceiling{};
    std::set<Id> compartments;
    using Neighbor=std::pair<const tp::Result*,const OceanReach*>;
    static OceanReach extend(const std::string& source,double head,int ceiling,std::uint64_t rev,
            const tp::Result& g,std::optional<Id> root,const std::vector<Neighbor>& neighbors) {
        OceanReach result{source,rev,g.revision,g.origin,head,ceiling,{}};
        if(source.empty()||!std::isfinite(head)||head>=ceiling||g.revision>rev)return result;
        std::set<Id> eligible;
        for(const auto &c:g.compartments){
            // A roofed interval cannot be initialized merely from an
            // ocean level, even if it belongs to a mixed compartment.
            if(!c.spans.empty()&&std::all_of(c.spans.begin(),c.spans.end(),[&](const auto &s){
                return g.origin.y+s.top*g.step==ceiling;
            })&&c.curve.at_level(head)>0)eligible.insert(c.id);
        }
        auto open=[&](const tp::Opening& p){return p.sill_mm<head*1000&&p.soffit_mm==ceiling*1000;};
        std::deque<Id> queue;
        auto add=[&](Id id){if(eligible.contains(id)&&result.compartments.insert(id).second)queue.push_back(id);};
        if(root)add(*root);
        for(const auto &[other,proof]:neighbors){
            if(!other||!proof||proof->key!=other->origin||proof->source!=source||
                proof->world_revision!=rev||proof->geometry_revision!=other->revision||
                proof->head!=head||proof->ceiling!=ceiling||other->step!=g.step)continue;
            const auto dx=other->origin.x-g.origin.x,dz=other->origin.z-g.origin.z;
            int face=-1;
            if(!dz&&dx==-other->nx*other->step)face=0;
            else if(!dz&&dx==g.nx*g.step)face=1;
            else if(!dx&&dz==-other->nz*other->step)face=2;
            else if(!dx&&dz==g.nz*g.step)face=3;
            if(face<0||other->origin.y!=g.origin.y)continue;
            for(const auto &p:tp::connect_faces(g,*other,face))
                if(open(p)&&proof->compartments.contains(p.b))add(p.a);
        }
        std::map<Id,std::vector<Id>> edges;
        for(const auto &p:g.openings)if(open(p)&&eligible.contains(p.a)&&eligible.contains(p.b)){
            edges[p.a].push_back(p.b);edges[p.b].push_back(p.a);
        }
        while(!queue.empty()){
            const auto id=queue.front();queue.pop_front();
            for(auto next:edges[id])add(next);
        }
        return result;
    }
    std::set<core::Region> frontier(const tp::Result& g)const {
        std::set<core::Region> result;
        if(key!=g.origin||geometry_revision!=g.revision)return result;
        for(const auto &edge:g.boundaries)if(edge.exposed&&compartments.contains(edge.compartment)&&
            edge.top_mm==ceiling*1000&&edge.bottom_mm<head*1000){
            result.insert({key.x+(edge.face==0?-g.nx*g.step:edge.face==1?g.nx*g.step:0),key.y,
                key.z+(edge.face==2?-g.nz*g.step:edge.face==3?g.nz*g.step:0)});
        }
        return result;
    }
};
}
