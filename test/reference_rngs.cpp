// Independent original-native-width byte probe; built only under .work/.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <iostream>
#include <list>
#include <deque>
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
#if defined(__i386__) || defined(__x86_64__)
#include "tools/dummy_rng.h"
#else
// Equivalent active dummy algorithm; the original header includes x86intrin.h
// unconditionally for Clang/GCC, even on ARM. Captures use its original x86 header.
class dummy_rng : public RNGs::vRNG32 {
    Uint32 a, b, c, d;
public:
    Uint32 raw32() override {
        const Uint64 product = a * Uint64(0x9e3779b97f4a7c15ULL);
        a = b ^ Uint32(product >> 32); b = Uint32(product); return b;
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c); walker->handle(d);
    }
    std::string get_name() const override { return "dummy_rng"; }
};
#endif
int main(int argc, char **argv) {
    RNG_Factories::register_recommended_RNGs();
    RNG_Factories::register_nonrecommended_RNGs();
    RNG_Factories::register_candidate_RNGs();
    RNG_Factories::register_input_RNGs();
    FastSeeder128_MetaRNG::register_name();
    RecursiveSeed64_MetaRNG::register_name();
    EntropyPool_MetaRNG::register_name();
    RNG_Factories::RNG_factory_index["dummy_rng"] = RNG_Factories::_generic_notrecommended_RNG_factory<dummy_rng>;
    if (argc == 2 && !std::strcmp(argv[1], "--factories")) {
        for (const auto &entry : RNG_Factories::RNG_factory_index) std::puts(entry.first.c_str());
        return 0;
    }
    if (argc != 5) return 2;
    std::unique_ptr<RNGs::vRNG> rng(RNG_Factories::create_rng(argv[1]));
    if (!rng) return 3;
    rng->seed(std::strtoull(argv[2], nullptr, 16), std::strtoull(argv[3], nullptr, 16));
    std::fprintf(stderr, "%d\n%s\n", rng->get_native_output_size(), rng->get_name().c_str());
    size_t remaining = std::strtoull(argv[4], nullptr, 10);
    Tests::TestBlock blocks[4];
    while (remaining) {
        const size_t count = remaining < sizeof blocks ? remaining : sizeof blocks;
        blocks[0].fill(rng.get(), (count + 1023) / 1024);
        if (std::fwrite(blocks, 1, count, stdout) != count) return 4;
        remaining -= count;
    }
    return std::fflush(stdout) == 0 ? 0 : 5;
}
