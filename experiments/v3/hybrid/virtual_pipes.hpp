#pragma once
#include "core/hydraulic_topology.hpp"
namespace sandbox::hydraulic::experiment {
// R2 microbenchmark only; no engine dependency and no change to H14.
// One free-surface interval per column layer, never one state per voxel.
struct Column {
    int x{},z{},floor_mm{},ceiling_mm{},area_m2=1;
    Litres litres{};
    std::size_t type=no_liquid;
    double floor()const{return floor_mm*0.001;}
    double ceiling()const{return ceiling_mm*0.001;}
    Litres capacity()const{return Litres(ceiling_mm-floor_mm)*area_m2;}
    double head()const{return floor()+double(litres)/(1000.0*area_m2);}
};
struct Pipe {
    std::size_t a{},b{};
    double sill{},soffit{},width{},length{};
    double flux{},credit{};
    bool enabled=true;
};
struct Tick {
    Litres moved{};
    std::size_t pressure_blocked{};
};
class Local {
    std::vector<Liquid> types_;
    std::vector<Column> columns_;
    std::vector<Pipe> pipes_;
    std::vector<std::vector<std::size_t>> column_index_;
    int width_{},depth_{};
    Litres initial_{};
    static constexpr int substeps=4;
    static constexpr double dt=tick_s/substeps;
    struct Proposal {std::size_t from{},to{},edge{};Litres amount{};double q{},credit{};};
    Tick substep() {
        Tick report;
        std::vector<Proposal> proposals;proposals.reserve(pipes_.size());
        std::vector<Litres> outgoing(columns_.size()),incoming(columns_.size());
        std::vector<std::size_t> type(columns_.size(),no_liquid);
        for(std::size_t e=0;e<pipes_.size();++e) {
            auto &p=pipes_[e];const auto &a=columns_[p.a],&b=columns_[p.b];
            if(!p.enabled||(a.litres&&b.litres&&a.type!=b.type)){p.flux=p.credit=0;continue;}
            // No pressure model in R2: a completely flooded bounded
            // interval is explicitly unsupported, never fictitiously pressurized.
            if(a.litres==a.capacity()||b.litres==b.capacity()) {
                ++report.pressure_blocked;p.flux=p.credit=0;continue;
            }
            const double ha=a.head(),hb=b.head();
            const double depth=std::max(0.0,std::min(std::max(ha,hb),p.soffit)-p.sill);
            if(depth<=0||(!a.litres&&!b.litres)){p.flux=p.credit=0;continue;}
            const double area=depth*p.width;
            const double delta=std::max(ha,p.sill)-std::max(hb,p.sill);
            const auto material=a.litres?a.type:b.type;
            // Dagenais et al. 2018: inertial virtual-pipe acceleration
            // and implicit vertical shear damping. Relative mod viscosity
            // is mapped to an uncalibrated effective coefficient for R2.
            const double nu=0.05*types_.at(material).viscosity;
            const double damping=depth*depth/(depth*depth+3.0*dt*nu);
            double q=(p.flux+dt*9.81*area*delta/p.length)*damping;
            const double cfl_q=0.45*p.length/dt*area;
            q=std::clamp(q,-cfl_q,cfl_q);
            if(!std::isfinite(q))throw std::logic_error("R2 nonfinite flux");
            const auto from=q>=0?p.a:p.b,to=q>=0?p.b:p.a;
            const auto &source=columns_[from],&target=columns_[to];
            if(!source.litres||source.head()<=p.sill||target.litres==target.capacity()||
                (target.litres&&target.type!=source.type)||(type[to]!=no_liquid&&type[to]!=source.type)) {
                p.flux=p.credit=0;continue;
            }
            const auto above=static_cast<Litres>(std::floor((source.head()-std::max(source.floor(),p.sill))*1000.0*source.area_m2+1e-8));
            const double carry=p.flux*q>0?p.credit:0.0;
            const double exact=std::abs(q)*dt*1000.0+carry;
            const auto whole=static_cast<Litres>(std::floor(exact));
            const auto wanted=std::min({whole,source.litres,above,target.capacity()-target.litres});
            const double credit=wanted==whole?exact-double(whole):0.0;
            p.flux=q;p.credit=credit;
            if(wanted<=0)continue;
            proposals.push_back({from,to,e,wanted,q,credit});
            outgoing[from]+=wanted;incoming[to]+=wanted;type[to]=source.type;
        }
        std::vector<Litres> sent(columns_.size()),received(columns_.size());
        for(const auto &v:proposals) {
            const auto &source=columns_[v.from],&target=columns_[v.to];
            const double scale=std::min({1.0,double(source.litres)/double(outgoing[v.from]),
                double(target.capacity()-target.litres)/double(incoming[v.to])});
            const auto amount=std::min({static_cast<Litres>(std::floor(double(v.amount)*scale)),
                source.litres-sent[v.from],target.capacity()-target.litres-received[v.to]});
            auto &p=pipes_[v.edge];
            if(amount<v.amount) {
                p.flux=std::copysign(double(amount)/(dt*1000.0),v.q);p.credit=0;
            }
            sent[v.from]+=amount;received[v.to]+=amount;report.moved+=amount;
        }
        for(std::size_t i=0;i<columns_.size();++i) {
            auto &c=columns_[i];
            if(!c.litres&&received[i])c.type=type[i];
            c.litres+=received[i]-sent[i];
            if(!c.litres)c.type=no_liquid;
            if(c.litres<0||c.litres>c.capacity())throw std::logic_error("R2 capacity invariant");
        }
        return report;
    }
public:
    Local(const topology::Result &g,std::vector<Liquid> types):types_(std::move(types)) {
        if(g.step!=1||g.nx>32||g.nz>32||types_.empty())throw std::invalid_argument("R2 local bounds");
        width_=g.nx;depth_=g.nz;column_index_.resize(g.column_runs.size());
        auto &indexes=column_index_;
        for(std::size_t i=0;i<g.column_runs.size();++i)for(const auto &s:g.column_runs[i]) {
            indexes[i].push_back(columns_.size());
            columns_.push_back({s.x,s.z,topology::span_floor_mm(g,s),(g.origin.y+s.top*g.step)*1000,1,0,no_liquid});
        }
        int top_mm=std::numeric_limits<int>::min();for(const auto &cell:columns_)top_mm=std::max(top_mm,cell.ceiling_mm);
        for(int z=0;z<g.nz;++z)for(int x=0;x<g.nx;++x)
            for(auto d:{core::Region{1,0,0},core::Region{0,0,1}}) {
                if(x+d.x>=g.nx||z+d.z>=g.nz)continue;
                const auto i=static_cast<std::size_t>(z*g.nx+x),j=static_cast<std::size_t>((z+d.z)*g.nx+x+d.x);
                for(auto a:indexes[i])for(auto b:indexes[j]) {
                    const auto &u=columns_[a],&v=columns_[b];
                    const auto coarse=[&](const Column& c){
                        for(const auto &s:g.column_runs[static_cast<std::size_t>(c.z*g.nx+c.x)])
                            if(topology::span_floor_mm(g,s)==c.floor_mm&&(g.origin.y+s.top)*1000==c.ceiling_mm)
                                return double(g.origin.y+s.bottom);
                        throw std::logic_error("R2 interval mapping");
                    };
                    const bool both_exposed=u.ceiling_mm==v.ceiling_mm&&u.ceiling_mm==top_mm;
                    const double sill=both_exposed?std::max(u.floor(),v.floor()):std::max(coarse(u),coarse(v));
                    const double soffit=std::min(u.ceiling(),v.ceiling());
                    if(sill<soffit)pipes_.push_back({a,b,sill,soffit,1,1,0,0,true});
                }
            }
    }
    const auto& columns()const{return columns_;}
    const auto& column_indices(int x,int z)const {
        if(x<0||x>=width_||z<0||z>=depth_)throw std::out_of_range("local column");
        return column_index_.at(static_cast<std::size_t>(z*width_+x));
    }
    const auto& pipes()const{return pipes_;}
    void seed(std::size_t i,std::size_t type,Litres litres) {
        auto &c=columns_.at(i);
        if(c.litres||type>=types_.size()||litres<=0||litres>c.capacity())throw std::invalid_argument("R2 seed");
        c.type=type;c.litres=litres;initial_+=litres;
    }
    // R3 exclusive-owner interface. The caller owns the global ledger;
    // these operations update only the local expected mass.
    bool receive(std::size_t i,std::size_t type,Litres amount) {
        auto &c=columns_.at(i);
        if(type>=types_.size()||amount<=0||amount>c.capacity()-c.litres||
            (c.litres&&c.type!=type))return false;
        c.type=type;c.litres+=amount;initial_+=amount;return true;
    }
    bool withdraw(std::size_t i,Litres amount) {
        auto &c=columns_.at(i);
        if(amount<=0||amount>c.litres)return false;
        c.litres-=amount;initial_-=amount;if(!c.litres)c.type=no_liquid;return true;
    }
    void restore_pipe(std::size_t i,double flux,double credit) {
        if(!std::isfinite(flux)||!std::isfinite(credit)||credit<0||credit>=1.0||
            std::abs(flux)>100000.0)throw std::invalid_argument("R3 pipe archive");
        auto &p=pipes_.at(i);p.flux=flux;p.credit=credit;
    }
    // For the microfixture only: exact unchanged interval mapping after
    // an opening adds columns. No deletion or general remap implied.
    void copy_unchanged(const Local& previous) {
        for(const auto &c:previous.columns_)if(c.litres) {
            const auto it=std::find_if(columns_.begin(),columns_.end(),[&](const auto &v){
                return v.x==c.x&&v.z==c.z&&v.floor_mm==c.floor_mm&&v.ceiling_mm==c.ceiling_mm;
            });
            if(it==columns_.end())throw std::invalid_argument("R2 changed wet interval unsupported");
            seed(static_cast<std::size_t>(it-columns_.begin()),c.type,c.litres);
        }
    }
    // Stage a carve in the same horizontal footprint. Retain occupied
    // overlap first, then displaced litres only in spatial descendants.
    // Reject an incompatible edit rather than spreading into a dry cell.
    bool remap_from(const Local& previous,bool displace=false) {
        std::map<std::pair<int,int>,std::vector<std::size_t>> index;
        for(std::size_t i=0;i<columns_.size();++i)index[{columns_[i].x,columns_[i].z}].push_back(i);
        struct Residual {std::size_t old_index,type;Litres left;std::vector<std::size_t> targets;};
        std::vector<Residual> residuals;
        for(std::size_t old_index=0;old_index<previous.columns_.size();++old_index){
            const auto &old=previous.columns_[old_index];if(!old.litres)continue;
            Residual rem{old_index,old.type,old.litres,{}};
            for(auto i:index[{old.x,old.z}]) {
                const auto &c=columns_[i];
                const int lo=std::max(old.floor_mm,c.floor_mm),hi=std::min(old.ceiling_mm,c.ceiling_mm);
                if(lo>=hi)continue;
                const auto wet=std::max<Litres>(0,std::min<Litres>(hi,Litres(old.floor_mm)+old.litres)-lo);
                if(!displace||wet>0)rem.targets.push_back(i);
                const auto n=std::min({wet,rem.left,c.capacity()-c.litres});
                if(n&&!receive(i,old.type,n))return false;
                rem.left-=n;
            }
            residuals.push_back(std::move(rem));
        }
        for(auto &rem:residuals)for(auto i:rem.targets) {
            const auto n=std::min(rem.left,columns_[i].capacity()-columns_[i].litres);
            if(n&&!receive(i,rem.type,n))return false;
            rem.left-=n;
        }
        if(displace&&std::any_of(residuals.begin(),residuals.end(),[](const auto &v){return v.left>0;})){
            // Displaced mass may go only to surviving wet descendants
            // connected by submerged openings in the PRE-edit state.
            // Construction cannot initialize a new dry interval.
            std::vector<std::size_t> parent(previous.columns_.size());
            std::iota(parent.begin(),parent.end(),std::size_t(0));
            auto root=[&](std::size_t i){while(parent[i]!=i){parent[i]=parent[parent[i]];i=parent[i];}return i;};
            for(const auto &p:previous.pipes_){
                const auto &a=previous.columns_[p.a],&b=previous.columns_[p.b];
                if(p.enabled&&a.litres&&b.litres&&a.type==b.type&&std::min(a.head(),b.head())>p.sill&&p.soffit>p.sill)
                    parent[root(p.a)]=root(p.b);
            }
            struct Displaced {std::size_t type=no_liquid;Litres amount{};std::set<std::size_t> recipients;};
            std::map<std::size_t,Displaced> groups;
            for(auto &rem:residuals){
                auto &group=groups[root(rem.old_index)];group.type=rem.type;group.amount+=rem.left;
                for(auto i:rem.targets)if(columns_[i].litres&&columns_[i].type==rem.type)group.recipients.insert(i);
                rem.left=0;
            }
            for(auto &[key,group]:groups){
                (void)key;if(!group.amount)continue;
                if(group.recipients.empty())return false;
                int lo=std::numeric_limits<int>::max(),hi=std::numeric_limits<int>::min();
                for(auto i:group.recipients){lo=std::min(lo,columns_[i].floor_mm);hi=std::max(hi,columns_[i].ceiling_mm);}
                auto room=[&](std::size_t i,int mm){
                    const auto &c=columns_[i];
                    return std::max<Litres>(0,std::clamp(Litres(mm-c.floor_mm)*c.area_m2,Litres(0),c.capacity())-c.litres);
                };
                auto free_at=[&](int mm){Litres sum=0;for(auto i:group.recipients)sum+=room(i,mm);return sum;};
                if(free_at(hi)<group.amount)return false;
                while(lo<hi){const int mid=lo+(hi-lo)/2;if(free_at(mid)>=group.amount)hi=mid;else lo=mid+1;}
                // Deterministic common-head displacement; residual integer
                // litres use stable interval order. No cross-tile teleport.
                for(int mm:{lo-1,lo})for(auto i:group.recipients){
                    const auto n=std::min(group.amount,room(i,mm));
                    if(n&&!receive(i,group.type,n))return false;
                    group.amount-=n;
                }
                if(group.amount)return false;
            }
        }
        for(const auto &rem:residuals)if(rem.left)return false;
        // Retain momentum only on identical intervals and openings.
        // Changed apertures restart their inertial state.
        using Key=std::tuple<int,int,int,int>;
        auto key=[](const Column& c){return Key{c.x,c.z,c.floor_mm,c.ceiling_mm};};
        std::map<std::pair<Key,Key>,std::pair<double,double>> history;
        for(const auto &p:previous.pipes_)if(p.enabled)
            history.emplace(std::pair{key(previous.columns_[p.a]),key(previous.columns_[p.b])},std::pair{p.flux,p.credit});
        for(auto &p:pipes_) {
            auto it=history.find({key(columns_[p.a]),key(columns_[p.b])});
            if(it!=history.end()){p.flux=it->second.first;p.credit=it->second.second;}
        }
        return mass()==previous.mass();
    }
    void close_crossing(int x) {
        for(auto &p:pipes_)if((columns_[p.a].x<x)!=(columns_[p.b].x<x)){p.enabled=false;p.flux=p.credit=0;}
    }
    Litres mass()const{Litres sum=0;for(const auto &c:columns_)sum+=c.litres;return sum;}
    Litres mass_right(int x)const{Litres sum=0;for(const auto &c:columns_)if(c.x>=x)sum+=c.litres;return sum;}
    Tick tick() {
        Tick out;
        for(int i=0;i<substeps;++i){const auto r=substep();out.moved+=r.moved;out.pressure_blocked+=r.pressure_blocked;}
        if(mass()!=initial_)throw std::logic_error("R2 mass ledger");
        return out;
    }
    std::size_t bytes()const{return columns_.capacity()*sizeof(Column)+pipes_.capacity()*sizeof(Pipe);}
};
}
