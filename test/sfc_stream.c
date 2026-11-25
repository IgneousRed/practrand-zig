/* PractRand 0.96 SFC16/32/64 (CC0), normal seed(0, 0), little-endian output.
 * Kept separate from the tester; captured upstream prefix hashes verify the
 * recurrence, seed state, warmup, and byte order without running upstream. */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { BUFFER_BYTES = 1 << 20 };

#define SFC(BITS, RIGHT, ROTATE, WARMUP, INITIAL_C) \
    static uint##BITS##_t a##BITS, b##BITS, c##BITS = INITIAL_C, counter##BITS = 1; \
    static uint##BITS##_t next##BITS(void) { \
        uint##BITS##_t result = (uint##BITS##_t)(a##BITS + b##BITS + counter##BITS++); \
        a##BITS = (uint##BITS##_t)(b##BITS ^ (b##BITS >> RIGHT)); \
        b##BITS = (uint##BITS##_t)(c##BITS + (c##BITS << 3)); \
        c##BITS = (uint##BITS##_t)(((c##BITS << ROTATE) | (c##BITS >> (BITS - ROTATE))) + result); \
        return result; \
    } \
    static void init##BITS(void) { \
        for (int i = 0; i < WARMUP; ++i) (void)next##BITS(); \
    }

SFC(16, 5, 6, 10, 0)
SFC(32, 9, 21, 12, 0)
SFC(64, 11, 25, 8, UINT64_MAX)

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "16") && strcmp(argv[1], "32") && strcmp(argv[1], "64"))) {
        fprintf(stderr, "usage: sfc_stream 16|32|64 BYTE_COUNT (normal seed zero)\n");
        return 1;
    }
    if (*argv[2] < '0' || *argv[2] > '9') return 1;
    char *end;
    errno = 0;
    uint64_t remaining = strtoull(argv[2], &end, 10);
    if (errno || *end) return 1;
    const unsigned width = (unsigned)atoi(argv[1]);
    const unsigned word_bytes = width / 8;
    if (remaining % word_bytes) return 1;
    if (width == 16) init16(); else if (width == 32) init32(); else init64();
    unsigned char buffer[BUFFER_BYTES];
    while (remaining) {
        const size_t count = remaining < sizeof buffer ? (size_t)remaining : sizeof buffer;
        for (size_t offset = 0; offset < count; offset += word_bytes) {
            const uint64_t word = width == 16 ? next16() : width == 32 ? next32() : next64();
            for (unsigned j = 0; j < word_bytes; ++j) buffer[offset + j] = (unsigned char)(word >> (j * 8));
        }
        if (fwrite(buffer, 1, count, stdout) != count) return 1;
        remaining -= count;
    }
    return fflush(stdout) != 0 || ferror(stdout);
}
