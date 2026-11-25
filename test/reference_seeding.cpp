// Independent seeding-stream oracle over unchanged PractRand 0.96 sources.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <deque>
#include <list>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include <PractRand_full.h>
#include <PractRand/RNGs/all.h>
#include <PractRand/RNGs/other/mt19937.h>
#include <PractRand/RNGs/other/transform.h>
#include <PractRand/RNGs/other/lcgish.h>
#include <PractRand/RNGs/other/oddball.h>
#include <PractRand/RNGs/other/simple.h>
#include <PractRand/RNGs/other/cbuf.h>
#include <PractRand/RNGs/other/indirection.h>
#include <PractRand/RNGs/other/special.h>
#include "tools/RNG_from_name.h"
using namespace PractRand;
#include "tools/Candidate_RNGs.h"
#include "tools/SeedingTester.h"

// Direct rank-to-word construction, independent of the Zig edge selector.
static __uint128_t balanced(unsigned width, __uint128_t rank) {
    if (width == 4) {
        const unsigned words[] = {0, 1, 3, 7, 5, 4, 12, 14, 6, 2, 10, 11, 15, 13, 9, 8};
        return words[unsigned(rank)];
    }
    const unsigned half = width / 2;
    const __uint128_t mask = (__uint128_t(1) << half) - 1;
    const __uint128_t k = (rank >> 1) & mask;
    const __uint128_t p = rank >> (half + 1);
    const __uint128_t x = (k + (rank & 1)) & mask;
    const __uint128_t y = (k - 2 * p) & mask;
    return balanced(half, x) | (balanced(half, y) << half);
}

int main(int argc, char **argv) {
    if (argc != 7) return 2; // expression mode bits low high bytes
    RNG_Factories::register_recommended_RNGs();
    RNG_Factories::register_nonrecommended_RNGs();
    RNG_Factories::register_candidate_RNGs();
    std::unique_ptr<RNGs::vRNG> rng(RNG_Factories::create_rng(argv[1]));
    if (!rng) return 3;
    unsigned bits = unsigned(std::strtoul(argv[3], nullptr, 10));
    const Uint64 low = std::strtoull(argv[4], nullptr, 16);
    const Uint64 high = std::strtoull(argv[5], nullptr, 16);
    size_t bytes = std::strtoull(argv[6], nullptr, 10);
    const bool original = !std::strcmp(argv[2], "original");
    const bool gray = !std::strcmp(argv[2], "gray");
    const bool balanced_gray = !std::strcmp(argv[2], "balanced-gray");
    if (!original && !gray && !balanced_gray) return 5;
    if (!bits) {
        Uint64 l, h;
        rng->get_maximum_seed(l, h);
        bits = !l && !h ? 128 : 64 + unsigned(std::floor(std::log2(1.0 + double(h ? h : l)) + 0.000001));
    }
    // Recursive rank construction requires a power-of-two width.
    if (bits < 16 || bits > 128 || (balanced_gray && (bits & (bits - 1)))) return 4;
    std::fprintf(stderr, "%u\n", bits);
    if (original) {
        rng.reset(new FastSeeder128_MetaRNG(rng.release(), int(bits)));
        rng->seed(low, high);
    }
    const __uint128_t mask = ~__uint128_t(0) >> (128 - bits);
    const __uint128_t offset = (__uint128_t(low) | (__uint128_t(high) << 64)) & mask;
    for (__uint128_t rank = 0; bytes; ++rank) {
        if (!original) {
            const __uint128_t value = ((gray ? rank ^ (rank >> 1) : balanced(bits, rank)) ^ offset) & mask;
            rng->seed(Uint64(value), Uint64(value >> 64));
        }
        const Uint64 word = rng->raw64();
        const size_t count = bytes < 8 ? bytes : 8;
        if (std::fwrite(&word, 1, count, stdout) != count) return 6;
        bytes -= count;
    }
    return std::fflush(stdout) ? 7 : 0;
}
