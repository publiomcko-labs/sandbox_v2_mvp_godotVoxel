#pragma once
#include "checkpoint.hpp"
#include "core/hydraulic_graph.hpp"
namespace sandbox::persistence {
namespace hy=sandbox::hydraulic;
inline Json encode_hydraulic(const hy::Graph &g) {
    Json volumes=Json::array(),portals=Json::array();
    for(const auto &[id,v]:g.volumes()) {
        Json curve=Json::array();
        for(auto k:v.curve.knots())curve.push_back({k.mm,k.litres});
        volumes.push_back({{"id",id},{"type",g.types().at(v.type).id},{"curve",curve},{"litres",v.litres},
                           {"ocean",v.ocean},{"level",v.ocean_level}});
    }
    for(const auto &[id,p]:g.portals())portals.push_back({{"id",id},{"a",p.a},{"b",p.b},{"sill",p.sill_m},
        {"area",p.area_m2},{"coefficient",p.coefficient},{"revision",p.revision}});
    return {{"schema",1},{"initial",g.initial()},{"injected",g.injected()},{"drained",g.drained()},
            {"volumes",volumes},{"portals",portals}};
}
inline hy::Litres hydraulic_integer(const Json &j,hy::Litres lo,hy::Litres hi) {
    require(j.is_number_integer()&&j.get<double>()>=double(lo)&&j.get<double>()<=double(hi),"hydraulic integer range");
    return j.get<hy::Litres>();
}
inline double hydraulic_number(const Json &j) {
    require(j.is_number()&&std::isfinite(j.get<double>()),"hydraulic number");return j.get<double>();
}
inline hy::Graph decode_hydraulic(const Json &j,const std::vector<hy::Liquid> &types) {
    content::fields(j,{"schema","initial","injected","drained","volumes","portals"});
    require(j.at("schema")==1&&j.at("volumes").is_array()&&j.at("volumes").size()<=hy::volume_count_limit&&
            j.at("portals").is_array()&&j.at("portals").size()<=hy::portal_count_limit,"hydraulic schema");
    hy::Graph g(types);
    auto id=[](const Json &v){return static_cast<hy::Id>(hydraulic_integer(v,1,std::numeric_limits<hy::Id>::max()));};
    for(const auto &v:j.at("volumes")) {
        content::fields(v,{"id","type","curve","litres","ocean","level"});
        const auto type=content::str(v.at("type"));
        auto t=std::find_if(types.begin(),types.end(),[&](const auto &l){return l.id==type;});
        require(t!=types.end()&&v.at("ocean").is_boolean()&&v.at("curve").is_array()&&v.at("curve").size()<=256,"hydraulic volume format");
        std::vector<hy::Knot> knots;
        for(const auto &k:v.at("curve")) {
            require(k.is_array()&&k.size()==2,"hydraulic curve knot");
            knots.push_back({static_cast<int>(hydraulic_integer(k[0],-100000000,100000000)),hydraulic_integer(k[1],0,hy::volume_limit)});
        }
        g.add_volume({id(v.at("id")),static_cast<std::size_t>(t-types.begin()),hy::Curve(std::move(knots)),
            hydraulic_integer(v.at("litres"),0,hy::volume_limit),v.at("ocean").get<bool>(),hydraulic_number(v.at("level"))});
    }
    for(const auto &p:j.at("portals")) {
        content::fields(p,{"id","a","b","sill","area","coefficient","revision"});
        // Residency is never persisted. Every restored portal is closed
        // until its terrain revision and opening are validated anew.
        g.add_portal({id(p.at("id")),id(p.at("a")),id(p.at("b")),hydraulic_number(p.at("sill")),
            hydraulic_number(p.at("area")),hydraulic_number(p.at("coefficient")),false,uint(p.at("revision"))});
    }
    g.restore_ledger(hydraulic_integer(j.at("initial"),0,hy::ledger_limit),
        hydraulic_integer(j.at("injected"),0,hy::ledger_limit),hydraulic_integer(j.at("drained"),0,hy::ledger_limit));
    return g;
}
inline void save_hydraulic(const fs::path &world,const hy::Graph &g) {
    const auto tmp=world/"session_pending"/"hydraulic.tmp";
    write_new(tmp,encode_hydraulic(g));replace_file(tmp,world/"hydraulic.json");
}
inline hy::Graph load_hydraulic(const fs::path &world,const std::vector<hy::Liquid> &types) {
    const auto p=world/"hydraulic.json";plain_unique_file(p);
    return decode_hydraulic(read_json(p),types);
}
}
