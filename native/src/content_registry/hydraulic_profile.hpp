#pragma once
#include "loader.hpp"
#include "core/hydraulic_graph.hpp"
namespace sandbox::content {
namespace hy=sandbox::hydraulic;
struct HydraulicProfile {
    std::vector<hy::Liquid> types;
    Json config={{"liquids",Json::array()},{"sources",Json::array()}};
};
inline HydraulicProfile compile_hydraulic(const Snapshot &snapshot) {
    HydraulicProfile out;
    std::map<std::string,std::size_t> slots;
    for(const auto &r:snapshot.records)if(r.type=="liquid"&&r.data.contains("albedo")) {
        require(out.types.size()<32,"hydraulic liquid limit");
        const auto density=r.data.at("density").get<double>(),viscosity=r.data.at("viscosity").get<double>();
        require(viscosity>=0.01&&viscosity<=10000,"hydraulic viscosity limit");
        slots.emplace(r.id,out.types.size());
        out.types.push_back({r.id,viscosity,density});
        auto entry=r.data;entry["id"]=r.id;out.config["liquids"].push_back(entry);
    }
    require(!out.types.empty(),"no hydraulic liquids");
    for(const auto &r:snapshot.records)if(r.type=="liquid_source_rule"&&r.data.contains("anchor_m")) {
        require(out.config["sources"].size()<64,"hydraulic source limit");
        const auto liquid=str(r.data.at("liquid"));
        require(slots.contains(liquid),"hydraulic source requires complete liquid");
        auto entry=r.data;entry["id"]=r.id;entry["slot"]=slots.at(liquid);
        out.config["sources"].push_back(entry);
    }
    return out;
}
}
