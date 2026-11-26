#pragma once
#include "loader.hpp"
#include "seed.hpp"

namespace sandbox::content {
inline Json compile_caves(const Snapshot &s,const std::string &id,std::uint64_t world_seed) {
    const auto found=s.indices.find(id);
    require(found!=s.indices.end(),"cave profile absent");
    const auto &p=s.records.at(found->second);
    require(p.type=="cave_profile" && p.data.contains("chamber_radius_m"),"profile not V3.3");
    Json config=p.data;
    config["id"]=id;
    config["noise_seeds"]=Json::array();
    for(const auto *role:{"sheet_a","sheet_b","sheet_c","entrance","pocket"})
        config["noise_seeds"].push_back(composed_seed(world_seed,id,0,0,0,
            std::string("v3_3_caves_v1:")+role)&0x7fffffffULL);
    return config;
}
}
