#pragma once
#include "checkpoint.hpp"
#include "core/fluids.hpp"

namespace sandbox::persistence {
namespace fl=sandbox::fluid;
inline constexpr std::size_t fluid_file_limit=8*1024*1024;
inline void save_fluid(const fs::path &world,const fl::Solver &s,const std::set<std::string>& seeded) {
    Json rows=Json::array();
    for(auto [p,a]:s.cells())rows.push_back({p.x,p.y,p.z,a.type,a.litres});
    const auto bytes=Json{{"schema",1},{"initial",s.initial()},{"injected",s.injected()},
        {"drained",s.drained()},{"seeded",seeded},{"cells",rows}}.dump();
    require(bytes.size()<=fluid_file_limit,"fluid file limit");
    const auto tmp=world/"session_pending"/"fluid.tmp";
    require(!fs::exists(fs::symlink_status(tmp)),"fluid temp exists");
    std::ofstream out(tmp,std::ios::binary);
    require(bool(out),"fluid save open");out.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));out.flush();
    require(bool(out),"fluid save write");out.close();require(bool(out),"fluid save close");
    replace_file(tmp,world/"fluids.json");
}
inline std::set<std::string> load_fluid(const fs::path &world,fl::Solver &s,const Json &config) {
    const auto path=world/"fluids.json";
    plain_unique_file(path);
    const auto n=fs::file_size(path);require(n<=fluid_file_limit,"fluid file limit");
    std::ifstream in(path,std::ios::binary);
    require(bool(in),"fluid load open");
    std::string bytes(static_cast<std::size_t>(n),'\0');
    in.read(bytes.data(),static_cast<std::streamsize>(n));require(bool(in),"fluid load read");
    const auto j=content::strict_json(bytes);
    content::fields(j,{"schema","initial","injected","drained","seeded","cells"});
    require(j.at("schema")==1 && j.at("cells").is_array() && j.at("cells").size()<=fl::cell_limit,"fluid schema");
    std::set<std::string> seeded;
    require(j.at("seeded").is_array()&&j.at("seeded").size()<=16,"seeded reservoir limit");
    for(const auto &v:j.at("seeded")) {
        auto id=content::str(v);bool found=false;
        for(const auto &r:config.at("reservoirs"))if(content::str(r.at("id"))==id)found=true;
        require(found&&seeded.insert(id).second,"unknown or duplicate reservoir");
    }
    std::map<fl::Cell,fl::Amount> cells;
    for(const auto &r:j.at("cells")) {
        require(r.is_array()&&r.size()==5,"fluid row");
        for(const auto &v:r)require(v.is_number_integer()&&std::abs(v.get<double>())<=1000000,"fluid row integer");
        fl::Cell p{r[0].get<int>(),r[1].get<int>(),r[2].get<int>()};
        require(cells.emplace(p,fl::Amount{r[3].get<int>(),r[4].get<int>()}).second,"duplicate fluid cell");
    }
    s.restore(cells,uint(j.at("initial")),uint(j.at("injected")),uint(j.at("drained")));
    return seeded;
}
}
