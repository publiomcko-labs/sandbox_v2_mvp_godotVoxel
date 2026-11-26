#pragma once
#include "loader.hpp"
#include "core/fluids.hpp"

namespace sandbox::content {
struct FluidProfile {
    std::vector<sandbox::fluid::Liquid> types;
    std::vector<std::string> ids;
    Json config;
};
inline FluidProfile compile_fluids(const Snapshot &s) {
    FluidProfile p;
    p.config={{"liquids",Json::array()},{"reservoirs",Json::array()}};
    for(const auto &r:s.records) if(r.type=="liquid" && r.data.contains("albedo")) {
        require(p.types.size()<32,"fluid type limit");
        const int rate=static_cast<int>(std::clamp(500.0/r.data.at("viscosity").get<double>(),1.0,1000.0));
        const int substeps=r.data.value("substeps",1);
        p.types.push_back({rate,r.data.at("density").get<double>(),substeps});
        p.ids.push_back(r.id);
        auto entry=r.data;entry["id"]=r.id;entry["rate_litres"]=rate;entry["substeps"]=substeps;
        p.config["liquids"].push_back(entry);
    }
    require(!p.types.empty(),"no complete liquid types");
    for(const auto &r:s.records) if(r.type=="liquid_source_rule" && r.data.contains("anchor_x")) {
        require(p.config["reservoirs"].size()<16,"reservoir limit");
        const auto id=str(r.data.at("liquid"));
        const auto it=std::find(p.ids.begin(),p.ids.end(),id);
        require(it!=p.ids.end(),"reservoir requires complete liquid");
        auto entry=r.data;entry["id"]=r.id;entry["slot"]=static_cast<int>(it-p.ids.begin());
        p.config["reservoirs"].push_back(entry);
    }
    return p;
}
}
