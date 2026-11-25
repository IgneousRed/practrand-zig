// Inspect the diagnostic reference's classification bytes and Arbee progress.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "PractRand.h"
#include "PractRand/tests.h"
#include "PractRand/test_batteries.h"
#include "PractRand/RNGs/arbee.h"
#include "PractRand/Tests/transforms.h"

using namespace PractRand;

class Probe : public Tests::Transforms::classify128to8 {
public:
    Probe() : classify128to8("[C8]", Tests::ListOfTests()) {}
    void write_bytes() const {
        const std::size_t size = buffered.size() * Tests::TestBlock::SIZE -
            (leftovers ? Tests::TestBlock::SIZE - leftovers : 0);
        if (std::fwrite(buffered.data(), 1, size, stdout) != size) std::exit(1);
    }
};

int main() {
    // Cross the original transform's 16 MiB recursive-call boundary as well as
    // smaller irregular whole-block boundaries. The transformed output remains
    // below the 4 MiB normal flush, so the probe can inspect every output byte.
    const int blocks = 16385;
    std::vector<Tests::TestBlock> input(blocks);
    for (int fixture = 0; fixture < 5; ++fixture) {
        unsigned char *bytes = reinterpret_cast<unsigned char *>(input.data());
        for (std::size_t i = 0; i < input.size() * Tests::TestBlock::SIZE; ++i) {
            bytes[i] = fixture == 0 ? (i * 37 + 11) & 255 :
                fixture == 1 ? 0 : fixture == 2 ? 255 : fixture == 3 ? 0x55 :
                (i % 16 == 0 ? 1 : 0);
        }
        for (int schedule = 0; schedule < 2; ++schedule) {
            RNGs::Polymorphic::arbee known_good(Uint64(0));
            Probe probe;
            probe.init(&known_good);
            if (schedule == 0) probe.test_blocks(input.data(), blocks);
            else {
                const int chunks[] = {1, 3, 7, 31, 2048};
                int offset = 0, step = 0;
                while (offset < blocks) {
                    int count = chunks[step++ % 5];
                    if (count > blocks - offset) count = blocks - offset;
                    probe.test_blocks(input.data() + offset, count);
                    offset += count;
                }
            }
            probe.write_bytes();
            const Uint64 next = probe.internal_rng.raw64();
            for (int i = 0; i < 8; ++i) std::putchar((next >> (i * 8)) & 255);
            probe.deinit();
        }
    }
    return std::fflush(stdout) == 0 && !std::ferror(stdout) ? 0 : 1;
}
