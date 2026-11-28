#pragma once
#include "hydraulic_domain_store.hpp"
#include "../content_registry/sha256.hpp"
#include <array>
#include <chrono>

namespace sandbox::persistence {
// Disk-backed cold hydraulic ownership. The existing exclusive session intent
// remains the crash gate; no separate terrain authority is introduced.
// The on-disk summary is checked at clean reopen, not a world-size RAM index.
class HydraulicRegionStore {
    fs::path root_,pending_;
    std::uint64_t count_{};
    hy::Litres mass_{};
    mutable bool poisoned_=false;
    struct Cost {
        std::uint64_t count{},total_us{},max_us{},bytes{};
        std::array<std::uint64_t,32> bins{};
        void add(std::uint64_t us,std::uint64_t n) {
            ++count;total_us+=us;max_us=std::max(max_us,us);bytes+=n;
            std::size_t b=0;std::uint64_t upper=1;
            while(b+1<bins.size()&&upper<us){upper<<=1;++b;}
            ++bins[b];
        }
        std::uint64_t p95_upper_us()const {
            if(!count)return 0;
            const auto need=(count*95+99)/100;std::uint64_t total=0;
            for(std::size_t i=0;i<bins.size();++i){total+=bins[i];if(total>=need)return std::uint64_t(1)<<i;}
            return std::uint64_t(1)<<31;
        }
    };
    mutable Cost reads_,erases_;
    Cost writes_;
    static std::uint64_t us_since(std::chrono::steady_clock::time_point start) {
        return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now()-start).count());
    }
    static fs::path filename(core::Region k) {
        require(k.y==-32&&k.x%16==0&&k.z%16==0&&
            std::abs(static_cast<std::int64_t>(k.x))<=1000016&&
            std::abs(static_cast<std::int64_t>(k.z))<=1000016,"cold region key");
        return "r_"+std::to_string(k.x)+"_"+std::to_string(k.z)+".json";
    }
    static Json read(const fs::path& p) {
        plain_unique_file(p);
        const auto n=fs::file_size(p);
        require(n<=hydraulic_archive_limit,"cold record bytes");
        std::ifstream in(p,std::ios::binary);
        require(bool(in),"cold record open");
        std::string bytes(static_cast<std::size_t>(n),'\0');
        in.read(bytes.data(),static_cast<std::streamsize>(n));
        require(static_cast<std::uintmax_t>(in.gcount())==n&&in.peek()==EOF,"cold record read");
        return content::strict_json(bytes);
    }
    void write(const fs::path& dst,const Json& data) {
        const auto tmp=pending_/"hydraulic_region.tmp";
        const auto bytes=data.dump();
        require(bytes.size()<=hydraulic_archive_limit&&!fs::exists(fs::symlink_status(tmp)),"cold record write bounds");
        std::ofstream out(tmp,std::ios::binary);
        require(bool(out),"cold record output");
        out.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));
        out.flush();require(bool(out),"cold record flush");
        out.close();require(bool(out),"cold record close");
        replace_file(tmp,dst);
    }
    static hy::Litres record_mass(const Json& row) {
        require(row.at("content").is_array()&&row.at("content").size()<=16384,"cold owner content");
        hy::Litres amount=0;
        for(const auto &v:row.at("content")){
            require(v.is_array()&&v.size()==3,"cold owner content row");
            amount+=hydraulic_integer(v.at(2),1,hy::volume_limit);
            require(amount<=hy::volume_limit,"cold owner mass bounds");
        }
        return amount;
    }
