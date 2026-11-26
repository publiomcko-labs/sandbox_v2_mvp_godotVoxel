#pragma once
#include "hydraulic_store.hpp"
#include "core/hydraulic_domain.hpp"
namespace sandbox::persistence {
inline constexpr std::size_t hydraulic_archive_limit=16*1024*1024;
inline Json encode_domain(const hy::Domain &d) {
    Json tiles=Json::array(),oceans=Json::array();
    for(const auto &[key,t]:d.tiles()) {
        const auto &g=*t.geometry;
        Json runs=Json::array(),wet=Json::array();
        for(const auto &column:g.column_runs)for(const auto &s:column)
            runs.push_back({s.x,s.z,s.bottom,s.top});
        for(const auto &[local,id]:t.ids) {
            const auto &v=d.graph().volumes().at(id);
            if(v.litres)wet.push_back({local,d.graph().types().at(v.type).id,v.litres});
        }
        tiles.push_back({{"origin",{key.x,key.y,key.z}},{"revision",g.revision},{"runs",runs},{"wet",wet}});
    }
    for(const auto &[id,o]:d.oceans()) {
        const auto &v=d.graph().volumes().at(o.ocean);
        oceans.push_back({{"id",id},{"anchor",{o.anchor.x,o.anchor.y,o.anchor.z}},
            {"type",d.graph().types().at(v.type).id},{"level",v.ocean_level},{"area",o.area}});
    }
    return {{"schema",1},{"initial",d.graph().initial()},{"injected",d.graph().injected()},
        {"drained",d.graph().drained()},{"tiles",tiles},{"oceans",oceans},{"seeded",d.seeded()}};
}
inline hy::Domain decode_domain(const Json &j,const std::vector<hy::Liquid> &types) {
    content::fields(j,{"schema","initial","injected","drained","tiles","oceans","seeded"});
    require(j.at("schema")==1&&j.at("tiles").is_array()&&j.at("tiles").size()<=256&&
        j.at("oceans").is_array()&&j.at("oceans").size()<=64&&j.at("seeded").is_array()&&j.at("seeded").size()<=64,"hydraulic domain schema");
    hy::Domain d(types);
    auto integer=[](const Json &v,int lo,int hi){return static_cast<int>(hydraulic_integer(v,lo,hi));};
    auto slot=[&](const Json &v){const auto id=content::str(v);auto it=std::find_if(types.begin(),types.end(),[&](const auto &t){return t.id==id;});
        require(it!=types.end(),"hydraulic type absent");return static_cast<std::size_t>(it-types.begin());};
    for(const auto &t:j.at("tiles")) {
        content::fields(t,{"origin","revision","runs","wet"});
        const auto &o=t.at("origin");require(o.is_array()&&o.size()==3,"tile origin");
        sandbox::core::Region key{integer(o[0],-1000000,1000000),integer(o[1],-32,-32),integer(o[2],-1000000,1000000)};
        require(!d.tiles().contains(key),"duplicate tile");
        hy::tp::Snapshot s{key,16,64,16,1,uint(t.at("revision")),std::vector<std::uint8_t>(16*64*16)};
        require(t.at("runs").is_array()&&t.at("runs").size()<=16384&&t.at("wet").is_array()&&t.at("wet").size()<=4096,"tile rows");
        for(const auto &r:t.at("runs")) {
            require(r.is_array()&&r.size()==4,"span row");
            const int x=integer(r[0],0,15),z=integer(r[1],0,15),lo=integer(r[2],0,63),hi=integer(r[3],lo+1,64);
            for(int y=lo;y<hi;++y) {
                auto &v=s.air[static_cast<std::size_t>((z*16+x)*64+y)];
                require(!v,"duplicate span");v=1;
            }
        }
        require(d.publish(hy::tp::extract(s)),"restore tile");
        for(const auto &r:t.at("wet")) {
            require(r.is_array()&&r.size()==3,"wet row");
            require(d.restore_content(key,static_cast<hy::Id>(hydraulic_integer(r[0],1,16384)),slot(r[1]),
                hydraulic_integer(r[2],1,hy::volume_limit)),"restore wet body");
        }
    }
    for(const auto &o:j.at("oceans")) {
        content::fields(o,{"id","anchor","type","level","area"});
        const auto &p=o.at("anchor");require(p.is_array()&&p.size()==3,"ocean anchor");
        require(d.add_ocean(content::str(o.at("id")),{hydraulic_number(p[0]),hydraulic_number(p[1]),hydraulic_number(p[2])},
            slot(o.at("type")),hydraulic_number(o.at("level")),hydraulic_number(o.at("area")),true),"restore ocean");
    }
    for(const auto &id:j.at("seeded"))d.restore_seeded(content::str(id));
    d.restore_ledger(hydraulic_integer(j.at("initial"),0,hy::ledger_limit),
        hydraulic_integer(j.at("injected"),0,hy::ledger_limit),hydraulic_integer(j.at("drained"),0,hy::ledger_limit));
    // Snapshot residency is never restored. Keep old geometry for remap.
    for(const auto &[key,t]:d.tiles())d.invalidate(key,t.geometry->revision);
    return d;
}
inline void save_domain(const fs::path &world,const hy::Domain &d) {
    const auto tmp=world/"session_pending"/"hydraulic_domain.tmp";
    const auto bytes=encode_domain(d).dump();
    require(bytes.size()<=hydraulic_archive_limit&&!fs::exists(fs::symlink_status(tmp)),"hydraulic archive bounds");
    std::ofstream out(tmp,std::ios::binary);require(bool(out),"hydraulic open");
    out.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));out.flush();require(bool(out),"hydraulic write");
    out.close();require(bool(out),"hydraulic close");replace_file(tmp,world/"hydraulic_domain.json");
}
inline hy::Domain load_domain(const fs::path &world,const std::vector<hy::Liquid> &types) {
    const auto p=world/"hydraulic_domain.json";plain_unique_file(p);
    const auto n=fs::file_size(p);require(n<=hydraulic_archive_limit,"hydraulic archive limit");
    std::ifstream in(p,std::ios::binary);std::string bytes(static_cast<std::size_t>(n),'\0');
    in.read(bytes.data(),static_cast<std::streamsize>(n));require(bool(in),"hydraulic read");
    return decode_domain(content::strict_json(bytes),types);
}
}
