#pragma once
#include "hydraulic_remap.hpp"
#include <memory>
namespace sandbox::hydraulic {
namespace tp=topology;
struct Tile {
    std::shared_ptr<const tp::Result> geometry;
    std::map<Id,Id> ids; // local compartment -> globally unique ID
    bool available=true;
    std::uint64_t expected_revision{};
    bool renderable()const{return geometry&&expected_revision==geometry->revision;}
};
struct OceanLink {
    std::string source;
    core::Region tile;
    core::Vec3 anchor;
    Id ocean{};
    double sill{},area{};
};
class Domain {
    Graph graph_;
    std::map<core::Region,Tile> tiles_;
    std::map<std::string,OceanLink> oceans_;
    std::set<std::string> seeded_;
    Id next_node_=1,next_portal_=1;
    int width_,depth_,step_,base_y_;
    static constexpr std::size_t tile_limit=256;
    static Id allocate(Id &n) {
        if(n==std::numeric_limits<Id>::max())throw std::length_error("hydraulic ID exhausted");
        return n++;
    }
    static void connect(Graph &g,Id &next,const Tile &a,const Tile &b,int face) {
        // Keep a certified geometric connection even when streaming has
        // suspended a neighbouring tile. Such a portal remains physically
        // closed. A tile whose geometry was edited is NOT certified.
        if(!a.renderable()||!b.renderable())return;
        for(const auto &o:tp::connect_faces(*a.geometry,*b.geometry,face))
            g.add_portal({allocate(next),a.ids.at(o.a),b.ids.at(o.b),double(o.sill_mm)*0.001,
                o.area_m2,0.62,a.available&&b.available,std::max(a.geometry->revision,b.geometry->revision),double(o.soffit_mm-o.sill_mm)*0.001});
    }
    static void attach(Graph &g,Id &next,const Tile &t,const OceanLink &o) {
        if(!t.available)return;
        const auto id=tp::compartment_at(*t.geometry,o.anchor);
        if(!id)return; // blocked/removed anchor remains closed, no inferred path
        g.add_portal({allocate(next),o.ocean,t.ids.at(*id),o.sill,o.area,0.62,true,t.geometry->revision});
    }
    core::Region key(core::Vec3 point)const {
        return {static_cast<int>(std::floor(point.x/width_))*width_,base_y_,
                static_cast<int>(std::floor(point.z/depth_))*depth_};
    }
public:
    Domain(std::vector<Liquid> types,int nx=16,int nz=16,int step=1,int base_y=-32)
        :graph_(std::move(types)),width_(nx*step),depth_(nz*step),step_(step),base_y_(base_y) {
        if(nx<1||nx>32||nz<1||nz>32||step<1||step>4||std::abs(std::int64_t(base_y))>99000)
            throw std::invalid_argument("domain tile shape");
    }
    const Graph &graph()const{return graph_;}
    const auto &tiles()const{return tiles_;}
    const auto &seeded()const{return seeded_;}
    const auto &oceans()const{return oceans_;}
    // Invalidate before terrain mutation or unload. The old mass is retained
    // but unavailable to physics and transfer until revalidated.
    void invalidate(core::Region origin,std::uint64_t revision) {
        auto it=tiles_.find(origin);if(it==tiles_.end())return;
        auto &t=it->second;
        if(revision<t.expected_revision)return;
        t.available=false;t.expected_revision=revision;
        for(const auto &[local,id]:t.ids) {
            (void)local;
            for(auto p:graph_.incident(id))graph_.invalidate_portal(p,std::max(revision,graph_.portals().at(p).revision));
        }
    }
    bool publish(tp::Result geometry) {
        const auto origin=geometry.origin;
        if(origin.y!=base_y_||origin.x%width_||origin.z%depth_||
            geometry.nx*geometry.step!=width_||geometry.nz*geometry.step!=depth_||geometry.step!=step_)
            throw std::invalid_argument("domain tile alignment");
        const auto old=tiles_.find(origin);
        if(old==tiles_.end()&&tiles_.size()>=tile_limit)return false;
        if(old!=tiles_.end()&&(geometry.revision<old->second.expected_revision||
            geometry.revision<old->second.geometry->revision))return false;
        // Same revision revalidation after unload requires identical geometry.
        // Normal edited geometry always has a strictly newer revision.
        if(old!=tiles_.end()&&geometry.revision==old->second.geometry->revision) {
            if(old->second.available)return false;
            // Geometry snapshot is recomputed, compare all column intervals.
            const auto &before=old->second.geometry->column_runs;
            if(before.size()!=geometry.column_runs.size())return false;
            for(std::size_t i=0;i<before.size();++i) {
                const auto &a=before[i],&b=geometry.column_runs[i];
                if(a.size()!=b.size())return false;
                for(std::size_t j=0;j<a.size();++j)
                    if(a[j].bottom!=b[j].bottom||a[j].top!=b[j].top||a[j].compartment!=b[j].compartment)return false;
            }
        }
        // Copy-on-publication staging for this bounded prototype. Ticks do
        // not copy or rebuild topology. Geometry itself is shared immutable.
        auto staged=graph_;auto tiles=tiles_;
        auto node=next_node_,portal=next_portal_;
        const auto initial=graph_.initial(),injected=graph_.injected(),drained=graph_.drained();
        std::map<Id,tp::Content> contents;
        if(old!=tiles_.end()) {
            std::set<Id> ids;
            for(const auto &[local,id]:old->second.ids) {
                const auto &v=graph_.volumes().at(id);ids.insert(id);
                if(v.litres)contents.emplace(local,tp::Content{v.type,v.litres});
            }
            if(geometry.revision>old->second.geometry->revision) {
                auto mapped=tp::remap(*old->second.geometry,geometry,contents);
                if(!mapped)return false;
                contents=std::move(mapped->contents);
            }
            staged.erase_region(ids);
        }
        Tile t{std::make_shared<const tp::Result>(std::move(geometry)),{},true,0};
        t.expected_revision=t.geometry->revision;
        for(const auto &c:t.geometry->compartments) {
            const auto found=contents.find(c.id);
            const auto a=found==contents.end()?tp::Content{no_liquid,0}:found->second;
            const auto id=allocate(node);t.ids.emplace(c.id,id);
            staged.add_volume({id,a.type,c.curve,a.litres});
        }
        for(const auto &o:t.geometry->openings)
            staged.add_portal({allocate(portal),t.ids.at(o.a),t.ids.at(o.b),
                double(o.sill_mm)*0.001,o.area_m2,0.62,true,t.geometry->revision,double(o.soffit_mm-o.sill_mm)*0.001});
        constexpr std::array<core::Region,4> dirs{{{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}}};
        for(int face=0;face<4;++face) {
            const auto d=dirs[static_cast<std::size_t>(face)];
            const core::Region neighbor{origin.x+d.x*width_,origin.y,origin.z+d.z*depth_};
            auto n=tiles.find(neighbor);
            if(n!=tiles.end())connect(staged,portal,t,n->second,face);
        }
        for(const auto &[name,o]:oceans_)if(o.tile==origin){(void)name;attach(staged,portal,t,o);}
        staged.restore_ledger(initial,injected,drained);
        tiles.insert_or_assign(origin,std::move(t));
        graph_=std::move(staged);tiles_=std::move(tiles);next_node_=node;next_portal_=portal;
        return true;
    }
    std::optional<Id> volume_at(core::Vec3 point)const {
        if(!core::valid_point(point))return {};
        const auto it=tiles_.find(key(point));
        if(it==tiles_.end()||!it->second.available)return {};
        auto local=tp::compartment_at(*it->second.geometry,point);
        if(!local)return {};
        return it->second.ids.at(*local);
    }
    std::optional<tp::Content> wet_at(core::Vec3 point)const {
        const auto id=volume_at(point);if(!id)return {};
        const auto &v=graph_.volumes().at(*id);
        if(!v.litres||point.y>=v.level())return {};
        return tp::Content{v.type,v.litres};
    }
    // Exposure/connection is certified by the source classifier, not by
    // altitude. Source IDs are idempotent; no injection on tile reload.
    bool seed_finite(const std::string &source,core::Vec3 anchor,std::size_t type,double level,bool exposure_certified) {
        if(source.empty()||!exposure_certified||seeded_.contains(source)||!std::isfinite(level)||level<=anchor.y)return false;
        const auto id=volume_at(anchor);if(!id)return false;
        const auto amount=graph_.volumes().at(*id).curve.at_level(level);
        if(!graph_.initialize(*id,type,amount))return false;
        seeded_.insert(source);return true;
    }
    // Initial finite lake only: seed the declared head across the known
    // exposed, hydraulically reachable component. Never traverse a closed
    // or above-head sill, a covered interval, or an already seeded body.
    // Later edits and new tiles use the ordinary conservative solver.
    bool seed_surface_basin(const std::string &source,core::Vec3 anchor,std::size_t type,
            double level,int ceiling,const std::set<core::Region> &window,
            std::set<core::Region>* frontier=nullptr) {
        if(frontier)frontier->clear();
        if(source.empty()||!std::isfinite(level)||level<=anchor.y||
            type>=graph_.types().size()||seeded_.contains(source))return false;
        const auto root=volume_at(anchor);if(!root)return false;
        std::set<Id> exposed;
        for(const auto &k:window) {
            const auto it=tiles_.find(k);
            if(it==tiles_.end()||!it->second.available)return false;
            const auto &t=it->second;
            for(const auto &c:t.geometry->compartments)
                if(std::any_of(c.spans.begin(),c.spans.end(),[&](const auto &s){
                    return t.geometry->origin.y+s.top*t.geometry->step==ceiling;
                }))exposed.insert(t.ids.at(c.id));
        }
        const auto eligible=[&](Id id){
            const auto &v=graph_.volumes().at(id);
            return exposed.contains(id)&&!v.ocean&&!v.litres&&v.curve.at_level(level)>0;
        };
        if(!eligible(*root))return false;
        std::set<Id> reached{*root};
        std::deque<Id> queue{*root};
        while(!queue.empty()) {
            const auto id=queue.front();queue.pop_front();
            for(auto pid:graph_.incident(id)) {
                const auto &p=graph_.portals().at(pid);
                if(!p.available||p.sill_m>=level||p.opening_height_m<=0||
                    p.sill_m+p.opening_height_m<double(ceiling)-0.001)continue;
                const auto next=p.a==id?p.b:p.a;
                if(eligible(next)&&reached.insert(next).second)queue.push_back(next);
            }
        }
        // Discover only exposed, below-head boundaries of the component
        // actually reached. Do not seed while a potential continuation
        // has not been classified. The caller enforces the search budget.
        if(frontier) {
            constexpr std::array<core::Region,4> dirs{{{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}}};
            for(const auto &k:window) {
                const auto &t=tiles_.at(k);
                for(const auto &b:t.geometry->boundaries) {
                    if(b.top_mm!=ceiling*1000||b.bottom_mm>=level*1000||
                        !reached.contains(t.ids.at(b.compartment)))continue;
                    const auto dir=dirs.at(static_cast<std::size_t>(b.face));
                    const core::Region next{k.x+dir.x*width_,k.y,k.z+dir.z*depth_};
                    if(!window.contains(next))frontier->insert(next);
                }
            }
            if(!frontier->empty())return false;
        }
        auto staged=graph_;
        for(auto id:reached)
            if(!staged.initialize(id,type,staged.volumes().at(id).curve.at_level(level)))return false;
        graph_=std::move(staged);seeded_.insert(source);return true;
    }
    bool add_ocean(const std::string &source,core::Vec3 anchor,std::size_t type,double level,double area,bool exposure_certified) {
        if(source.empty()||!exposure_certified||seeded_.contains(source)||!core::valid_point(anchor)||
            !std::isfinite(level)||level<=anchor.y||!std::isfinite(area)||area<=0||area>4096)return false;
        const auto id=volume_at(anchor);if(!id)return false;
        auto staged=graph_;auto node=next_node_,portal=next_portal_;
        const auto ocean=allocate(node);
        staged.add_volume({ocean,type,Curve({{0,0},{1000,1000}}),0,true,level});
        const auto origin=key(anchor);
        OceanLink link{source,origin,anchor,ocean,anchor.y,area};
        attach(staged,portal,tiles_.at(origin),link);
        auto sources=oceans_;sources.emplace(source,link);
        auto seeded=seeded_;seeded.insert(source);
        graph_=std::move(staged);oceans_=std::move(sources);seeded_=std::move(seeded);
        next_node_=node;next_portal_=portal;return true;
    }
    // Restore a validated archive. Graph IDs are session-local and can be
    // regenerated; source IDs and exact finite mass are persistent.
    bool restore_content(core::Region origin,Id local,std::size_t type,Litres litres) {
        return graph_.initialize(tiles_.at(origin).ids.at(local),type,litres);
    }
    void restore_ledger(Litres initial,Litres injected,Litres drained) {graph_.restore_ledger(initial,injected,drained);}
    void restore_seeded(const std::string &id) {
        if(id.empty())throw std::invalid_argument("source id");
        seeded_.insert(id);
    }
    Report tick(std::size_t budget=256){return graph_.tick(budget);}
};
}
