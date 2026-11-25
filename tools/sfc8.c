/* Exact SFC recurrence from PractRand 0.96 src/RNGs/sfc.cpp, reduced to
 * 8-bit words. Constants are right shift, left shift, left rotation.
 * Initialization seeds all four words equally and discards nine outputs.
 * Chosen shifts/rotation: 1, 3, 4. */
#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum { RSHIFT = 1, LSHIFT = 3, ROTL = 4, WARMUP = 9, BUFFER_BYTES = 65536 };

static uint64_t number(const char *text, uint64_t maximum) {
    const char *start = text;
    while (isspace((unsigned char)*start)) start++;
    char *end;
    errno = 0;
    unsigned long long value = strtoull(start, &end, 0);
    if (errno || end == start || *end || *start == '-' || value > maximum) {
        fprintf(stderr, "invalid argument: %s\n", text);
        exit(1);
    }
    return value;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: sfc8 SEED BYTE_COUNT\n");
        return 1;
    }
    uint8_t seed = (uint8_t)number(argv[1], UINT8_MAX);
    uint64_t remaining = number(argv[2], UINT64_MAX);
    uint8_t a = seed, b = seed, c = seed, counter = seed;
    uint8_t buffer[BUFFER_BYTES];
    unsigned warmup = WARMUP;
    while (remaining || warmup) {
        size_t count = remaining < sizeof buffer ? remaining : sizeof buffer;
        for (size_t i = 0; i < count || warmup;) {
            uint8_t result = (uint8_t)(a + b + counter++);
            a = (uint8_t)(b ^ (b >> RSHIFT));
            b = (uint8_t)(c + (c << LSHIFT));
            c = (uint8_t)(((c << ROTL) | (c >> (8 - ROTL))) + result);
            if (warmup) {
                warmup--;
                continue;
            }
            buffer[i++] = result;
        }
        if (fwrite(buffer, 1, count, stdout) != count) return 1;
        remaining -= count;
    }
    return fflush(stdout) != 0;
}
