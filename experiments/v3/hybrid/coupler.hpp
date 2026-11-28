#pragma once
#include "virtual_pipes.hpp"
#include "ocean_connectivity.hpp"
#include "core/hydraulic_domain.hpp"
#include <nlohmann/json.hpp>
namespace sandbox::hydraulic::experiment {
enum class Phase { aggregate,activating,local_active,settling,blocked };
struct Owner {
    core::Region tile;
    std::size_t index{};
    int kind{}; // 0 aggregate compartment, 1 local interval, 2 ocean boundary
    auto operator<=>(const Owner&)const=default;
};
struct Interface {Owner a,b;double sill{},soffit{},width{};};
struct Ocean {
    std::string id;core::Region tile;core::Vec3 anchor;std::size_t type{};
    double head{},sill{},width{};
};
struct CoupledTile {
    std::shared_ptr<const tp::Result> geometry;
    std::map<Id,tp::Content> aggregate;
    std::optional<Local> local;
    std::vector<Id> owners;
    Phase phase=Phase::aggregate;
    std::uint64_t epoch{};
    unsigned stable_ticks{};
    bool resident=true;
    std::map<std::string,OceanReach> ocean_reach;
};
// Restricted R3 proof: regional aggregate curves + bounded local windows.
// No engine dependency, no global per-column simulation, no double owner.
// Cross-interface exchanges are staged against pre-exchange states.
class Coupler {
    std::vector<Liquid> types_;
    std::map<core::Region,CoupledTile> tiles_;
    std::vector<Ocean> oceans_;
    std::vector<Interface> interfaces_;
    std::size_t active_limit_,tile_limit_;
    Litres initial_{},injected_{},drained_{},cold_mass_{};
    std::uint64_t cold_count_{};
    std::uint64_t epoch_{};
    // Ephemeral render invalidations; never persisted or used by physics.
    std::set<core::Region> surface_changes_;
    struct Value {std::size_t type=no_liquid;Litres mass{},capacity{};double head{};bool ocean=false;};
    static const tp::Compartment& compartment(const CoupledTile& t,Id id) {
        const auto it=std::find_if(t.geometry->compartments.begin(),t.geometry->compartments.end(),[&](const auto &v){return v.id==id;});
        if(it==t.geometry->compartments.end())throw std::invalid_argument("R3 compartment");
        return *it;
    }
    static std::vector<Id> mapping(const tp::Result& g,const Local& local) {
        std::vector<Id> out;out.reserve(local.columns().size());
        for(const auto &c:local.columns()) {
            const auto &runs=g.column_runs.at(static_cast<std::size_t>(c.z*g.nx+c.x));
            const auto it=std::find_if(runs.begin(),runs.end(),[&](const auto &s){
                return tp::span_floor_mm(g,s)==c.target_floor_mm&&(g.origin.y+s.top*g.step)*1000==c.ceiling_mm;
            });
            if(it==runs.end())throw std::logic_error("R3 interval ownership");
            out.push_back(it->compartment);
        }
        return out;
    }
    static Litres interval_at(const Column& c,double h) {
        return std::clamp(static_cast<Litres>(std::floor((h-c.floor())*1000.0*c.area_m2+1e-7)),Litres(0),c.capacity());
    }
    Owner at_boundary(const CoupledTile& t,const tp::Boundary& b)const {
        if(!t.local)return {t.geometry->origin,b.compartment,0};
        const int x=b.face==0?0:b.face==1?t.geometry->nx-1:b.along;
        const int z=b.face==2?0:b.face==3?t.geometry->nz-1:b.along;
        const auto &cells=t.local->columns();
        for(auto i:t.local->column_indices(x,z))if(
            cells[i].target_floor_mm==b.bottom_mm&&cells[i].ceiling_mm==b.top_mm)return {t.geometry->origin,i,1};
        throw std::logic_error("R3 boundary interval");
    }
    Owner at_anchor(const CoupledTile& t,core::Vec3 p)const {
        const auto *s=tp::span_at(*t.geometry,p);
        if(!s)throw std::invalid_argument("R3 ocean anchor");
        if(!t.local)return {t.geometry->origin,s->compartment,0};
        const auto &cells=t.local->columns();
        for(auto i:t.local->column_indices(s->x,s->z))if(
            cells[i].target_floor_mm==tp::span_floor_mm(*t.geometry,*s)&&cells[i].ceiling_mm==(t.geometry->origin.y+s->top)*1000)
            return {t.geometry->origin,i,1};
        throw std::logic_error("R3 ocean interval");
    }
    void rebuild() {
        interfaces_.clear();
        std::map<std::tuple<Owner,Owner,double,double>,double> aggregated;
        for(const auto &[k,t]:tiles_)if(t.resident) {
            if(!t.local)for(const auto &o:t.geometry->openings) {
                const double height=(o.soffit_mm-o.sill_mm)*0.001;
                if(height>0)interfaces_.push_back({{k,o.a,0},{k,o.b,0},o.sill_mm*0.001,o.soffit_mm*0.001,o.area_m2/height});
            }
            for(int face:{1,3}) {
                auto neighbor=k;
                if(face==1)neighbor.x+=t.geometry->nx;else neighbor.z+=t.geometry->nz;
                const auto it=tiles_.find(neighbor);if(it==tiles_.end()||!it->second.resident)continue;
                const auto &other=it->second;
                for(const auto &u:t.geometry->boundaries)if(u.face==face)
                    for(const auto &v:other.geometry->boundaries)if(v.face==face-1&&v.along==u.along) {
                        const int lo=u.exposed&&v.exposed?std::max(u.bottom_mm,v.bottom_mm):std::max(u.coarse_bottom_mm,v.coarse_bottom_mm);
                        const int hi=std::min(u.top_mm,v.top_mm);
                        if(lo<hi) {
                            const auto a=at_boundary(t,u),b=at_boundary(other,v);
                            if(a.kind==0&&b.kind==0)aggregated[{a,b,lo*0.001,hi*0.001}]+=1;
                            else interfaces_.push_back({a,b,lo*0.001,hi*0.001,1});
                        }
                    }
            }
        }
        for(const auto &[key,width]:aggregated){const auto &[a,b,lo,hi]=key;interfaces_.push_back({a,b,lo,hi,width});}
        for(std::size_t i=0;i<oceans_.size();++i) {
            const auto &o=oceans_[i];const auto it=tiles_.find(o.tile);
            if(it==tiles_.end()||!it->second.resident)continue;
            if(!tp::span_at(*it->second.geometry,o.anchor))continue;
            interfaces_.push_back({{{},i,2},at_anchor(it->second,o.anchor),o.sill,o.sill+64,o.width});
        }
    }
    Value value(Owner o)const {
        if(o.kind==2){const auto &v=oceans_.at(o.index);return {v.type,0,volume_limit,v.head,true};}
        const auto &t=tiles_.at(o.tile);
        if(o.kind==1){
            const auto &c=t.local->columns().at(o.index);return {c.type,c.litres,c.capacity(),c.head(),false};
        }
        const auto id=static_cast<Id>(o.index);const auto &curve=compartment(t,id).curve;
        const auto it=t.aggregate.find(id);const auto mass=it==t.aggregate.end()?0:it->second.litres;
        return {it==t.aggregate.end()?no_liquid:it->second.type,mass,curve.capacity(),curve.level(mass),false};
    }
    Litres above(Owner o,double sill)const {
        const auto v=value(o);if(v.ocean)return volume_limit;
        const auto &t=tiles_.at(o.tile);
        if(o.kind==1)return v.mass-interval_at(t.local->columns().at(o.index),sill);
        return v.mass-compartment(t,static_cast<Id>(o.index)).curve.at_level(sill);
    }
    double level_after(Owner o,Litres delta)const {
        const auto v=value(o);if(v.ocean)return v.head;
        const auto &t=tiles_.at(o.tile);
        if(o.kind==1){const auto &c=t.local->columns().at(o.index);return c.floor()+double(c.litres+delta)/(1000.0*c.area_m2);}
        return compartment(t,static_cast<Id>(o.index)).curve.level(v.mass+delta);
    }
    void remove(Owner o,Litres amount) {
        if(o.kind==2){injected_+=amount;return;}
        auto &t=tiles_.at(o.tile);
        if(o.kind==1){if(!t.local->withdraw(o.index,amount))throw std::logic_error("R3 local withdrawal");return;}
        auto it=t.aggregate.find(static_cast<Id>(o.index));
        if(it==t.aggregate.end()||it->second.litres<amount)throw std::logic_error("R3 aggregate withdrawal");
        it->second.litres-=amount;if(!it->second.litres)t.aggregate.erase(it);
    }
    void add(Owner o,std::size_t type,Litres amount) {
        if(o.kind==2){drained_+=amount;return;}
        auto &t=tiles_.at(o.tile);
        if(o.kind==1){if(!t.local->receive(o.index,type,amount))throw std::logic_error("R3 local deposit");return;}
        auto &v=t.aggregate[static_cast<Id>(o.index)];
        if(v.litres&&v.type!=type)throw std::logic_error("R3 liquid mix");
        v.type=type;v.litres+=amount;
        if(v.litres>compartment(t,static_cast<Id>(o.index)).curve.capacity())throw std::logic_error("R3 aggregate capacity");
    }
    // A compartment may contain disconnected pools of distinct liquids
    // in local mode. Such a state cannot be represented by one aggregate.
    std::optional<std::map<Id,tp::Content>> collect(const CoupledTile& t)const {
        if(!t.local)return t.aggregate;
        std::map<Id,tp::Content> out;
        for(std::size_t i=0;i<t.owners.size();++i) {
            const auto &c=t.local->columns()[i];if(!c.litres)continue;
            auto &v=out[t.owners[i]];
            if(v.litres&&v.type!=c.type)return {};
            v.type=c.type;v.litres+=c.litres;
        }
        return out;
    }
    // Use the same deterministic integer projection for promotion and
    // exact suspension checks. No new Local/pipe graph needed to check.
    static std::optional<std::vector<Litres>> project(const CoupledTile& t,
            const Local& local,const std::vector<Id>& owners,const std::map<Id,tp::Content>& contents) {
        std::vector<Litres> amounts(owners.size());
        for(const auto &[id,v]:contents) {
            const auto head=compartment(t,id).curve.level(v.litres);
            Litres left=v.litres;
            for(std::size_t i=0;i<owners.size();++i)if(owners[i]==id) {
                const auto n=std::min(left,interval_at(local.columns()[i],head));
                amounts[i]=n;left-=n;
            }
            for(std::size_t i=0;i<owners.size()&&left;++i)if(owners[i]==id) {
                const auto n=std::min(left,local.columns()[i].capacity()-amounts[i]);
                amounts[i]+=n;left-=n;
            }
            if(left)return {};
        }
        return amounts;
    }
    bool settled(const CoupledTile& t)const {
        const auto contents=collect(t);if(!contents)return false;
        for(const auto &c:t.local->columns())if(c.falling())return false;
        const auto expected=project(t,*t.local,t.owners,*contents);if(!expected)return false;
        for(std::size_t i=0;i<t.owners.size();++i) {
            const auto &c=t.local->columns()[i];
            // Never turn a dry interval into a wet one (or the reverse)
            // merely by changing representation.
            if(((*expected)[i]>0)!=(c.litres>0)||std::abs((*expected)[i]-c.litres)>20)return false;
        }
        for(const auto &p:t.local->pipes())if(std::abs(p.flux)>0.005)return false;
        return true;
    }
    void aggregate_owner(core::Region k,CoupledTile& t,std::map<Id,tp::Content> contents) {
        t.local.reset();std::vector<Id>().swap(t.owners);t.aggregate=std::move(contents);
        t.phase=Phase::aggregate;t.epoch=++epoch_;t.stable_ticks=0;surface_changes_.insert(k);
    }
    void verify()const {
        if(mass()!=initial_+injected_-drained_)throw std::logic_error("R3 global ledger");
        for(const auto &[key,t]:tiles_) {
            (void)key;
            if(t.local&&!t.aggregate.empty())throw std::logic_error("R3 double ownership");
            if(t.local&&t.local->columns().size()!=t.owners.size())throw std::logic_error("R3 owner map");
        }
    }
public:
    Coupler(std::vector<Liquid> types,std::size_t active_limit=2,std::size_t tile_limit=8):
        types_(std::move(types)),active_limit_(active_limit),tile_limit_(tile_limit) {
        if(types_.empty()||!active_limit_||active_limit_>tile_limit_||tile_limit_>128)throw std::invalid_argument("R3 limits");
    }
    const auto& tiles()const{return tiles_;}
    const auto& oceans()const{return oceans_;}
    std::size_t active()const{std::size_t n=0;for(const auto &[k,t]:tiles_){(void)k;if(t.local)++n;}return n;}
    Litres mass()const{
        Litres sum=cold_mass_;for(const auto &[k,t]:tiles_){(void)k;if(t.local)sum+=t.local->mass();else for(const auto &[id,v]:t.aggregate){(void)id;sum+=v.litres;}}return sum;
    }
    Litres tile_mass(core::Region k)const {
        const auto &t=tiles_.at(k);if(t.local)return t.local->mass();
        Litres sum=0;for(const auto &[id,v]:t.aggregate){(void)id;sum+=v.litres;}return sum;
    }
    Litres cold_mass()const{return cold_mass_;}
    std::uint64_t cold_count()const{return cold_count_;}
    Litres initial()const{return initial_;}
    Litres injected()const{return injected_;}
    std::size_t active_limit()const{return active_limit_;}
    std::size_t tile_limit()const{return tile_limit_;}
    const auto& interfaces()const{return interfaces_;}
    std::set<core::Region> take_surface_changes(){std::set<core::Region> out;out.swap(surface_changes_);return out;}
    // Explicit transfer from bootstrap Domain. Caller discards old owner.
    static Coupler adopt(const Domain& domain,std::size_t active_limit=8,std::size_t tile_limit=96) {
        Coupler out(domain.graph().types(),active_limit,tile_limit);
        if(domain.tiles().size()>tile_limit)throw std::invalid_argument("R3 bootstrap capacity");
        for(const auto &[k,t]:domain.tiles()) {
            CoupledTile owner;owner.geometry=t.geometry;owner.resident=t.available;
            for(const auto &[local,id]:t.ids) {
                const auto &v=domain.graph().volumes().at(id);
                if(v.litres)owner.aggregate.emplace(local,tp::Content{v.type,v.litres});
            }
            out.tiles_.emplace(k,std::move(owner));out.surface_changes_.insert(k);
        }
        for(const auto &[id,o]:domain.oceans()) {
            const auto &v=domain.graph().volumes().at(o.ocean);
            if(!out.ocean({id,o.tile,o.anchor,v.type,v.ocean_level,o.sill,o.area}))throw std::logic_error("R3 bootstrap ocean");
        }
        out.initial_=domain.graph().initial();out.injected_=domain.graph().injected();out.drained_=domain.graph().drained();
        out.rebuild();out.verify();return out;
    }
    // Never collapse a front by aggregating a still-active window.
    // Activate the receiving side of significant boundary discharge.
    std::vector<core::Region> flow_candidates(double gradient=0.2)const {
        std::set<core::Region> keys;
        for(const auto &p:interfaces_) {
            auto a=value(p.a),b=value(p.b);Owner from=p.a,to=p.b;
            if(a.head<b.head){std::swap(a,b);std::swap(from,to);}
            if(to.kind!=0||from.tile==to.tile||(!a.ocean&&!a.mass)||a.head<=p.sill||
                a.head-std::max(b.head,p.sill)<gradient||(b.mass&&a.type!=b.type))continue;
            keys.insert(to.tile);
        }
        return {keys.begin(),keys.end()};
    }
    // A local front must enter a receiving aggregate tile via the
    // actual boundary intervals, not instant compartment equalization.
    // Rank resident recipients by total prospective local discharge.
    std::vector<core::Region> local_front_candidates(double gradient=0.05)const {
        std::map<core::Region,double> scores;
        for(const auto &p:interfaces_) {
            Owner from=p.a,to=p.b;auto a=value(from),b=value(to);
            if(a.head<b.head){std::swap(a,b);std::swap(from,to);}
            if(from.kind!=1||to.kind!=0||from.tile==to.tile||!a.mass||
                (b.type!=no_liquid&&b.type!=a.type)||a.mass==a.capacity||b.mass==b.capacity)continue;
            const double dh=a.head-std::max(b.head,p.sill);
            const double area=std::max(0.0,std::min(a.head,p.soffit)-p.sill)*p.width;
            if(dh<gradient||area<=0)continue;
            scores[to.tile]+=area*std::sqrt(dh)/types_.at(a.type).viscosity;
        }
        std::vector<core::Region> result;
        for(const auto &[k,score]:scores){(void)score;result.push_back(k);}
        std::sort(result.begin(),result.end(),[&](auto a,auto b){
            return scores.at(a)!=scores.at(b)?scores.at(a)>scores.at(b):a<b;
        });
        return result;
    }
    // Diagnostic occupancy of a whole XZ column, including every Y
    // interval. -1 denotes uncertified/nonresident geometry.
    Litres column_mass(core::Region k,int x,int z)const {
        auto it=tiles_.find(k);if(it==tiles_.end()||!it->second.resident)return -1;
        const auto &t=it->second;const auto &g=*t.geometry;
        if(x<0||x>=g.nx||z<0||z>=g.nz)return -1;
        Litres sum=0;
        if(t.local) {
            for(auto i:t.local->column_indices(x,z))sum+=t.local->columns()[i].litres;
        }else for(const auto &s:g.column_runs.at(static_cast<std::size_t>(z*g.nx+x))) {
            auto v=t.aggregate.find(s.compartment);if(v==t.aggregate.end()||!v->second.litres)continue;
            const auto h=compartment(t,s.compartment).curve.level(v->second.litres);
            const auto cap=(k.y+s.top)*1000-tp::span_floor_mm(g,s);
            sum+=std::clamp(static_cast<Litres>(std::floor(h*1000.0-tp::span_floor_mm(g,s)+1e-7)),Litres(0),Litres(cap));
        }
        return sum;
    }
    std::optional<std::tuple<std::size_t,Litres,double,double>> sample(core::Vec3 p,core::Region k)const {
        const auto it=tiles_.find(k);if(it==tiles_.end()||!it->second.resident)return {};
        const auto &t=it->second;const auto *s=tp::span_at(*t.geometry,p);if(!s)return {};
        const auto floor=tp::span_floor_mm(*t.geometry,*s)*0.001;
        if(t.local) {
            for(auto i:t.local->column_indices(s->x,s->z)) {
                const auto &cell=t.local->columns()[i];
                if(cell.target_floor_mm==tp::span_floor_mm(*t.geometry,*s)&&cell.ceiling_mm==(k.y+s->top)*1000&&cell.litres&&p.y>=cell.floor()&&p.y<cell.head())
                    return std::tuple{cell.type,cell.litres,cell.head(),floor};
            }
            return {};
        }
        const auto v=t.aggregate.find(s->compartment);if(v==t.aggregate.end()||!v->second.litres)return {};
        const double h=compartment(t,s->compartment).curve.level(v->second.litres);
        if(p.y>=h)return {};
        return std::tuple{v->second.type,v->second.litres,h,floor};
    }
    Litres drained()const{return drained_;}
    bool publish(std::shared_ptr<const tp::Result> geometry) {
        if(!geometry||geometry->step!=1||tiles_.contains(geometry->origin)||tiles_.size()>=tile_limit_)return false;
        const auto key=geometry->origin;
        if(!tiles_.empty()&&(geometry->nx!=tiles_.begin()->second.geometry->nx||geometry->nz!=tiles_.begin()->second.geometry->nz||
            key.y!=tiles_.begin()->first.y))return false;
        CoupledTile t;t.geometry=std::move(geometry);tiles_.emplace(key,std::move(t));surface_changes_.insert(key);rebuild();return true;
    }
    bool seed(core::Region key,Id id,std::size_t type,Litres amount) {
        auto &t=tiles_.at(key);
        if(t.local||t.aggregate.contains(id)||type>=types_.size()||amount<=0||amount>compartment(t,id).curve.capacity()||amount>ledger_limit-initial_)return false;
        t.aggregate.emplace(id,tp::Content{type,amount});initial_+=amount;surface_changes_.insert(key);verify();return true;
    }
    // Atomic finite-source initialization on certified dry exposed
    // compartments. Discovery uses geometric openings even when the
    // tiles are not physics-resident; no exchange is enabled by seeding.
    // Prepare a newly initialized finite owner directly in the cold ledger.
    // The caller must durably write the returned record before publishing
    // this staged Coupler. Never call on a region with an existing owner.
    std::optional<std::pair<nlohmann::json,Litres>> stage_cold_seed(
            std::shared_ptr<const tp::Result> g,std::size_t type,const std::map<Id,Litres>& contents) {
        if(!g||tiles_.contains(g->origin)||contents.empty()||type>=types_.size()||
            cold_count_==std::numeric_limits<std::uint64_t>::max())return std::nullopt;
        Coupler isolated(types_,1,1);
        if(!isolated.publish(g))return std::nullopt;
        for(const auto &[id,amount]:contents)if(!isolated.seed(g->origin,id,type,amount))return std::nullopt;
        const auto total=isolated.mass();
        if(total>ledger_limit-initial_||total>2*ledger_limit-cold_mass_)return std::nullopt;
        isolated.set_resident(g->origin,false);
        auto row=isolated.encode_tile(g->origin);
        initial_+=total;cold_mass_+=total;++cold_count_;verify();
        return std::pair{std::move(row),total};
    }
    enum class BasinResult { seeded, waiting, frontier, conflict };
    BasinResult seed_surface_basin(core::Region root,Id id,std::size_t type,double level,int ceiling,
            const std::set<core::Region>& window,std::set<core::Region>& frontier) {
        frontier.clear();
        if(!window.contains(root)||type>=types_.size()||!std::isfinite(level)||window.size()>64)return BasinResult::conflict;
        using Node=std::pair<core::Region,Id>;
        std::map<Node,Litres> eligible;
        std::map<Node,std::vector<Node>> links;
        for(auto k:window){
            const auto it=tiles_.find(k);if(it==tiles_.end())return BasinResult::waiting;
            for(const auto &c:it->second.geometry->compartments){
                const auto &g=*it->second.geometry;
                const bool exposed=std::any_of(c.spans.begin(),c.spans.end(),[&](const auto &s){return g.origin.y+s.top*g.step==ceiling;});
                const auto amount=c.curve.at_level(level);
                if(exposed&&amount>0)eligible.emplace(Node{k,c.id},amount);
            }
        }
        const Node first{root,id};if(!eligible.contains(first))return BasinResult::conflict;
        auto link=[&](Node a,Node b,const tp::Opening& o){
            if(o.sill_mm>=level*1000||o.soffit_mm!=ceiling*1000||!eligible.contains(a)||!eligible.contains(b))return;
            links[a].push_back(b);links[b].push_back(a);
        };
        for(auto k:window){
            const auto &g=*tiles_.at(k).geometry;
            for(const auto &o:g.openings)link({k,o.a},{k,o.b},o);
            for(int face:{1,3}){
                const core::Region q{k.x+(face==1?g.nx:0),k.y,k.z+(face==3?g.nz:0)};
                if(!window.contains(q))continue;
                for(const auto &o:tp::connect_faces(g,*tiles_.at(q).geometry,face))link({k,o.a},{q,o.b},o);
            }
        }
        std::set<Node> reached{first};std::deque<Node> queue{first};
        while(!queue.empty()){
            const auto n=queue.front();queue.pop_front();
            const auto &tile=tiles_.at(n.first);
            // Never duplicate a previously discovered body or overwrite
            // a local front. Wait for the owner to become safely dry.
            if(tile.local||tile.aggregate.contains(n.second))return BasinResult::conflict;
            for(const auto &q:links[n])if(reached.insert(q).second)queue.push_back(q);
        }
        for(const auto &n:reached){
            const auto &g=*tiles_.at(n.first).geometry;
            for(const auto &edge:g.boundaries){
                if(edge.compartment!=n.second||edge.top_mm!=ceiling*1000||edge.bottom_mm>=level*1000)continue;
                const core::Region q{n.first.x+(edge.face==0?-g.nx:edge.face==1?g.nx:0),n.first.y,
                    n.first.z+(edge.face==2?-g.nz:edge.face==3?g.nz:0)};
                if(!window.contains(q))frontier.insert(q);
            }
        }
        if(!frontier.empty())return BasinResult::frontier;
        Litres total=0;
        for(const auto &n:reached){const auto amount=eligible.at(n);if(amount>ledger_limit-initial_-total)return BasinResult::conflict;total+=amount;}
        // All owners and capacity validated before any mutation.
        for(const auto &n:reached){
            tiles_.at(n.first).aggregate.emplace(n.second,tp::Content{type,eligible.at(n)});
            surface_changes_.insert(n.first);
        }
        initial_+=total;verify();return BasinResult::seeded;
    }
    // Materialize only newly certified pristine ocean compartments, with
    // an explicit source ledger. Existing wet owners and local fronts are
    // never reset to the head; they continue through the physical solver.
    // The caller owns the world revision/provenance certificate.
    bool remember_ocean(const OceanReach& proof,std::uint64_t world_revision) {
        const auto it=tiles_.find(proof.key);
        if(it==tiles_.end()||proof.compartments.empty()||!proof.matches(*it->second.geometry,world_revision)||
            std::none_of(oceans_.begin(),oceans_.end(),[&](const auto &o){return o.id==proof.source&&o.head==proof.head;}))return false;
        it->second.ocean_reach.insert_or_assign(proof.source,proof);return true;
    }
    bool acquire_ocean(const OceanReach& proof,std::uint64_t world_revision,bool pristine) {
        if(!pristine||proof.world_revision!=world_revision||proof.compartments.empty())return false;
        const auto source=std::find_if(oceans_.begin(),oceans_.end(),[&](const auto &o){return o.id==proof.source&&o.head==proof.head;});
        const auto it=tiles_.find(proof.key);
        if(source==oceans_.end()||it==tiles_.end()||it->second.local||
            it->second.geometry->revision!=proof.geometry_revision)return false;
        auto &tile=it->second;
        std::map<Id,tp::Content> additions;
        Litres total=0;
        for(auto id:proof.compartments){
            const auto &comp=compartment(tile,id);
            if(comp.spans.empty()||!std::all_of(comp.spans.begin(),comp.spans.end(),[&](const auto &s){
                return tile.geometry->origin.y+s.top*tile.geometry->step==proof.ceiling;
            }))return false;
            if(const auto old=tile.aggregate.find(id);old!=tile.aggregate.end()){
                if(old->second.type!=source->type)return false;
                continue;
            }
            const auto amount=comp.curve.at_level(source->head);
            if(amount<=0||amount>ledger_limit-injected_-total)return false;
            total+=amount;additions.emplace(id,tp::Content{source->type,amount});
        }
        for(const auto &[id,content]:additions)tile.aggregate.emplace(id,content);
        injected_+=total;
        if(total)surface_changes_.insert(proof.key);
        if(!remember_ocean(proof,world_revision))throw std::logic_error("ocean proof lost");
        verify();return true;
    }
    bool activate(core::Region key) {
        auto &t=tiles_.at(key);if(!t.resident||t.local)return false;
        if(active()>=active_limit_){t.phase=Phase::blocked;return false;}
        Local staged(*t.geometry,types_);
        auto owners=mapping(*t.geometry,staged);
        const auto amounts=project(t,staged,owners,t.aggregate);
        if(!amounts){t.phase=Phase::blocked;return false;}
        for(std::size_t i=0;i<owners.size();++i)if((*amounts)[i])
            staged.seed(i,t.aggregate.at(owners[i]).type,(*amounts)[i]);
        if(staged.mass()!=tile_mass(key))throw std::logic_error("R3 activation mass");
        t.phase=Phase::activating;
        t.local.emplace(std::move(staged));t.owners=std::move(owners);t.aggregate.clear();
        t.phase=Phase::local_active;t.epoch=++epoch_;t.stable_ticks=0;surface_changes_.insert(key);rebuild();verify();return true;
    }
    bool request_settle(core::Region key) {
        auto &t=tiles_.at(key);if(!t.local||!t.resident)return false;
        t.phase=Phase::settling;t.stable_ticks=0;return true;
    }
    void set_resident(core::Region key,bool resident) {
        auto &t=tiles_.at(key);if(t.resident==resident)return;t.resident=resident;rebuild();
    }
    // Unloading a region must not consume a local slot forever if its
    // state is exactly representable by the aggregate. Frozen time is
    // not counted as stable ticks: live fronts and momentum are retained.
    bool reclaim_suspended(core::Region k) {
        auto &t=tiles_.at(k);
        if(t.resident||!t.local)return false;
        auto contents=collect(t);if(!contents)return false;
        for(const auto &c:t.local->columns())if(c.falling())return false;
        if(!contents->empty()){
            for(const auto &p:t.local->pipes())if(p.flux!=0||p.credit!=0)return false;
            const auto expected=project(t,*t.local,t.owners,*contents);if(!expected)return false;
            for(std::size_t i=0;i<expected->size();++i)
                if((*expected)[i]!=t.local->columns()[i].litres)return false;
        }
        // Completely dry intervals carry no liquid momentum.
        aggregate_owner(k,t,std::move(*contents));rebuild();verify();return true;
    }
    void suspend_all() {for(auto &[k,t]:tiles_){(void)k;t.resident=false;}rebuild();}
    bool forget_dry(core::Region key) {
        auto it=tiles_.find(key);
        if(it==tiles_.end()||it->second.resident||it->second.local||tile_mass(key)||
            std::any_of(oceans_.begin(),oceans_.end(),[&](const auto &o){return o.tile==key;}))return false;
        tiles_.erase(it);surface_changes_.insert(key);rebuild();verify();return true;
    }
    bool replace_geometry(std::shared_ptr<const tp::Result> geometry,bool displace=false) {
        auto &t=tiles_.at(geometry->origin);
        if(geometry->revision<t.geometry->revision||geometry->nx!=t.geometry->nx||geometry->nz!=t.geometry->nz||geometry->step!=1)return false;
        if(geometry->revision==t.geometry->revision) {
            const auto &a=t.geometry->column_runs,&b=geometry->column_runs;
            if(a.size()!=b.size())return false;
            for(std::size_t i=0;i<a.size();++i){if(a[i].size()!=b[i].size())return false;for(std::size_t j=0;j<a[i].size();++j)
                if(a[i][j].bottom!=b[i][j].bottom||a[i][j].top!=b[i][j].top||a[i][j].compartment!=b[i][j].compartment||tp::span_floor_mm(*t.geometry,a[i][j])!=tp::span_floor_mm(*geometry,b[i][j]))return false;}
            surface_changes_.insert(geometry->origin);t.geometry=std::move(geometry);t.resident=true;rebuild();return true;
        }
        if(t.local) {
            Local staged(*geometry,types_);
            if(!staged.remap_from(*t.local,displace))return false;
            auto owners=mapping(*geometry,staged);
            t.local.emplace(std::move(staged));t.owners=std::move(owners);t.phase=Phase::local_active;t.stable_ticks=0;
        }else {
            auto remap=tp::remap(*t.geometry,*geometry,t.aggregate);if(!remap)return false;
            t.aggregate=std::move(remap->contents);
        }
        surface_changes_.insert(geometry->origin);t.ocean_reach.clear();t.geometry=std::move(geometry);t.resident=true;t.epoch=++epoch_;rebuild();verify();return true;
    }
    bool ocean(Ocean o) {
        if(o.id.empty()||o.type>=types_.size()||!std::isfinite(o.head)||!std::isfinite(o.sill)||
            !std::isfinite(o.width)||o.width<=0||o.head<=o.sill||!tiles_.contains(o.tile)||
            !tp::span_at(*tiles_.at(o.tile).geometry,o.anchor)||
            std::any_of(oceans_.begin(),oceans_.end(),[&](const auto &v){return v.id==o.id;}))return false;
        oceans_.push_back(std::move(o));rebuild();return true;
    }
    Litres tick() {
        Litres moved=0;std::set<core::Region> exchanging;
        for(auto &[k,t]:tiles_)if(t.resident&&t.local){const auto amount=t.local->tick().moved;moved+=amount;if(amount)surface_changes_.insert(k);}
        std::map<Owner,Litres> sent,received;
        std::map<Owner,std::size_t> receiving_type;
        struct Transfer {Owner from,to;std::size_t type;Litres amount;};
        std::vector<Transfer> transfers;
        for(const auto &p:interfaces_) {
            Owner from=p.a,to=p.b;auto src=value(from),dst=value(to);
            if(src.head<dst.head){std::swap(from,to);std::swap(src,dst);}
            if((!src.ocean&&!src.mass)||(dst.type!=no_liquid&&dst.type!=src.type)||
                (receiving_type.contains(to)&&receiving_type.at(to)!=src.type)||
                (from.kind==1&&src.mass==src.capacity)||(to.kind==1&&dst.mass==dst.capacity))continue;
            const double head=src.head-std::max(dst.head,p.sill);
            const double area=std::max(0.0,std::min(src.head,p.soffit)-p.sill)*p.width;
            if(head<=0||area<=0)continue;
            const auto discharge=static_cast<Litres>(std::floor(0.62*area*std::sqrt(2*9.81*head)*1000*tick_s/types_.at(src.type).viscosity));
            Litres hi=std::min({discharge,src.ocean?volume_limit:src.mass-sent[from],
                src.ocean?volume_limit:above(from,p.sill)-sent[from],dst.ocean?volume_limit:dst.capacity-dst.mass-received[to]});
            if(hi<=0)continue;
            Litres lo=0;
            while(lo<hi) {
                const auto mid=lo+(hi-lo+1)/2;
                if(level_after(from,received[from]-sent[from]-mid)>=std::max(p.sill,level_after(to,received[to]-sent[to]+mid)))lo=mid;else hi=mid-1;
            }
            if(!lo)continue;
            sent[from]+=lo;received[to]+=lo;receiving_type[to]=src.type;transfers.push_back({from,to,src.type,lo});
            if(from.kind!=2)exchanging.insert(from.tile);
            if(to.kind!=2)exchanging.insert(to.tile);
            moved+=lo;
        }
        // Apply withdrawals first; no use of incoming mass for proposals.
        for(const auto &v:transfers)remove(v.from,v.amount);
        for(const auto &v:transfers)add(v.to,v.type,v.amount);
        surface_changes_.insert(exchanging.begin(),exchanging.end());
        bool changed=false;
        for(auto &[k,t]:tiles_)if(t.resident&&t.local&&t.phase==Phase::settling) {
            if(!exchanging.contains(k)&&settled(t))++t.stable_ticks;else t.stable_ticks=0;
            if(t.stable_ticks>=20) {
                auto aggregate=collect(t);
                if(!aggregate)throw std::logic_error("R3 settled aggregate");
                aggregate_owner(k,t,std::move(*aggregate));changed=true;
            }
        }
        if(changed)rebuild();
        verify();return moved;
    }
    // Separate experimental schema: caller supplies immutable geometry
    // from the same terrain checkpoint. Flux momentum is persisted.
    // A single owner record is independent of the hot graph. Geometry is
    // supplied separately by the revision-certified archive reader.
    nlohmann::json encode_tile(core::Region k)const {
        using J=nlohmann::json;
        const auto &t=tiles_.at(k);
        J content=J::array(),pipes=J::array(),falling=J::array();
        if(t.local){
            for(std::size_t i=0;i<t.local->columns().size();++i){
                const auto &c=t.local->columns()[i];
                if(c.litres)content.push_back({i,types_.at(c.type).id,c.litres});
                if(c.falling())falling.push_back({i,c.fall_start_mm,c.fall_ticks});
            }
            for(const auto &p:t.local->pipes())pipes.push_back({p.flux,p.credit});
        }else for(const auto &[id,v]:t.aggregate)if(v.litres)content.push_back({id,types_.at(v.type).id,v.litres});
        J reach=J::array();for(const auto &[id,proof]:t.ocean_reach){(void)id;reach.push_back(proof.encode());}
        return {{"ocean_reach",reach},{"falling",falling},{"tile",{k.x,k.y,k.z}},{"revision",t.geometry->revision},{"epoch",t.epoch},{"local",t.local.has_value()},
            {"phase",static_cast<int>(t.phase)},{"resident",t.resident},{"stable",t.stable_ticks},{"content",content},{"pipes",pipes}};
    }
    bool can_archive(core::Region k)const {
        const auto it=tiles_.find(k);
        return it!=tiles_.end()&&!it->second.resident&&
            std::none_of(oceans_.begin(),oceans_.end(),[&](const auto &o){return o.tile==k;});
    }
    // Caller must durably write the exact owner and geometry first.
    // The global ledger includes cold mass, but tick/rebuild never scan it.
    bool detach_cold(core::Region k) {
        if(!can_archive(k))return false;
        const auto amount=tile_mass(k);
        if(!amount&&!tiles_.at(k).local)return false;
        if(cold_mass_>2*ledger_limit-amount||cold_count_==std::numeric_limits<std::uint64_t>::max())return false;
        cold_mass_+=amount;++cold_count_;
        tiles_.erase(k);surface_changes_.insert(k);rebuild();verify();return true;
    }
    std::optional<std::pair<CoupledTile,Litres>> inspect_cold(std::shared_ptr<const tp::Result> geometry,const nlohmann::json& row)const {
        if(!geometry||!cold_count_||tiles_.contains(geometry->origin)||row.at("resident").get<bool>())return std::nullopt;
        const auto k=geometry->origin;
        const auto &a=row.at("tile");
        if(a.at(0).get<int>()!=k.x||a.at(1).get<int>()!=k.y||a.at(2).get<int>()!=k.z)return std::nullopt;
        if(!tiles_.empty()&&(geometry->nx!=tiles_.begin()->second.geometry->nx||geometry->nz!=tiles_.begin()->second.geometry->nz||k.y!=tiles_.begin()->first.y))return std::nullopt;
        Litres amount=0;
        for(const auto &v:row.at("content")){
            const auto n=v.at(2).get<Litres>();if(n<=0||n>cold_mass_-amount)return std::nullopt;amount+=n;
        }
        using J=nlohmann::json;
        auto staged=decode(J{{"schema","hybrid-coupler-1"},{"initial",amount},{"injected",0},{"drained",0},{"epoch",epoch_},
            {"active_limit",1},{"tile_limit",1},{"tiles",J::array({row})},{"oceans",J::array()}},types_,{{k,geometry}});
        if(staged.mass()!=amount||staged.tiles_.at(k).epoch>epoch_||
            (cold_count_==1&&amount!=cold_mass_))return std::nullopt;
        return std::pair{std::move(staged.tiles_.at(k)),amount};
    }
    bool restore_cold(std::shared_ptr<const tp::Result> geometry,const nlohmann::json& row) {
        if(!geometry||tiles_.size()>=tile_limit_||
            (row.at("local").get<bool>()&&active()>=active_limit_))return false;
        const auto k=geometry->origin;
        auto decoded=inspect_cold(std::move(geometry),row);if(!decoded)return false;
        tiles_.emplace(k,std::move(decoded->first));cold_mass_-=decoded->second;--cold_count_;
        surface_changes_.insert(k);rebuild();verify();return true;
    }
    nlohmann::json encode()const {
        using J=nlohmann::json;
        J rows=J::array(),ocean_rows=J::array();
        for(const auto &[k,t]:tiles_){(void)t;rows.push_back(encode_tile(k));}
        for(const auto &o:oceans_)ocean_rows.push_back({{"id",o.id},{"tile",{o.tile.x,o.tile.y,o.tile.z}},
            {"anchor",{o.anchor.x,o.anchor.y,o.anchor.z}},{"type",types_.at(o.type).id},{"head",o.head},{"sill",o.sill},{"width",o.width}});
        return {{"schema","hybrid-coupler-1"},{"initial",initial_},{"injected",injected_},{"drained",drained_},{"epoch",epoch_},
            {"active_limit",active_limit_},{"tile_limit",tile_limit_},{"tiles",rows},{"oceans",ocean_rows},
            {"cold_mass",cold_mass_},{"cold_count",cold_count_}};
    }
    static Coupler decode(const nlohmann::json& j,std::vector<Liquid> types,
        const std::map<core::Region,std::shared_ptr<const tp::Result>>& geometry) {
        if(j.at("schema")!="hybrid-coupler-1")throw std::invalid_argument("R3 archive schema");
        Coupler out(types,j.at("active_limit").get<std::size_t>(),j.at("tile_limit").get<std::size_t>());
        auto key=[](const nlohmann::json& a){return core::Region{a.at(0).get<int>(),a.at(1).get<int>(),a.at(2).get<int>()};};
        auto type=[&](const nlohmann::json& a){const auto id=a.get<std::string>();for(std::size_t i=0;i<types.size();++i)if(types[i].id==id)return i;throw std::invalid_argument("R3 archive liquid");};
        for(const auto &row:j.at("tiles")) {
            const auto k=key(row.at("tile"));const auto g=geometry.at(k);
            if(g->revision!=row.at("revision").get<std::uint64_t>()||!out.publish(g))throw std::invalid_argument("R3 archive terrain revision");
            auto &t=out.tiles_.at(k);
            if(row.at("local").get<bool>()) {
                if(!out.activate(k))throw std::invalid_argument("R3 archive active budget");
                if(row.contains("falling")){
                    const auto &falling=row.at("falling");
                    if(!falling.is_array()||falling.size()>t.local->columns().size())throw std::invalid_argument("R3 archive fall bounds");
                    std::set<std::size_t> seen;
                    for(const auto &v:falling){
                        if(!v.is_array()||v.size()!=3)throw std::invalid_argument("R3 archive falling");
                        const auto idx=v.at(0).get<std::size_t>();
                        if(idx>=t.local->columns().size()||!seen.insert(idx).second||
                            !t.local->restore_fall(idx,v.at(1).get<int>(),v.at(2).get<unsigned>()))
                            throw std::invalid_argument("R3 archive falling state");
                    }
                }
                for(const auto &v:row.at("content"))if(!t.local->receive(v.at(0).get<std::size_t>(),type(v.at(1)),v.at(2).get<Litres>()))
                    throw std::invalid_argument("R3 archive interval");
                if(row.at("pipes").size()!=t.local->pipes().size())throw std::invalid_argument("R3 archive pipe count");
                for(std::size_t i=0;i<t.local->pipes().size();++i)t.local->restore_pipe(i,row.at("pipes")[i][0].get<double>(),row.at("pipes")[i][1].get<double>());
                // Temporarily keep the ledger consistent for subsequent
                // activation; replace with persisted external ledger below.
                out.initial_+=t.local->mass();
            }else for(const auto &v:row.at("content"))if(!out.seed(k,v.at(0).get<Id>(),type(v.at(1)),v.at(2).get<Litres>()))
                throw std::invalid_argument("R3 archive aggregate");
            const int phase=row.at("phase").get<int>();
            if(phase<0||phase>static_cast<int>(Phase::blocked)||phase==static_cast<int>(Phase::activating)||
                (t.local&&(phase==static_cast<int>(Phase::aggregate)))||(!t.local&&(phase==static_cast<int>(Phase::local_active)||phase==static_cast<int>(Phase::settling))))
                throw std::invalid_argument("R3 archive phase");
            t.phase=static_cast<Phase>(phase);t.resident=row.at("resident").get<bool>();
            t.epoch=row.at("epoch").get<std::uint64_t>();t.stable_ticks=row.at("stable").get<unsigned>();
            if(row.contains("ocean_reach")){
                const auto &proofs=row.at("ocean_reach");
                if(!proofs.is_array()||proofs.size()>64)throw std::invalid_argument("ocean proof count");
                for(const auto &encoded:proofs){
                    auto proof=OceanReach::decode(encoded,*g);
                    if(!t.ocean_reach.emplace(proof.source,std::move(proof)).second)throw std::invalid_argument("duplicate ocean proof");
                }
            }
        }
        for(const auto &row:j.at("oceans")){
            const auto &a=row.at("anchor");
            if(!out.ocean({row.at("id").get<std::string>(),key(row.at("tile")),{a[0].get<double>(),a[1].get<double>(),a[2].get<double>()},
                type(row.at("type")),row.at("head").get<double>(),row.at("sill").get<double>(),row.at("width").get<double>()}))throw std::invalid_argument("R3 archive ocean");
        }
        out.initial_=j.at("initial").get<Litres>();out.injected_=j.at("injected").get<Litres>();out.drained_=j.at("drained").get<Litres>();
        out.cold_mass_=j.value("cold_mass",Litres(0));out.cold_count_=j.value("cold_count",std::uint64_t(0));
        if(out.initial_<0||out.injected_<0||out.drained_<0||out.cold_mass_<0||
            out.cold_mass_>2*ledger_limit||(!out.cold_count_&&out.cold_mass_))throw std::invalid_argument("R3 archive ledger");
        out.epoch_=j.at("epoch").get<std::uint64_t>();out.rebuild();out.verify();return out;
    }
};
}
