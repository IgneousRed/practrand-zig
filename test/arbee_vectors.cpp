#include <cstdio>
#include "PractRand/config.h"
#include "PractRand/rng_basics.h"
#include "PractRand/RNGs/arbee.h"
using PractRand::Uint64;
using PractRand::RNGs::Raw::arbee;
static void row(arbee r) {
    std::printf(".{ ");
    for (int j = 0; j < 4; ++j) std::printf("0x%016llx, ", (unsigned long long)r.raw64());
    std::puts("},");
}
struct probe : arbee {
    void wrap() { a = b = c = d = i = ~Uint64(0); }
};
int main() {
    std::puts("seed vectors");
    row(arbee(0, 0)); row(arbee(1, 0)); row(arbee(~Uint64(0), ~Uint64(0)));
    row(arbee(0x0123456789abcdefULL, 0xfedcba9876543210ULL));
    std::puts("reset"); row(arbee());
    std::puts("entropy byte slices, bytes[j] = j * 37 + 11, initial seed (0x0123456789abcdef, 0xfedcba9876543210)");
    unsigned char bytes[32];
    for (unsigned j = 0; j < sizeof(bytes); ++j) bytes[j] = (unsigned char)(j * 37 + 11);
    for (unsigned j = 0; j <= sizeof(bytes); ++j) {
        arbee r(0x0123456789abcdefULL, 0xfedcba9876543210ULL);
        r.add_entropy_N(bytes, j); row(r);
    }
    std::puts("scalar entropy and flush");
    arbee r(0x0123456789abcdefULL, 0xfedcba9876543210ULL);
    r.add_entropy8(0xff); r.add_entropy16(0xfedc); r.add_entropy32(0xfedcba98); r.add_entropy64(0xfedcba9876543210ULL);
    row(r); r.flush_buffers(); row(r);
    std::puts("wrap"); probe p; p.wrap(); row(p);
}