public:
    HydraulicRegionStore(const fs::path& world,std::uint64_t count,hy::Litres mass):count_(count),mass_(mass) {
        const auto base=content::checked_root(world);
        pending_=content::checked_root(base/"session_pending");
        const auto root=base/"hydraulic_regions";
        if(!fs::exists(fs::symlink_status(root))){
            require(!count&&!mass&&fs::create_directory(root),"missing cold region store");
        }
        root_=content::checked_root(root);
        require(content::contained(base,root_),"cold store path escaped");
        const auto summary=root_/"ledger.json";
        if(fs::exists(fs::symlink_status(summary))){
            const auto j=read(summary);
            require(j.at("schema")=="hydraulic-cold-ledger-1"&&uint(j.at("count"))==count&&
                hydraulic_integer(j.at("mass"),0,2*hy::ledger_limit)==mass,"cold ledger mismatch");
        }else require(!count&&!mass&&fs::is_empty(root_),"missing cold ledger");
    }
    bool contains(core::Region k)const {
        require(!poisoned_,"cold store poisoned");
        const auto p=root_/filename(k);
        if(!fs::exists(fs::symlink_status(p)))return false;
        plain_unique_file(p);return true;
    }
    bool consistent(std::uint64_t count,hy::Litres mass)const{return !poisoned_&&count_==count&&mass_==mass;}
    void poison(){poisoned_=true;}
    void put(core::Region k,const Json& geometry,const Json& owner,hy::Litres amount) {
        require(!poisoned_&&!contains(k)&&amount==record_mass(owner)&&amount>=0&&
            mass_<=2*hy::ledger_limit-amount&&count_<std::numeric_limits<std::uint64_t>::max(),"cold duplicate or invalid owner");
        const Json key={k.x,k.y,k.z};
        require(owner.at("tile")==key&&geometry.at("key")==key&&owner.at("revision")==geometry.at("revision")&&
            !owner.at("resident").get<bool>(),"cold owner identity");
        try{
            const auto start=std::chrono::steady_clock::now();
            Json record={{"schema","hydraulic-cold-region-2"},{"mass",amount},{"geometry",geometry},{"owner",owner}};
            record["sha256"]=content::sha256(record.dump());
            const auto bytes=record.dump().size();
            write(root_/filename(k),record);
            ++count_;mass_+=amount;
            writes_.add(us_since(start),bytes);
        }catch(...){poison();throw;}
    }
    Json get(core::Region k)const {
        const auto start=std::chrono::steady_clock::now();
        try {
            require(contains(k),"missing cold record");
            const auto path=root_/filename(k);
            const auto j=read(path);
            const auto schema=j.at("schema");
            require(schema=="hydraulic-cold-region-1"||schema=="hydraulic-cold-region-2","cold record schema");
            if(schema=="hydraulic-cold-region-2"){
                const auto digest=j.at("sha256").get<std::string>();
                require(digest.size()==64,"cold digest size");
                auto validated=j;validated.erase("sha256");
                require(content::sha256(validated.dump())==digest,"cold record digest mismatch");
            }
            const Json key={k.x,k.y,k.z};
            const auto &owner=j.at("owner"),&geometry=j.at("geometry");
            require(owner.at("tile")==key&&geometry.at("key")==key&&
                owner.at("revision")==geometry.at("revision")&&!owner.at("resident").get<bool>()&&
                hydraulic_integer(j.at("mass"),0,hy::volume_limit)==record_mass(owner),"cold record integrity");
            reads_.add(us_since(start),fs::file_size(path));
            return j;
        }catch(...){poisoned_=true;throw;}
    }
    void erase(core::Region k,hy::Litres amount) {
        try {
            const auto start=std::chrono::steady_clock::now();
            const auto record=get(k);
            require(count_&&amount>=0&&amount<=mass_&&record.at("mass").get<hy::Litres>()==amount,"cold removal mismatch");
            require(fs::remove(root_/filename(k)),"cold removal failed");
            --count_;mass_-=amount;
            erases_.add(us_since(start),0);
        }catch(...){poison();throw;}
    }
    Json metrics()const {
        return {{"read_count",reads_.count},{"read_total_us",reads_.total_us},{"read_max_us",reads_.max_us},
            {"read_p95_upper_us",reads_.p95_upper_us()},{"read_bytes",reads_.bytes},
            {"write_count",writes_.count},{"write_total_us",writes_.total_us},{"write_max_us",writes_.max_us},
            {"write_p95_upper_us",writes_.p95_upper_us()},{"write_bytes",writes_.bytes},
            {"erase_count",erases_.count},{"erase_total_us",erases_.total_us},{"erase_max_us",erases_.max_us}};
    }
    void checkpoint(std::uint64_t count,hy::Litres mass) {
        require(consistent(count,mass),"cold checkpoint ledger mismatch");
        try{write(root_/"ledger.json",{{"schema","hydraulic-cold-ledger-1"},{"count",count},{"mass",mass}});}
        catch(...){poison();throw;}
    }
};
}
