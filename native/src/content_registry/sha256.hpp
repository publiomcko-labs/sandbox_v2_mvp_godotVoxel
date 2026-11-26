#pragma once
#include <array>
#include <stdexcept>
#include <string>
#include <string_view>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#else
#include <openssl/evp.h>
#endif

namespace sandbox::content {
inline std::string sha256(std::string_view data) {
    std::array<unsigned char, 32> digest{};
#ifdef _WIN32
    BCRYPT_ALG_HANDLE alg{};
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
        throw std::runtime_error("SHA256 provider");
    const auto status = BCryptHash(alg, nullptr, 0,
        reinterpret_cast<PUCHAR>(const_cast<char *>(data.data())),
        static_cast<ULONG>(data.size()), digest.data(), static_cast<ULONG>(digest.size()));
    BCryptCloseAlgorithmProvider(alg, 0);
    if (status < 0) throw std::runtime_error("SHA256 failed");
#else
    unsigned int length = 0;
    if (EVP_Digest(data.data(), data.size(), digest.data(), &length, EVP_sha256(), nullptr) != 1 ||
        length != digest.size()) throw std::runtime_error("SHA256 failed");
#endif
    constexpr char hex[] = "0123456789abcdef";
    std::string out;
    for (auto byte : digest) {
        out += hex[byte >> 4];
        out += hex[byte & 15];
    }
    return out;
}
}
