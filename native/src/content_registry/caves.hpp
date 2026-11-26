#pragma once
#include "loader.hpp"
#include "seed.hpp"

namespace sandbox::content {
inline Json compile_caves(const Snapshot &s,const std::string &id,std::uint64_t world_seed) {
    const auto found=s.indices.find(id);
    require(found!=s.indices.end(),"cave profile absent");
    const auto &p=s.records.at(found->second);
    require(p.type=="cave_profile" && p.data.contains("entrance_elongation"),"profile not V3.3 organic entrance format");
    Json config=p.data;
    config["id"]=id;
    config["noise_seeds"]=Json::array();
    for(const auto *role:{"sheet_a","sheet_b","sheet_c","entrance","pocket"})
        config["noise_seeds"].push_back(composed_seed(world_seed,id,0,0,0,
            std::string("v3_3_caves_v1:")+role)&0x7fffffffULL);
    // Preserve existing underground noise domains for controlled comparison.
    // The new independent entrance warp is versioned separately.
    config["noise_seeds"].push_back(composed_seed(world_seed,id,0,0,0,
        "v3_3_caves_v2:entrance_z")&0x7fffffffULL);
    config["noise_seeds"].push_back(composed_seed(world_seed,id,0,0,0,
        "v3_3_caves_v3:entrance_wall")&0x7fffffffULL);
    return config;
}
}
