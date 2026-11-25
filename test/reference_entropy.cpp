// Entropy-target oracle over unchanged PractRand 0.96, following RNG_test.cpp mode 2.
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

int main(int argc, char **argv) {
    if (argc != 5) return 2; // expression low high bytes
    RNG_Factories::register_recommended_RNGs();
    RNG_Factories::register_nonrecommended_RNGs();
    RNG_Factories::register_candidate_RNGs();
    std::unique_ptr<RNGs::vRNG> rng(RNG_Factories::create_rng(argv[1]));
    if (!rng || !(rng->get_flags() & RNGs::FLAG::SUPPORTS_ENTROPY_ACCUMULATION)) return 3;
    const Uint64 low = std::strtoull(argv[2], nullptr, 16);
    const Uint64 high = std::strtoull(argv[3], nullptr, 16);
    size_t bytes = std::strtoull(argv[4], nullptr, 10);
    RNGs::Polymorphic::hc256 known_good(SEED_NONE);
    known_good.seed(low, high);
    rng->reset_entropy();
    const Uint64 a = rng->raw64();
    rng->reset_entropy();
    const Uint64 b = rng->raw64();
    if (a != b) return 11;
    const Uint64 s64 = known_good.raw64();
    rng->reset_entropy();
    rng->add_entropy64(s64);
    const Uint64 c1 = rng->raw64();
    const Uint64 c2 = rng->raw64();
    rng->reset_entropy();
    rng->add_entropy64(s64);
    const Uint64 d = rng->raw64();
    rng->reset_entropy();
    rng->add_entropy64(s64 + 1);
    const Uint64 e1 = rng->raw64();
    const Uint64 e2 = rng->raw64();
    if (c1 != d) return 12;
    if (c1 == e1 && c2 == e2) return 13;
    rng.reset(new EntropyPool_MetaRNG(rng.release(), 57, 57));
    rng->seed(low, high);
    std::fprintf(stderr, "%d\n%s\n", rng->get_native_output_size(), rng->get_name().c_str());
    while (bytes) {
        const Uint64 word = rng->raw64();
        const size_t count = bytes < 8 ? bytes : 8;
        if (std::fwrite(&word, 1, count, stdout) != count) return 4;
        bytes -= count;
    }
    return std::fflush(stdout) ? 5 : 0;
}
