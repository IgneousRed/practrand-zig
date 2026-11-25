// Capture FPF/64's unchanged initial alignment with exactly one input call.
#include <cstdio>
#include <map>
#include <string>
#include <vector>
#include "PractRand.h"
#include "PractRand/tests.h"
#include "PractRand/test_helpers.h"
#include "PractRand/Tests/FPF.h"

int main() {
    for (unsigned blocks : {1u, 8u, 256u}) {
        std::vector<PractRand::Tests::TestBlock> input(blocks);
        PractRand::Uint64 state = 0;
        for (unsigned i = 0; i < blocks * 128; ++i) {
            state += 0x9e3779b97f4a7c15ULL;
            PractRand::Uint64 word = state;
            word = (word ^ (word >> 30)) * 0xbf58476d1ce4e5b9ULL;
            word = (word ^ (word >> 27)) * 0x94d049bb133111ebULL;
            word ^= word >> 31;
            // Define input bytes independently of the host's native byte order.
            for (unsigned byte = 0; byte < 8; ++byte)
                input[i / 128].as8[(i % 128) * 8 + byte] = PractRand::Uint8(word >> (byte * 8));
        }
        PractRand::Tests::FPF test(6, 14, 6);
        test.init(nullptr);
        test.test_blocks(input.data(), int(blocks));
        std::vector<PractRand::TestResult> results;
        test.get_results(results);
        for (const auto &r : results)
            std::printf("%u\t%s\t%ld\t%.17g\t%.17g\t%.17g\t%.17g\t%.17g\n",
                        blocks, r.name.c_str(), r.type, r.raw, r.processed,
                        r.get_pvalue(), r.get_suspicion(), r.get_weight());
        test.deinit();
    }
}
