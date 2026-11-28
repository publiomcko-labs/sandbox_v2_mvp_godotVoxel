#pragma once
#include "ocean_connectivity.hpp"
#include <algorithm>
#include <stdexcept>

namespace sandbox::hydraulic::experiment {
// Incremental, revision-bound discovery of a finite surface basin.
// Survey geometry is a temporary immutable witness, not a physical owner.
// Only unresolved frontier tiles need a live acquisition slot. No water
// is created until all reachable below-head boundaries are classified.
class FiniteBasinSurvey {
public:
    using Key=core::Region;
    using Contents=std::map<Id,Litres>;
private:
    Key root_;
    Id root_id_;
    double head_;
    int ceiling_;
    std::uint64_t revision_;
    std::map<Key,std::shared_ptr<const tp::Result>> geometry_;
    std::map<Key,Contents> reached_;
    std::set<Key> wanted_,dirty_;
    bool invalid_=false;
    static std::array<Key,4> neighbors(const tp::Result& g) {
        const auto k=g.origin;
        return {{{k.x-g.nx*g.step,k.y,k.z},{k.x+g.nx*g.step,k.y,k.z},
            {k.x,k.y,k.z-g.nz*g.step},{k.x,k.y,k.z+g.nz*g.step}}};
    }
    bool open(const tp::Opening& p)const{return p.sill_mm<head_*1000&&p.soffit_mm==ceiling_*1000;}
public:
    FiniteBasinSurvey(Key root,Id id,double head,int ceiling,std::uint64_t revision):
        root_(root),root_id_(id),head_(head),ceiling_(ceiling),revision_(revision),wanted_{root} {
        if(!std::isfinite(head)||head>=ceiling)throw std::invalid_argument("finite basin head");
    }
    std::uint64_t revision()const{return revision_;}
    const auto& wanted()const{return wanted_;}
    const auto& geometry()const{return geometry_;}
    const auto& reached()const{return reached_;}
    bool invalid()const{return invalid_;}
    bool complete()const{return !invalid_&&wanted_.empty()&&dirty_.empty()&&!reached_.empty();}
    bool offer(std::shared_ptr<const tp::Result> g) {
        if(!g||g->revision>revision_||!wanted_.contains(g->origin))return false;
        const auto k=g->origin;
        geometry_.emplace(k,std::move(g));wanted_.erase(k);dirty_.insert(k);
        return true;
    }
    void step(std::size_t budget=4) {
        while(budget--&&!dirty_.empty()&&!invalid_){
            const auto k=*dirty_.begin();dirty_.erase(dirty_.begin());
            const auto &g=*geometry_.at(k);
            Contents eligible;
            for(const auto &c:g.compartments){
                const bool exposed=std::any_of(c.spans.begin(),c.spans.end(),[&](const auto &s){
                    return g.origin.y+s.top*g.step==ceiling_;
                });
                if(exposed&&c.curve.at_level(head_)>0)eligible.emplace(c.id,c.curve.at_level(head_));
            }
            Contents found;
            if(auto it=reached_.find(k);it!=reached_.end())found=it->second;
            const auto before=found.size();
            std::deque<Id> queue;
            auto add=[&](Id id){if(eligible.contains(id)&&found.emplace(id,eligible.at(id)).second)queue.push_back(id);};
            if(k==root_){if(!eligible.contains(root_id_)){invalid_=true;return;}add(root_id_);}
            const auto adjacent=neighbors(g);
            for(std::size_t face=0;face<adjacent.size();++face){
                const auto q=adjacent[face];
                const auto p=reached_.find(q);
                if(p==reached_.end())continue;
                for(const auto &o:tp::connect_faces(g,*geometry_.at(q),static_cast<int>(face)))
                    if(open(o)&&p->second.contains(o.b))add(o.a);
            }
            std::map<Id,std::vector<Id>> links;
            for(const auto &o:g.openings)if(open(o)&&eligible.contains(o.a)&&eligible.contains(o.b)){
                links[o.a].push_back(o.b);links[o.b].push_back(o.a);
            }
            while(!queue.empty()){
                const auto id=queue.front();queue.pop_front();
                for(auto n:links[id])add(n);
            }
            if(found.size()==before)continue;
            reached_.insert_or_assign(k,std::move(found));
            for(const auto &b:g.boundaries)if(reached_.at(k).contains(b.compartment)&&
                b.top_mm==ceiling_*1000&&b.bottom_mm<head_*1000){
                const auto q=adjacent.at(static_cast<std::size_t>(b.face));
                if(!core::valid_point({double(q.x),double(q.y),double(q.z)})){invalid_=true;return;}
                if(!geometry_.contains(q))wanted_.insert(q);
                else dirty_.insert(q);
            }
        }
    }
};
}
