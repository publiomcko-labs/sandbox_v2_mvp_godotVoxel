#pragma once
#include "fluids.hpp"

namespace sandbox::fluid {
// Cache immutable SDF corner classifications, never streaming residency.
// Only the engine main thread calls this adapter. Edits invalidate their
// affected block bounds before the next round, including shared corners.
class ProbeCache {
    static constexpr int side=4;
    static constexpr std::size_t block_limit=2048;
    struct Block {std::array<std::uint8_t,125> corners{};};
    std::map<Cell,Block> blocks_;
    std::map<Cell,bool> ready_;
    std::size_t reads_{},checks_{},hits_{},deferred_{};
    std::size_t read_limit_=128,check_limit_=48;
    static int axis(int v){return (v>=0?v/side:(v-side+1)/side)*side;}
    static Cell origin(Cell p){return {axis(p.x),axis(p.y),axis(p.z)};}
public:
    void begin(std::size_t read_limit=128,std::size_t check_limit=48) {
        ready_.clear();reads_=checks_=hits_=deferred_=0;
        read_limit_=read_limit;check_limit_=check_limit;
    }
    std::size_t reads() const{return reads_;}
    std::size_t checks() const{return checks_;}
    std::size_t hits() const{return hits_;}
    std::size_t deferred() const{return deferred_;}
    void invalidate(Cell lo,Cell hi) {
        // Each cached block contains its positive boundary corner as well.
        const auto a=origin(plus(lo,{-1,-1,-1})),b=origin(hi);
        for(int x=a.x;x<=b.x;x+=side)
            for(int y=a.y;y<=b.y;y+=side)
                for(int z=a.z;z<=b.z;z+=side)blocks_.erase({x,y,z});
        ready_.clear();
    }
    template<class Ready,class Sample,class Fallback>
    Passage probe(Cell p,Ready ready,Sample sample,Fallback fallback) {
        if(!valid(p))return Passage::unavailable;
        const auto base=origin(p);
        auto r=ready_.find(base);
        if(r==ready_.end()) {
            if(checks_>=check_limit_){++deferred_;return Passage::unavailable;}
            ++checks_;r=ready_.emplace(base,ready(base)).first;
        }
        if(!r->second) {
            // Near a streaming boundary a cell may still be editable even
            // if the whole block is not. Never reuse a cached SDF there.
            if(checks_>=check_limit_||reads_+8>read_limit_){++deferred_;return Passage::unavailable;}
            ++checks_;reads_+=8;
            return fallback(p);
        }
        auto it=blocks_.find(base);
        if(it==blocks_.end()) {
            if(blocks_.size()>=block_limit)blocks_.erase(blocks_.begin());
            it=blocks_.emplace(base,Block{}).first;
        }
        auto &corners=it->second.corners;
        const int dx=p.x-base.x,dy=p.y-base.y,dz=p.z-base.z;
        for(int x=0;x<=1;++x)for(int y=0;y<=1;++y)for(int z=0;z<=1;++z) {
            auto &v=corners[static_cast<std::size_t>(((dz+z)*5+dy+y)*5+dx+x)];
            if(!v) {
                if(reads_>=read_limit_){++deferred_;return Passage::unavailable;}
                ++reads_;v=sample(plus(p,{x,y,z}))?2:1;
            }else ++hits_;
            if(v==1)return Passage::solid;
        }
        return Passage::open;
    }
};
}
