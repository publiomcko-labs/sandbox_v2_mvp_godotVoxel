#pragma once
#include "core/hydraulic_topology.hpp"
#include <godot_cpp/classes/voxel_buffer.hpp>
#include <godot_cpp/classes/voxel_tool.hpp>
#include <godot_cpp/classes/voxel_stream.hpp>
#include <godot_cpp/classes/voxel_generator.hpp>
#include <godot_cpp/classes/voxel_format.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <cstring>

namespace sandbox::hydraulic {
namespace tp=topology;
// Same quantized SDF operation used by the authoritative material brush.
struct BrushPreview {godot::Vector3 center;double radius;bool add;};
inline double brush_sdf(const godot::Vector3& point,const BrushPreview& brush,double old){
    const double shape=point.distance_to(brush.center)-brush.radius;
    if(shape>1)return old;
    return brush.add?std::min(old,shape):std::max(old,-shape);
}
// Shared classification for live VoxelTool copies and authoritative stream blocks.
inline tp::Snapshot classify_air_buffer(const godot::Ref<godot::VoxelBuffer>& buffer,
        godot::Vector3i origin,godot::Vector3i extent,std::uint64_t revision,bool render,int pad) {
    using namespace godot;
    const auto core_size=extent+Vector3i(1,1,1),size=buffer->get_size();
    const bool halo=pad==1;
    tp::Snapshot snapshot{{origin.x,origin.y,origin.z},extent.x,extent.y,extent.z,1,revision,{}};
    snapshot.air.resize(static_cast<std::size_t>(extent.x*extent.y*extent.z));
    // Each corner is classified once; reuse between adjacent samples.
    std::vector<std::uint8_t> corners(static_cast<std::size_t>(size.x*size.y*size.z));
    if(render){snapshot.render_pad=pad;snapshot.render_sdf.resize(corners.size());}
    auto index=[&](int x,int y,int z){return static_cast<std::size_t>((z*size.x+x)*size.y+y);};
    // Locked Voxel Tools v1.7 (2ac9f5f): dense CHANNEL_SDF uses
    // Z/X/Y layout and signed normalized 16-bit samples, scale 0.002f.
    // One channel copy avoids 23k GDExtension calls per halo tile.
    // Preserve the original API for other channel depths and H14.
    PackedByteArray raw;
    if(render&&buffer->get_channel_depth(VoxelBuffer::CHANNEL_SDF)==VoxelBuffer::DEPTH_16_BIT)
        raw=buffer->get_channel_as_byte_array(VoxelBuffer::CHANNEL_SDF);
    bool bulk=static_cast<std::size_t>(raw.size())==corners.size()*sizeof(std::int16_t);
    auto decode=[&](std::size_t i)->double {
        std::int16_t value{};
        std::memcpy(&value,raw.ptr()+i*sizeof(value),sizeof(value));
        return std::max(static_cast<float>(value)/32767.f,-1.f)*(1.f/0.002f);
    };
    // Guard ABI/format/layout drift against the authoritative engine API.
    if(bulk)for(const auto &p:{Vector3i(0,0,0),Vector3i(size.x-1,size.y-1,size.z-1),
            Vector3i(size.x/2,size.y/2,size.z/2),Vector3i(size.x-1,size.y/3,0),Vector3i(0,size.y/2,size.z-1)})
        if(decode(index(p.x,p.y,p.z))!=buffer->get_voxel_f(p.x,p.y,p.z,VoxelBuffer::CHANNEL_SDF)){bulk=false;break;}
    std::vector<float> floors(static_cast<std::size_t>(size.x*size.z));
    for(int z=0;z<size.z;++z)for(int x=0;x<size.x;++x) {
        double previous=0.0;
        double floor=origin.y;
        for(int y=0;y<size.y;++y) {
            const double sdf=bulk?decode(index(x,y,z)):buffer->get_voxel_f(x,y,z,VoxelBuffer::CHANNEL_SDF);
            corners[index(x,y,z)]=sdf>0.1?1:0;
            if(render)snapshot.render_sdf[index(x,y,z)]=static_cast<std::int16_t>(std::lround(std::clamp(sdf,-4.0,4.0)*1024));
            if(y&&previous<=0.0&&sdf>0.0)
                floor=origin.y+y-1+std::clamp(-previous/(sdf-previous),0.0,1.0);
            previous=sdf;
        }
        if(previous<=0.0)floor=origin.y+extent.y;
        floors[static_cast<std::size_t>(z*size.x+x)]=static_cast<float>(floor);
    }
    snapshot.refine_exposed=true;
    snapshot.surface_floor.resize(static_cast<std::size_t>(core_size.x*core_size.z));
    for(int z=0;z<core_size.z;++z)for(int x=0;x<core_size.x;++x)
        snapshot.surface_floor[static_cast<std::size_t>(z*core_size.x+x)]=floors[static_cast<std::size_t>((z+pad)*size.x+x+pad)];
    if(halo) {
        snapshot.halo_floor=std::move(floors);
        snapshot.halo_air.resize(static_cast<std::size_t>((extent.x+2)*(extent.z+2)*extent.y));
    }
    for(int z=-pad;z<extent.z+pad;++z)for(int x=-pad;x<extent.x+pad;++x)for(int y=0;y<extent.y;++y) {
        bool open=true;
        for(int dx=0;dx<=1;++dx)for(int dy=0;dy<=1;++dy)for(int dz=0;dz<=1;++dz)
            open=open&&corners[index(x+pad+dx,y+dy,z+pad+dz)]!=0;
        if(x>=0&&x<extent.x&&z>=0&&z<extent.z)
            snapshot.air[static_cast<std::size_t>((z*extent.x+x)*extent.y+y)]=open?1:0;
        else snapshot.halo_air[static_cast<std::size_t>(((z+1)*(extent.x+2)+x+1)*extent.y+y)]=open?1:0;
    }
    return snapshot;
}
// A certificate for the saved Voxel Tools stream, not an alternate terrain store.
// A NOT_FOUND block is pristine in this flushed, revision-matched stream;
// errors never fall back to generation.
struct StreamSnapshotSource {
    godot::Ref<godot::VoxelStream> stream;
    godot::Ref<godot::VoxelGenerator> generator;
    godot::Ref<godot::VoxelFormat> format;
    int block_size{};
    std::uint64_t durable_revision{};
    bool valid()const{return stream.is_valid()&&generator.is_valid()&&format.is_valid()&&
        block_size>=8&&block_size<=64&&(block_size&(block_size-1))==0;}
};
struct StreamSnapshotStats {std::uint64_t found{},generated{};};
inline std::optional<tp::Snapshot> copy_stream_snapshot(const StreamSnapshotSource& source,
        godot::Vector3i origin,godot::Vector3i extent,std::uint64_t revision,StreamSnapshotStats* stats=nullptr) {
    using namespace godot;
    if(!source.valid()||revision>source.durable_revision||extent.x<1||extent.x>16||
        extent.z<1||extent.z>16||extent.y<1||extent.y>64||
        std::abs(std::int64_t(origin.x))>1000000||std::abs(std::int64_t(origin.y))>98000||
        std::abs(std::int64_t(origin.z))>1000000)return {};
    const int n=source.block_size;
    const auto lo=origin-Vector3i(1,0,1),size=extent+Vector3i(3,1,3),hi=lo+size;
    auto floor_block=[&](int v){return v>=0?v/n:(v-n+1)/n;};
    auto create=[&](Vector3i dims){
        Ref<VoxelBuffer> out;out.instantiate();
        for(int i=0;i<VoxelBuffer::MAX_CHANNELS;++i)
            out->set_channel_depth(i,source.format->get_channel_depth(static_cast<VoxelBuffer::ChannelId>(i)));
        out->create(dims.x,dims.y,dims.z);return out;
    };
    auto buffer=create(size);
    StreamSnapshotStats counts;
    for(int z=floor_block(lo.z);z<=floor_block(hi.z-1);++z)
        for(int x=floor_block(lo.x);x<=floor_block(hi.x-1);++x)
            for(int y=floor_block(lo.y);y<=floor_block(hi.y-1);++y){
                auto block=create(Vector3i(n,n,n));
                const Vector3i bp(x,y,z),bo(x*n,y*n,z*n),end=bo+Vector3i(n,n,n);
                const auto result=source.stream->load_voxel_block(block,bp,0);
                if(result==VoxelStream::RESULT_BLOCK_FOUND)++counts.found;
                else if(result==VoxelStream::RESULT_BLOCK_NOT_FOUND){
                    source.generator->generate_block(block,Vector3(bo),0);++counts.generated;
                }else return {};
                if(block->get_size()!=Vector3i(n,n,n)||
                    block->get_channel_depth(VoxelBuffer::CHANNEL_SDF)!=buffer->get_channel_depth(VoxelBuffer::CHANNEL_SDF))return {};
                const Vector3i a(std::max(lo.x,bo.x),std::max(lo.y,bo.y),std::max(lo.z,bo.z));
                const Vector3i b(std::min(hi.x,end.x),std::min(hi.y,end.y),std::min(hi.z,end.z));
                buffer->copy_channel_from_area(block,a-bo,b-bo,a-lo,VoxelBuffer::CHANNEL_SDF);
            }
    if(stats)*stats=counts;
    return classify_air_buffer(buffer,origin,extent,revision,true,1);
}
// Must be called on the engine main thread. The returned snapshot owns
// plain C++ data only, suitable for off-thread topology extraction later.
// It is a geometric classification, not an additional terrain store.
inline std::optional<tp::Snapshot> copy_air_snapshot(const godot::Ref<godot::VoxelTool>& tool,
        godot::Vector3i origin,godot::Vector3i extent,std::uint64_t revision,bool render=false,bool pristine_survey=false,const BrushPreview* preview=nullptr) {
    using namespace godot;
    if(extent.x<1||extent.x>16||extent.z<1||extent.z>16||extent.y<1||extent.y>64||
        std::abs(std::int64_t(origin.x))>1000000||std::abs(std::int64_t(origin.y))>98000||
        std::abs(std::int64_t(origin.z))>1000000)
        throw std::invalid_argument("hydraulic voxel snapshot bounds");
    const auto core_size=extent+Vector3i(1,1,1);
    // VoxelData::copy falls back to the same generator outside loaded
    // blocks. Its fallback is NOT safe for a world with accepted edits:
    // unloaded edited blocks might be absent from memory.
    if(pristine_survey&&(!render||revision!=0))throw std::invalid_argument("pristine hydraulic survey revision");
    if(tool.is_null()||(!pristine_survey&&!tool->is_area_editable(AABB(Vector3(origin),Vector3(core_size)))))return {};
    const auto halo_origin=origin-Vector3i(1,0,1),halo_size=extent+Vector3i(3,1,3);
    const bool halo=pristine_survey||tool->is_area_editable(AABB(Vector3(halo_origin),Vector3(halo_size)));
    const int pad=halo?1:0;
    const auto size=halo?halo_size:core_size;
    Ref<VoxelBuffer> buffer;buffer.instantiate();buffer->create(size.x,size.y,size.z);
    const auto copy_origin=halo?halo_origin:origin;
    tool->copy(copy_origin,buffer,1<<VoxelBuffer::CHANNEL_SDF,false);
    if(preview){
        if(pristine_survey)throw std::invalid_argument("preview requires authoritative resident data");
        for(int z=0;z<size.z;++z)for(int x=0;x<size.x;++x)for(int y=0;y<size.y;++y){
            const double old=buffer->get_voxel_f(x,y,z,VoxelBuffer::CHANNEL_SDF);
            const double next=brush_sdf(Vector3(copy_origin+Vector3i(x,y,z)),*preview,old);
            if(next!=old)buffer->set_voxel_f(next,x,y,z,VoxelBuffer::CHANNEL_SDF);
        }
    }
    return classify_air_buffer(buffer,origin,extent,revision,render,pad);
}
}