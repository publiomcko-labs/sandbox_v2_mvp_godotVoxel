#pragma once
#include "loader.hpp"

namespace sandbox::content {
struct GeologyPalette {
    std::string profile_id;
    std::vector<std::string> ids;
    Json config;
    int slot(const std::string &id) const {
        auto it=std::find(ids.begin(),ids.end(),id);
        return it==ids.end()?-1:static_cast<int>(it-ids.begin());
    }
};
inline GeologyPalette compile_geology(const Snapshot &s,const std::string &id) {
    const auto found=s.indices.find(id);
    require(found!=s.indices.end(),"geology profile absent");
    const auto &p=s.records[found->second];
    require(p.type=="geology_profile" && p.data.contains("palette"),"profile not V3.2");
    GeologyPalette out{id,{},p.data};
    out.config["materials"]=Json::array();
    for(const auto &v:p.data.at("palette")) {
        const auto mid=str(v);
        const auto &m=s.records.at(s.indices.at(mid));
        require(m.type=="material" && m.data.contains("albedo") && m.data.contains("roughness"),
                "geology requires complete material definition");
        out.ids.push_back(mid);
        out.config["materials"].push_back({{"id",mid},{"data",m.data}});
    }
    return out;
}
}
