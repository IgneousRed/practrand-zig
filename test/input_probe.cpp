// Exercise the public adapter, including irregular reads, in a fresh process.
#include "../src/builtin_rngs.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unistd.h>
static std::array<int, 2> available_descriptors() {
    const std::array<int, 2> result = {{dup(0), dup(0)}};
    for (int descriptor : result) if (descriptor >= 0) close(descriptor);
    return result;
}
int main(int argc, char **argv) {
    if (argc != 3 && argc != 6) return 2; // expression mode [entropy-low entropy-high bytes]
    const bool entropy = argc == 6;
    const bool lifecycle_error = !std::strcmp(argv[2], "lifecycle-error");
    const bool lifecycle = lifecycle_error || !std::strcmp(argv[2], "lifecycle");
    const auto before = lifecycle ? available_descriptors() : std::array<int, 2>{{0, 0}};
    if (lifecycle && (before[0] < 0 || before[1] < 0)) return 6;
    const size_t bytes = entropy ? std::strtoull(argv[5], nullptr, 10) : 4099;
    if (bytes > (1 << 20)) return 2;
    char error[1024] = {};
    unsigned bits = 0;
    void *rng = pr_rng_create(argv[1], entropy ? std::strtoull(argv[3], nullptr, 16) : 0,
                             entropy ? std::strtoull(argv[4], nullptr, 16) : 0,
                             entropy ? PR_RNG_ENTROPY : PR_RNG_OUTPUT, &bits, error, sizeof error);
    if (lifecycle_error) {
        if (rng) pr_rng_destroy(rng);
        return !rng && before == available_descriptors() ? 0 : 6;
    }
    if (!rng) { std::fprintf(stderr, "%s\n", error); return 3; }
    std::fprintf(stderr, "%d\n%s\n", pr_rng_width(rng), pr_rng_name(rng));
    if (!std::strcmp(argv[2], "metadata")) { pr_rng_destroy(rng); return 0; }
    std::vector<unsigned char> output(bytes);
    const size_t chunks[] = {1, 7, 3, 1024, 11, 31, 128};
    size_t offset = 0, call = 0;
    int result = 0;
    while (offset < bytes) {
        size_t count = !std::strcmp(argv[2], "split") ? chunks[call++ % 7] : bytes;
        if (count > bytes - offset) count = bytes - offset;
        result = pr_rng_fill(rng, output.data() + offset, count, error, sizeof error);
        if (result) { std::fprintf(stderr, "%s\n", error); break; }
        offset += count;
    }
    pr_rng_destroy(rng);
    if (lifecycle && before != available_descriptors()) {
        std::fprintf(stderr, "input descriptors leaked\n");
        return 6;
    }
    if (result) return 4;
    return std::fwrite(output.data(), 1, bytes, stdout) == bytes && !std::fflush(stdout) ? 0 : 5;
}
