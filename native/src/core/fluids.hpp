#pragma once
#include "world_core.hpp"
#include <deque>
#include <functional>
#include <numeric>

namespace sandbox::fluid {
using Cell=core::Region;
inline constexpr int capacity=1000; // integer litres in a 1m^3 cell
inline constexpr std::size_t cell_limit=65536;
inline constexpr std::array<Cell,6> neighbors{{{0,-1,0},{-1,0,0},{0,0,-1},{0,0,1},{1,0,0},{0,1,0}}};
inline Cell plus(Cell a,Cell b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline bool valid(Cell p) {
    return std::abs(std::int64_t(p.x))<=1000000 && std::abs(std::int64_t(p.y))<=1000000 && std::abs(std::int64_t(p.z))<=1000000;
}
enum class Passage { solid, open, unavailable };
struct Liquid {
    int rate{}; // litres per source cell per tick
    double density{};
    int substeps=1;
};
struct Amount {
    int type{}, litres{};
    auto operator<=>(const Amount &) const=default;
};
struct TickReport {
    std::size_t processed{},blocked{},changed{},backlog{},substeps{};
    std::uint64_t transferred{};
};
class Solver {
    std::vector<Liquid> types_;
    std::map<Cell,Amount> wet_;
    std::set<Cell> dirty_;
    std::set<std::pair<int,Cell>> queued_;
    std::vector<std::deque<Cell>> frontiers_;
    std::map<Cell,Amount> falls_, next_falls_;
    std::uint64_t initial_{},injected_{},drained_{},volume_{};
    void wake(Cell p) {
        auto a=at(p);
        if(a.litres && queued_.insert({a.type,p}).second)frontiers_[static_cast<std::size_t>(a.type)].push_back(p);
    }
    void wake_halo(Cell p) {
        wake(p);
        for(auto d:neighbors) wake(plus(p,d));
    }
public:
    explicit Solver(std::vector<Liquid> types):types_(std::move(types)),frontiers_(types_.size()) {
        if(types_.empty()||types_.size()>32) throw std::invalid_argument("fluid type limit");
        for(auto t:types_) if(t.rate<1||t.rate>capacity||!std::isfinite(t.density)||t.density<=0||t.substeps<1||t.substeps>5)
            throw std::invalid_argument("invalid fluid properties");
    }
    const auto &cells() const{return wet_;}
    const auto &types() const{return types_;}
    std::uint64_t volume() const{return volume_;}
    std::uint64_t initial() const{return initial_;}
    std::uint64_t injected() const{return injected_;}
    std::uint64_t drained() const{return drained_;}
    std::size_t backlog() const {std::size_t n=0;for(const auto &q:frontiers_)n+=q.size();return n;}
    Amount falling_at(Cell p) const {auto it=falls_.find(p);return it==falls_.end()?Amount{}:it->second;}
    Amount at(Cell p) const {
        auto it=wet_.find(p);return it==wet_.end()?Amount{}:it->second;
    }
    // Initial reservoir or explicit source only; never infer water from altitude.
    template<class Probe> bool add(Cell p,int type,int amount,Probe probe,bool initial=false) {
        if(!valid(p)||type<0||static_cast<std::size_t>(type)>=types_.size()||amount<1||amount>capacity||probe(p)!=Passage::open) return false;
        auto a=at(p);
        if((a.litres && a.type!=type)||a.litres+amount>capacity||(!a.litres&&wet_.size()>=cell_limit))return false;
        wet_[p]={type,a.litres+amount};volume_+=static_cast<std::uint64_t>(amount);
        (initial?initial_:injected_)+=static_cast<std::uint64_t>(amount);
        dirty_.insert(p);wake_halo(p);return true;
    }
    int drain(Cell p,int amount) {
        auto it=wet_.find(p);if(it==wet_.end()||amount<=0)return 0;
        const int n=std::min(amount,it->second.litres);
        it->second.litres-=n;if(!it->second.litres)wet_.erase(it);
        drained_+=static_cast<std::uint64_t>(n);volume_-=static_cast<std::uint64_t>(n);
        dirty_.insert(p);wake_halo(p);return n;
    }
    void invalidate(Cell lo,Cell hi) {
        if(!valid(lo)||!valid(hi)||hi.x<lo.x||hi.y<lo.y||hi.z<lo.z||
            hi.x-lo.x>24||hi.y-lo.y>24||hi.z-lo.z>24)throw std::invalid_argument("fluid edit bounds");
        for(int x=lo.x;x<=hi.x;++x)for(int y=lo.y;y<=hi.y;++y)for(int z=lo.z;z<=hi.z;++z)wake_halo({x,y,z});
    }
    // Two phases. Read old volumes, reserve both source and destination
    // budgets, then apply the complete delta. Incoming liquid cannot move
    // until a later tick. No cross-type mixing or volume deletion.
private:
    template<class Probe> TickReport step(Probe probe,int type,std::size_t budget) {
        TickReport report;
        std::map<Cell,int> outgoing,incoming,incoming_type;
        std::map<Cell,Passage> checked;
        std::set<Cell> retry,changed;
        auto passage=[&](Cell p) {
            if(!valid(p))return Passage::unavailable;
            auto it=checked.find(p);if(it!=checked.end())return it->second;
            auto s=probe(p);checked.emplace(p,s);return s;
        };
        auto &frontier=frontiers_[static_cast<std::size_t>(type)];
        const auto count=std::min(budget,frontier.size());
        std::size_t new_cells=0;
        for(std::size_t i=0;i<count;++i) {
            const auto p=frontier.front();frontier.pop_front();queued_.erase({type,p});
            auto a=at(p);if(!a.litres||a.type!=type)continue;
            ++report.processed;
            if(passage(p)!=Passage::open){retry.insert(p);++report.blocked;continue;}
            int remaining=std::min(a.litres,types_[static_cast<std::size_t>(a.type)].rate);
            for(std::size_t n=0;n<5 && remaining>0;++n) {
                const auto q=plus(p,neighbors[n]);const auto pass=passage(q);
                if(pass==Passage::unavailable){retry.insert(p);++report.blocked;continue;}
                if(pass!=Passage::open)continue;
                const auto b=at(q);
                const auto it=incoming.find(q);
                const int reserved=it==incoming.end()?0:it->second;
                if((b.litres&&b.type!=a.type)||(reserved&&incoming_type.at(q)!=a.type))continue;
                if(!b.litres&&!reserved&&wet_.size()+new_cells>=cell_limit){retry.insert(p);++report.blocked;continue;}
                const int free=capacity-b.litres-reserved;
                const int desired=n==0?remaining:std::max(0,(a.litres-outgoing[p]-b.litres-reserved)/2);
                const int transfer=std::min({remaining,free,desired});
                if(transfer<=0)continue;
                if(!b.litres&&!reserved)++new_cells;
                outgoing[p]+=transfer;incoming[q]+=transfer;incoming_type[q]=a.type;
                remaining-=transfer;report.transferred+=static_cast<std::uint64_t>(transfer);
                if(n==0) {
                    auto &fall=next_falls_[p];fall.type=a.type;
                    fall.litres=std::min(capacity,fall.litres+transfer);
                }
                changed.insert(p);changed.insert(q);
            }
        }
        for(auto p:changed) {
            auto a=at(p);
            if(!a.litres)a.type=incoming_type.at(p);
            a.litres+=incoming[p]-outgoing[p];
            if(a.litres<0||a.litres>capacity)throw std::logic_error("fluid reservation invariant");
            if(a.litres)wet_[p]=a;else wet_.erase(p);
            dirty_.insert(p);
        }
        for(auto p:changed)wake_halo(p);
        for(auto p:retry)wake(p);
        report.changed=changed.size();report.backlog=backlog();
        return report;
    }
public:
    // One macro tick remains 100ms. Independent FIFO queues make the
    // per-liquid cadence explicit and keep lava at its original cadence.
    // Cache the unchanged terrain across substeps, never across edits.
    template<class Probe> TickReport tick(Probe probe,std::size_t budget=256) {
        TickReport total;
        std::map<Cell,Passage> checked;
        auto cached=[&](Cell p) {
            auto it=checked.find(p);if(it!=checked.end())return it->second;
            auto v=probe(p);checked.emplace(p,v);return v;
        };
        next_falls_.clear();
        // Keep the full former budget for each of the two standard types.
        // For mod-heavy worlds cap total work per round at roughly 2*budget.
        const auto divisor=(types_.size()+1)/2;
        const auto share=budget/divisor;
        for(int round=0;round<5;++round) {
            bool any=false;
            for(std::size_t type=0;type<types_.size();++type) {
                if(round>=types_[type].substeps)continue;
                any=true;
                const auto r=step(cached,static_cast<int>(type),share);
                total.processed+=r.processed;total.blocked+=r.blocked;
                total.changed+=r.changed;total.transferred+=r.transferred;
            }
            if(any)++total.substeps;
        }
        // Transient visual-only downward transfer envelope, no save state.
        // Retain a short fading trail so a waterfall is not one-frame noise.
        for(auto [p,a]:falls_) {
            dirty_.insert(p);
            if(!next_falls_.contains(p)&&a.litres>80)next_falls_[p]={a.type,a.litres/2};
        }
        for(auto [p,a]:next_falls_){(void)a;dirty_.insert(p);}
        falls_.swap(next_falls_);
        total.backlog=backlog();
        return total;
    }
    // Finite window query; never scan the entire dry world.
    std::vector<std::pair<Cell,Amount>> query(Cell lo,Cell hi,std::size_t limit=4096) const {
        if(!valid(lo)||!valid(hi)||hi.x<lo.x||hi.y<lo.y||hi.z<lo.z||hi.x-lo.x>128||hi.y-lo.y>128||hi.z-lo.z>128)
            throw std::invalid_argument("fluid query bounds");
        std::vector<std::pair<Cell,Amount>> result;
        for(auto it=wet_.lower_bound({lo.x,-1000000,-1000000});it!=wet_.end()&&it->first.x<=hi.x;++it) {
            auto p=it->first;
            if(p.y>=lo.y&&p.y<=hi.y&&p.z>=lo.z&&p.z<=hi.z) {
                if(result.size()>=limit)throw std::length_error("fluid query limit");
                result.push_back(*it);
            }
        }
        return result;
    }
    std::vector<Cell> take_dirty(std::size_t budget) {
        std::vector<Cell> out;
        while(budget--&&!dirty_.empty()){out.push_back(*dirty_.begin());dirty_.erase(dirty_.begin());}
        return out;
    }
    // Restore all wet cells and wake once on reopen. Stable cells then sleep.
    void restore(const std::map<Cell,Amount>& cells,std::uint64_t initial,std::uint64_t injected,std::uint64_t drained) {
        if(!wet_.empty()||volume_||cells.size()>cell_limit||initial>std::numeric_limits<std::uint64_t>::max()-injected||drained>initial+injected)
            throw std::invalid_argument("fluid restore counters");
        std::uint64_t sum=0;
        for(auto [p,a]:cells) {
            if(!valid(p)||a.type<0||static_cast<std::size_t>(a.type)>=types_.size()||a.litres<1||a.litres>capacity)
                throw std::invalid_argument("fluid restore cell");
            sum+=static_cast<std::uint64_t>(a.litres);
        }
        if(sum!=initial+injected-drained)throw std::invalid_argument("fluid mass mismatch");
        wet_=cells;volume_=sum;initial_=initial;injected_=injected;drained_=drained;
        for(auto [p,a]:wet_){(void)a;wake(p);dirty_.insert(p);}
    }
};
}
