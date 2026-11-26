#pragma once
#include "manifest.hpp"
#include "sha256.hpp"
#include <cstdint>
#include <stdexcept>
#include <string>

namespace sandbox::content {
// Stable, domain-separated seed; no global RNG or traversal order.
inline std::uint64_t composed_seed(std::uint64_t world_seed, std::string_view id,
        std::int32_t x, std::int32_t y, std::int32_t z, std::string_view generator) {
    if (!content_id(id) || generator.empty() || generator.size()>128 ||
        generator.find('\n')!=std::string_view::npos || generator.find('\r')!=std::string_view::npos)
        throw std::invalid_argument("invalid seed domain");
    const auto input=std::string("sandbox_seed_v1\n")+std::to_string(world_seed)+"\n"+
        std::string(id)+"\n"+std::to_string(x)+"\n"+std::to_string(y)+"\n"+
        std::to_string(z)+"\n"+std::string(generator);
    const auto hex=sha256(input);
    std::uint64_t result=0;
    for (std::size_t i=0;i<16;++i) {
        const char c=hex[i];
        result=(result<<4)|static_cast<std::uint64_t>(c<='9'?c-'0':c-'a'+10);
    }
    return result;
}
}
