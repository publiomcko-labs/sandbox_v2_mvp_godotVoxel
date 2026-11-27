#pragma once
#include "world_core.hpp"
#include <set>
#include <map>
#include <cstdint>
#include <nlohmann/json.hpp>
namespace sandbox::hydraulic {
// Only edit provenance, never terrain. A missing entry is evidence of
// pristine terrain ONLY while every accepted revision is accounted for.
class EditProvenance {
    bool complete_=true;
    std::uint64_t revision_=0;
    std::map<core::Region,std::uint64_t> edited_;
    static constexpr std::size_t limit=65536;
    static bool key_valid(core::Region k){return k.y==-32&&k.x%16==0&&k.z%16==0&&
        std::abs(static_cast<std::int64_t>(k.x))<=1000016&&std::abs(static_cast<std::int64_t>(k.z))<=1000016;}
public:
    bool complete()const{return complete_;}
    std::size_t size()const{return edited_.size();}
    std::uint64_t revision()const{return revision_;}
    bool pristine(core::Region k,std::uint64_t world_revision)const{
        return complete_&&revision_==world_revision&&key_valid(k)&&!edited_.contains(k);
    }
    bool certifies(core::Region k,std::uint64_t geometry_revision,std::uint64_t world_revision)const{
        if(!complete_||revision_!=world_revision||geometry_revision>world_revision||!key_valid(k))return false;
        const auto it=edited_.find(k);
        return it==edited_.end()||geometry_revision>=it->second;
    }
    void invalidate(std::uint64_t revision){complete_=false;revision_=revision;edited_.clear();}
    void record(std::uint64_t revision,const std::set<core::Region>& keys){
        if(!complete_||revision_==UINT64_MAX||revision!=revision_+1||keys.empty()){
            invalidate(revision);return;
        }
        for(auto k:keys){
            if(!key_valid(k)){invalidate(revision);return;}
            edited_[k]=revision;
            if(edited_.size()>limit){invalidate(revision);return;}
        }
        revision_=revision;
    }
    nlohmann::json encode()const{
        nlohmann::json rows=nlohmann::json::array();
        for(const auto &[k,r]:edited_)rows.push_back({k.x,k.y,k.z,r});
        return {{"complete",complete_},{"revision",revision_},{"tiles",rows}};
    }
    static EditProvenance decode(const nlohmann::json& j,std::uint64_t expected){
        EditProvenance out;
        if(j.is_null()){if(expected)out.invalidate(expected);return out;}
        if(!j.is_object()||!j.at("complete").is_boolean()||!j.at("revision").is_number_unsigned()||
            j.at("revision").get<std::uint64_t>()!=expected||!j.at("tiles").is_array()||j.at("tiles").size()>limit)
            throw std::invalid_argument("hydraulic provenance archive");
        out.revision_=expected;out.complete_=j.at("complete").get<bool>();
        if(!out.complete_&&!j.at("tiles").empty())throw std::invalid_argument("incomplete provenance rows");
        for(const auto &row:j.at("tiles")){
            if(!row.is_array()||row.size()!=4||!row[3].is_number_unsigned())throw std::invalid_argument("provenance row");
            core::Region k{row[0].get<int>(),row[1].get<int>(),row[2].get<int>()};
            auto r=row[3].get<std::uint64_t>();
            if(!key_valid(k)||!r||r>expected||!out.edited_.emplace(k,r).second)throw std::invalid_argument("provenance tile");
        }
        if(out.complete_&&expected&&out.edited_.empty())throw std::invalid_argument("missing edited provenance");
        return out;
    }
};
}
