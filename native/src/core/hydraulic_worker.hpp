#pragma once
#include "hydraulic_topology.hpp"
#include <future>
#include <chrono>

namespace sandbox::hydraulic::topology {
// One in-flight immutable snapshot and bounded pending queue; no engine API
// from worker threads. The owner polls and only publishes current revisions.
class Worker {
    static constexpr std::size_t pending_limit=8;
    std::map<core::Region,Snapshot> pending_;
    std::map<core::Region,std::uint64_t> requested_;
    std::optional<std::future<Result>> running_;
    std::optional<core::Region> active_;
    void launch() {
        if(running_||pending_.empty())return;
        auto it=pending_.begin();
        auto snapshot=std::move(it->second);
        active_=it->first;pending_.erase(it);
        running_.emplace(std::async(std::launch::async,[s=std::move(snapshot)](){return extract(s);}));
    }
public:
    bool submit(Snapshot snapshot) {
        const auto key=snapshot.origin;
        const auto it=requested_.find(key);
        if(it!=requested_.end()&&snapshot.revision<=it->second)return false;
        if(!pending_.contains(key)&&pending_.size()>=pending_limit)return false;
        requested_[key]=snapshot.revision;
        pending_.insert_or_assign(key,std::move(snapshot));launch();return true;
    }
    void invalidate(core::Region key) {
        pending_.erase(key);requested_.erase(key);
    }
    bool busy()const{return running_.has_value()||!pending_.empty();}
    std::optional<Result> poll() {
        if(!running_) {launch();return {};}
        if(running_->wait_for(std::chrono::seconds(0))!=std::future_status::ready)return {};
        auto future=std::move(*running_);running_.reset();
        const auto key=*active_;active_.reset();
        try {
            auto result=future.get();
            const auto current=requested_.find(key);
            const bool valid=current!=requested_.end()&&current->second==result.revision;
            if(valid)requested_.erase(current);
            launch();
            if(valid)return result;
        }catch(...) {
            if(!pending_.contains(key))requested_.erase(key);
            launch();throw;
        }
        return {};
    }
};
}
