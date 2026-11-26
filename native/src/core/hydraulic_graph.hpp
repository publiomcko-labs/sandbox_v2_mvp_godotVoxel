#pragma once
#include "world_core.hpp"
#include <deque>
#include <string>

namespace sandbox::hydraulic {
using Id=std::uint32_t;
using Litres=std::int64_t;
inline constexpr Litres volume_limit=1'000'000'000'000LL;
inline constexpr Litres ledger_limit=1'000'000'000'000'000LL;
inline constexpr std::size_t volume_count_limit=4096,portal_count_limit=16384;
inline constexpr double tick_s=0.05;
inline constexpr std::size_t no_liquid=std::numeric_limits<std::size_t>::max();
struct Knot {int mm{};Litres litres{};auto operator<=>(const Knot&)const=default;};
class Curve {
    std::vector<Knot> knots_;
public:
    explicit Curve(std::vector<Knot> k):knots_(std::move(k)) {
        if(knots_.size()<2||knots_.size()>256||knots_.front().litres!=0)
            throw std::invalid_argument("capacity curve");
        for(std::size_t i=0;i<knots_.size();++i) {
            const auto v=knots_[i];
            if(std::abs(std::int64_t(v.mm))>100000000||v.litres<0||v.litres>volume_limit||
                (i&& (v.mm<=knots_[i-1].mm||v.litres<=knots_[i-1].litres)))
                throw std::invalid_argument("nonmonotonic capacity");
        }
    }
    const auto &knots()const{return knots_;}
    Litres capacity()const{return knots_.back().litres;}
    double level(Litres amount)const {
        if(amount<0||amount>capacity())throw std::invalid_argument("volume out of capacity");
        const auto i=std::lower_bound(knots_.begin(),knots_.end(),amount,[](Knot k,Litres v){return k.litres<v;});
        if(i==knots_.begin())return double(i->mm)*0.001;
        const auto a=*(i-1),b=*i;
        return (double(a.mm)+double(b.mm-a.mm)*double(amount-a.litres)/double(b.litres-a.litres))*0.001;
    }
    Litres at_level(double metres)const {
        if(!std::isfinite(metres))throw std::invalid_argument("invalid level");
        const auto mm=metres*1000.0;
        if(mm<=knots_.front().mm)return 0;
        if(mm>=knots_.back().mm)return capacity();
        const auto i=std::lower_bound(knots_.begin(),knots_.end(),mm,[](Knot k,double v){return double(k.mm)<v;});
        const auto a=*(i-1),b=*i;
        return a.litres+static_cast<Litres>(std::floor(double(b.litres-a.litres)*(mm-a.mm)/double(b.mm-a.mm)));
    }
};
struct Liquid {std::string id;double viscosity=1,density=1000;};
struct Volume {
    Id id{};std::size_t type{};Curve curve;Litres litres{};
    bool ocean=false;double ocean_level=0;
    double level()const{return ocean?ocean_level:curve.level(litres);}
};
struct Portal {
    Id id{},a{},b{};double sill_m{},area_m2{},coefficient=0.62;
    bool available=false;std::uint64_t revision{};double opening_height_m=0;
};
struct Transfer {Id portal{},from{},to{};Litres litres{};};
struct Report {std::size_t visited{},backlog{};Litres moved{};std::vector<Transfer> flows;};
class Graph {
    std::vector<Liquid> types_;
    std::map<Id,Volume> volumes_;
    std::map<Id,Portal> portals_;
    std::map<Id,std::set<Id>> adjacency_;
    std::set<Id> queued_;
    std::deque<Id> frontier_;
    // Sub-litre discharge credit belongs to an active directed portal,
    // never to a cell or to the conserved mass ledger.
    std::map<Id,std::pair<Id,double>> discharge_credit_;
    Litres initial_=0,injected_=0,drained_=0,finite_=0;
    void wake(Id id) {
        if(portals_.contains(id)&&portals_.at(id).available&&queued_.insert(id).second)frontier_.push_back(id);
    }
    void wake_volume(Id id){for(auto p:adjacency_[id])wake(p);}
    static void check_portal(const Portal &p) {
        if(!p.id||p.a==p.b||!std::isfinite(p.sill_m)||std::abs(p.sill_m)>100000||
            !std::isfinite(p.area_m2)||p.area_m2<=0||p.area_m2>4096||
            !std::isfinite(p.opening_height_m)||p.opening_height_m<0||p.opening_height_m>512||
            !std::isfinite(p.coefficient)||p.coefficient<=0||p.coefficient>1)
            throw std::invalid_argument("portal geometry");
    }
    static double level_after(const Volume &v,Litres delta){return v.ocean?v.ocean_level:v.curve.level(v.litres+delta);}
    // Cap movement at the equilibrium head and at the sill. No teleporting
    // across two portals in one tick: all proposals use pre-tick volumes.
    static Litres equilibrium(const Volume &a,const Volume &b,const Portal &p,Litres max,Litres a_delta,Litres b_delta) {
        Litres lo=0,hi=max;
        while(lo<hi) {
            const auto mid=lo+(hi-lo+1)/2;
            if(level_after(a,a_delta-mid)>=std::max(p.sill_m,level_after(b,b_delta+mid)))lo=mid;
            else hi=mid-1;
        }
        return lo;
    }
public:
    explicit Graph(std::vector<Liquid> types):types_(std::move(types)) {
        if(types_.empty()||types_.size()>32)throw std::invalid_argument("liquid types");
        std::set<std::string> ids;
        for(const auto &t:types_)if(t.id.empty()||!ids.insert(t.id).second||
            !std::isfinite(t.viscosity)||t.viscosity<0.01||t.viscosity>10000||
            !std::isfinite(t.density)||t.density<=0||t.density>100000)
            throw std::invalid_argument("liquid properties");
    }
    const auto &volumes()const{return volumes_;}
    const auto &portals()const{return portals_;}
    const auto &types()const{return types_;}
    Litres finite()const{return finite_;}
    Litres initial()const{return initial_;}
    Litres injected()const{return injected_;}
    Litres drained()const{return drained_;}
    std::size_t backlog()const{return frontier_.size();}
    void add_volume(Volume v) {
        if(!v.id||volumes_.contains(v.id)||volumes_.size()>=volume_count_limit||(v.type>=types_.size()&&!(v.type==no_liquid&&!v.litres&&!v.ocean))||
            v.litres<0||v.litres>v.curve.capacity()||
            (v.ocean&&(v.litres||!std::isfinite(v.ocean_level)||std::abs(v.ocean_level)>100000))||
            initial_>ledger_limit-v.litres)
            throw std::invalid_argument("volume definition");
        if(!v.ocean&&!v.litres)v.type=no_liquid;
        initial_+=v.litres;finite_+=v.litres;
        adjacency_.try_emplace(v.id);
        volumes_.emplace(v.id,std::move(v));
    }
    void add_portal(Portal p) {
        check_portal(p);
        if(portals_.size()>=portal_count_limit||portals_.contains(p.id)||!volumes_.contains(p.a)||!volumes_.contains(p.b)||
            (volumes_.at(p.a).ocean&&volumes_.at(p.b).ocean))
            throw std::invalid_argument("portal endpoints");
        portals_.emplace(p.id,p);adjacency_[p.a].insert(p.id);adjacency_[p.b].insert(p.id);wake(p.id);
    }
    const std::set<Id>& incident(Id id)const{return adjacency_.at(id);}
    // Used only on a staging graph during a topology transaction. The
    // caller restores the original ledger after remapped mass is installed.
    void erase_region(const std::set<Id> &ids) {
        std::set<Id> removed;
        for(auto id:ids) {
            const auto &v=volumes_.at(id);
            if(v.ocean)throw std::invalid_argument("cannot erase ocean as region");
            removed.insert(adjacency_.at(id).begin(),adjacency_.at(id).end());
        }
        for(auto id:removed) {
            const auto p=portals_.at(id);
            adjacency_.at(p.a).erase(id);adjacency_.at(p.b).erase(id);
            portals_.erase(id);queued_.erase(id);discharge_credit_.erase(id);
        }
        frontier_.erase(std::remove_if(frontier_.begin(),frontier_.end(),[&](Id id){return removed.contains(id);}),frontier_.end());
        for(auto id:ids){finite_-=volumes_.at(id).litres;volumes_.erase(id);adjacency_.erase(id);}
    }
    bool initialize(Id id,std::size_t type,Litres litres) {
        auto &v=volumes_.at(id);
        if(v.ocean||v.litres||type>=types_.size()||litres<=0||litres>v.curve.capacity()||initial_>ledger_limit-litres)return false;
        v.type=type;v.litres=litres;initial_+=litres;finite_+=litres;wake_volume(id);return true;
    }
    // Geometry revision protects against stale asynchronous analysis. A
    // pending/unloaded opening is closed, never assumed to communicate.
    bool publish_portal(Id id,double sill,double area,bool available,std::uint64_t revision) {
        auto &p=portals_.at(id);
        if(revision<p.revision)return false;
        auto next=p;next.sill_m=sill;next.area_m2=area;next.available=available;next.revision=revision;
        check_portal(next);p=next;discharge_credit_.erase(id);wake(id);return true;
    }
    void invalidate_portal(Id id,std::uint64_t revision) {
        auto &p=portals_.at(id);
        if(revision>=p.revision){p.available=false;p.revision=revision;discharge_credit_.erase(id);}
    }
    // Geometry replacement is fail-closed; caller must first conservatively
    // redistribute excess mass if a new curve cannot hold the current volume.
    bool replace_curve(Id id,Curve next) {
        auto &v=volumes_.at(id);
        if(v.ocean||v.litres>next.capacity())return false;
        v.curve=std::move(next);wake_volume(id);return true;
    }
    // Restore the exact ledger after loading all finite volumes. A restored
    // graph wakes only its available portals; no per-volume tick scan.
    void restore_ledger(Litres initial,Litres injected,Litres drained) {
        if(initial<0||injected<0||drained<0||initial>ledger_limit||injected>ledger_limit||
            drained>ledger_limit||initial+injected-drained!=finite_)
            throw std::invalid_argument("hydraulic mass ledger");
        initial_=initial;injected_=injected;drained_=drained;
    }
    Report tick(std::size_t budget=256) {
        Report r;
        if(budget>portal_count_limit)throw std::invalid_argument("portal budget");
        std::map<Id,Litres> incoming,outgoing;
        std::map<Id,std::size_t> incoming_type;
        std::set<Id> changed,retry;
        Litres inject=0,drain=0;
        const auto count=std::min(budget,frontier_.size());
        for(std::size_t i=0;i<count;++i) {
            const auto id=frontier_.front();frontier_.pop_front();queued_.erase(id);
            const auto &p=portals_.at(id);
            if(!p.available)continue;
            ++r.visited;
            const Volume *a=&volumes_.at(p.a),*b=&volumes_.at(p.b);
            if(a->level()<b->level())std::swap(a,b);
            if(a->type==no_liquid||(!a->ocean&&!a->litres)){discharge_credit_.erase(id);continue;}
            if((b->type!=no_liquid&&a->type!=b->type)||
                (incoming_type.contains(b->id)&&incoming_type.at(b->id)!=a->type)){discharge_credit_.erase(id);continue;}
            const double head=a->level()-std::max(b->level(),p.sill_m);
            if(head<=0.00001){discharge_credit_.erase(id);continue;}
            // Torricelli-type simplified discharge; not a Navier-Stokes solver.
            const double area=p.opening_height_m>0?p.area_m2*std::clamp((a->level()-p.sill_m)/p.opening_height_m,0.0,1.0):p.area_m2;
            // Broad, mutually submerged openings represent different
            // numerical partitions of one free body. Accelerate small
            // head corrections without accelerating a dry breach or fall.
            // Width is the actual summed face width for this aperture.
            double conductance=1.0;
            if(!a->ocean&&!b->ocean&&b->litres&&a->type==b->type&&p.opening_height_m>0) {
                const double width=p.area_m2/p.opening_height_m;
                const double depth=std::min(a->level(),b->level())-p.sill_m;
                const double wet=std::clamp((depth-0.15)/0.35,0.0,1.0);
                const double near_equal=std::clamp((1.0-head)/0.75,0.0,1.0);
                conductance+=std::clamp((width-1.0)*2.0,0.0,7.0)*wet*near_equal;
            }
            const auto q=conductance*p.coefficient*area*std::sqrt(2.0*9.81*head)*1000*tick_s/types_[a->type].viscosity;
            const auto credit=discharge_credit_.find(id);
            const double prior=credit!=discharge_credit_.end()&&credit->second.first==a->id?credit->second.second:0.0;
            const double discharge=std::min(q+prior,double(volume_limit));
            const auto rate=static_cast<Litres>(std::floor(discharge));
            auto free=a->ocean?std::min(volume_limit,ledger_limit-injected_-inject):
                std::max<Litres>(0,a->litres-a->curve.at_level(p.sill_m)-outgoing[a->id]);
            auto room=b->ocean?std::min(volume_limit,ledger_limit-drained_-drain):
                b->curve.capacity()-b->litres-incoming[b->id];
            const auto possible=std::min(free,room);
            const auto da=incoming[a->id]-outgoing[a->id],db=incoming[b->id]-outgoing[b->id];
            auto n=equilibrium(*a,*b,p,std::min(rate,possible),da,db);
            if(n<=0) {
                // A small but real opening must not stop permanently just
                // because its per-tick discharge rounds below one litre.
                // Stop retrying when even one litre would reverse the head.
                if(rate==0&&possible>0&&equilibrium(*a,*b,p,1,da,db)>0) {
                    discharge_credit_[id]={a->id,discharge};
                    retry.insert(id);
                } else discharge_credit_.erase(id);
                continue;
            }
            const double fraction=discharge-double(rate);
            if(n==rate&&fraction>0)discharge_credit_[id]={a->id,fraction};
            else discharge_credit_.erase(id);
            if(a->ocean)inject+=n;else outgoing[a->id]+=n;
            if(b->ocean)drain+=n;else {incoming[b->id]+=n;incoming_type[b->id]=a->type;}
            changed.insert(a->id);changed.insert(b->id);
            retry.insert(id);
            r.moved+=n;r.flows.push_back({id,a->id,b->id,n});
        }
        for(auto id:changed) {
            auto &v=volumes_.at(id);
            if(!v.ocean){
                if(incoming_type.contains(id))v.type=incoming_type.at(id);
                v.litres+=incoming[id]-outgoing[id];
                if(!v.litres)v.type=no_liquid;
            }
        }
        injected_+=inject;drained_+=drain;finite_+=inject-drain;
        for(auto id:changed)wake_volume(id);
        for(auto id:retry)wake(id);
        r.backlog=frontier_.size();return r;
    }
};
}
