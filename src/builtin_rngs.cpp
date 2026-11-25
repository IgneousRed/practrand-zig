// Buffered C ABI over the unchanged PractRand 0.96 generator sources (CC0).
// Only generators/helpers are linked; statistical testing remains in Zig.
#include "builtin_rngs.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <cmath>
#include <list>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <typeinfo>
#include <utility>
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
#include <RNG_from_name.h>
using namespace PractRand;
#include <Candidate_RNGs.h>
#include <SeedingTester.h>

namespace {
// Stream adapters preserve native-word reads without letting the original
// reader's exit(0) bypass Zig cleanup. Prime in construction order after validation.
struct InputExhausted {};
struct InputReader {
    virtual void prime() = 0;
    virtual ~InputReader() = default;
};
using InputReaders = std::vector<std::unique_ptr<InputReader>>;
thread_local InputReaders *constructing_inputs = nullptr;
thread_local unsigned *constructing_ranrot_warnings = nullptr;
struct InputConstruction {
    InputReaders *previous;
    unsigned *previous_warnings;
    InputConstruction(InputReaders &inputs, unsigned &warnings)
        : previous(constructing_inputs), previous_warnings(constructing_ranrot_warnings) {
        constructing_inputs = &inputs;
        constructing_ranrot_warnings = &warnings;
    }
    ~InputConstruction() {
        constructing_inputs = previous;
        constructing_ranrot_warnings = previous_warnings;
    }
};
template<typename Word> class StreamReader : public InputReader {
    std::string path;
    bool named;
    FILE *file = nullptr;
    Word buffer[4096 / sizeof(Word)];
    size_t position = 0, count = 0;
    void refill() {
        if (!file) {
            file = named ? std::fopen(path.c_str(), "rb") : stdin;
            if (!file) throw std::runtime_error("cannot open input file: " + path);
        }
        count = std::fread(buffer, sizeof(Word), sizeof(buffer) / sizeof(Word), file);
        position = 0;
        if (!count) {
            if (std::ferror(file)) throw std::runtime_error("error reading from file");
            throw InputExhausted();
        }
    }
public:
    explicit StreamReader(const char *name) : path(name ? name : ""), named(name != nullptr) {}
    ~StreamReader() override { if (named && file) std::fclose(file); }
    void prime() override { if (!count) refill(); }
    Word read() {
        if (position == count) refill();
        return buffer[position++];
    }
};
template<typename Word> StreamReader<Word> *make_stream_reader(const char *path) {
    std::unique_ptr<StreamReader<Word>> input(new StreamReader<Word>(path));
    StreamReader<Word> *reader = input.get();
    constructing_inputs->push_back(std::move(input));
    return reader;
}
#define STREAM_RNG(BITS) \
class Stream##BITS : public RNGs::vRNG##BITS { \
    StreamReader<Uint##BITS> *reader; \
    std::string name; \
    int width; \
public: \
    Stream##BITS(const char *path, const char *label, int output_width) \
        : reader(make_stream_reader<Uint##BITS>(path)), name(std::string("RNG_") + label + (path ? std::string("(\"") + path + "\")" : "")), width(output_width) {} \
    Uint##BITS raw##BITS() override { return reader->read(); } \
    Uint64 get_flags() const override { return RNGs::FLAG::SEEDING_UNSUPPORTED | RNGs::FLAG::STATE_UNAVAILABLE; } \
    int get_native_output_size() const override { return width; } \
    std::string get_name() const override { return name; } \
    void walk_state(StateWalkingObject *) override {} \
};
STREAM_RNG(8)
STREAM_RNG(16)
STREAM_RNG(32)
STREAM_RNG(64)
#undef STREAM_RNG

template<class Stream, int bits, bool named> RNGs::vRNG *stream_factory(std::vector<std::string> &params) {
    if (params.size() != (named ? 1 : 0)) return nullptr;
    const std::string label = std::string(named ? "file" : "stdin") + (bits ? std::to_string(bits) : "");
    return new Stream(named ? params[0].c_str() : nullptr, label.c_str(), bits ? bits : -1);
}
// The active dummy algorithm and walk order from upstream tools/dummy_rng.h.
// Its unused x86 helper include prevents using that header on ARM.
class Dummy : public RNGs::vRNG32 {
    Uint32 a, b, c, d;
public:
    Uint32 raw32() override {
        const Uint64 product = a * Uint64(0x9e3779b97f4a7c15ULL);
        a = b ^ Uint32(product >> 32);
        b = Uint32(product);
        return b;
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c); walker->handle(d);
    }
    std::string get_name() const override { return "dummy_rng"; }
};
// UB053: both 16-bit factors fit an exact Uint32 product. Reduce only when
// assigning a, avoiding upstream's signed-int promotion overflow in Debug.
class BinaryMult16 : public RNGs::vRNG16 {
    Uint16 a, b, c, d;
public:
    Uint16 raw16() override {
        const Uint16 old = a;
        a = Uint16(Uint32(b) * (Uint32(c) | 1));
        b = c ^ (old >> 7);
        c ^= old + d++;
        return a;
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c); walker->handle(d);
    }
    std::string get_name() const override { return "binarymult16"; }
};
// UB055: preserve the buffered recurrence and state walk while defining the
// low 16-bit product, as for BinaryMult16 above.
class FibMulMix16 : public RNGs::vRNG16 {
    enum { LAG1 = 7, LAG2 = 3 };
    Uint16 buffer[LAG1];
    Uint8 position;
public:
    Uint16 raw16() override {
        if (position < LAG1) return buffer[position++];
        Uint16 previous = buffer[LAG1 - 1];
        for (unsigned i = 0; i < LAG1; ++i) {
            const Uint16 a = buffer[i];
            const Uint16 b = buffer[(i + LAG1 - LAG2) % LAG1];
            previous += Internals::rotate16(previous, 5);
            previous ^= Uint16(Uint32(a) * (Uint32(b) | 1));
            buffer[i] = previous;
        }
        position = 0;
        return buffer[position++];
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(position);
        for (unsigned i = 0; i < LAG1; ++i) walker->handle(buffer[i]);
        if (position >= LAG1) position %= LAG1;
    }
    std::string get_name() const override { return "fibmulmix16"; }
};
// UB056: keep the scale/counter wrap and recurrence, with an exact product.
class Garthy16 : public RNGs::vRNG16 {
    Uint16 value, counter, scale;
public:
    Uint16 raw16() override {
        if (!counter) scale += 2;
        scale += 2;
        const Uint16 product = Uint16(Uint32(value) * Uint32(scale));
        value += Internals::rotate16(product, 7) ^ counter++;
        return value;
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(value); walker->handle(counter); walker->handle(scale);
        scale |= 1;
    }
    std::string get_name() const override { return "garthy16"; }
};
#include "builtin_rng_arithmetic.h"
// Work around UB007 without modifying .vendor/PractRand/tools/SeedingTester.h:
// upstream EntropyPool_MetaRNG::evolve_seed decrements unordered_history.begin()
// when lower_bound(hash) is begin(). In C++11, insert(sitr.first, hash) inserts
// immediately before lower_bound(hash) for every iterator, including begin/end.
class SafeEntropyPool : public EntropyPool_MetaRNG {
    void evolve_seed_safe() {
        while (true) {
            const Transform t = pick_random_transform(current_seed);
            std::vector<Uint8> new_seed = current_seed;
            apply_transform(new_seed, t);
            const Uint64 hash = hash_message(new_seed);
            const auto sitr = unordered_history.equal_range(hash);
            if (sitr.first == sitr.second || !check_conflict(new_seed)) {
                current_seed.swap(new_seed);
                const auto it = unordered_history.insert(sitr.first, hash);
                history.push_front(std::make_pair(it, t));
                check_history_length();
                return;
            }
        }
    }
public:
    SafeEntropyPool(RNGs::vRNG *pool, int min_len, int max_len)
        : EntropyPool_MetaRNG(pool, min_len, max_len) {}
    Uint64 raw64() override {
        const Uint64 rv = hash_message(current_seed);
        evolve_seed_safe();
        return rv;
    }
    static RNGs::vRNG *factory(std::vector<std::string> &params) {
        if (params.size() != 3) {
            params.push_back("wrong number of parameters - should be EntropyPoolingTester(rng,minlength,maxlength)");
            return nullptr;
        }
        // Preserve upstream UB003 (both bounds from params[1]) and UB008e message.
        const int minlength = std::atoi(params[1].c_str());
        const int maxlength = std::atoi(params[1].c_str());
        if (minlength < 1 || maxlength < 1 || minlength > maxlength || maxlength > 500) {
            params.push_back("EntropyPoolingTester parameters out of range - 0 < minlength <= maxlength < 500");
            return nullptr;
        }
        if (minlength == 1) {
            throw std::invalid_argument("one-byte entropy messages are unsupported: duplicate-seed rejection can cover the entire seed space, leaving no acceptable next seed");
        }
        RNGs::vRNG *rng = RNG_Factories::create_rng(params[0]);
        return rng ? new SafeEntropyPool(rng, minlength, maxlength) : nullptr;
    }
};
void rng_error(const char *message) { throw std::runtime_error(message); }
RNGs::vRNG *removed(std::vector<std::string> &) {
    throw std::invalid_argument("selected RNG is no longer supported by PractRand 0.96 (xsm16/32/64 or rarns16/32/64)");
}
template<class Rng, unsigned warning> RNGs::vRNG *legacy_ranrot_factory(std::vector<std::string> &params) {
    if (!params.empty()) return nullptr;
    if (constructing_ranrot_warnings) *constructing_ranrot_warnings |= warning;
    return new Rng(SEED_NONE);
}
void initialize_factories() {
    static const bool initialized = []() {
        hook_error_handler(rng_error);
        RNG_Factories::register_recommended_RNGs();
        RNG_Factories::register_nonrecommended_RNGs();
        RNG_Factories::register_candidate_RNGs();
        FastSeeder128_MetaRNG::register_name();
        RecursiveSeed64_MetaRNG::register_name();
        RNG_Factories::RNG_factory_index["EntropyPoolingTester"] = SafeEntropyPool::factory;
#define INPUT_FACTORY(NAME, STREAM, BITS, NAMED) RNG_Factories::RNG_factory_index[NAME] = stream_factory<STREAM, BITS, NAMED>;
        INPUT_FACTORY("stdin", Stream8, 0, false)
        INPUT_FACTORY("stdin8", Stream8, 8, false)
        INPUT_FACTORY("stdin16", Stream16, 16, false)
        INPUT_FACTORY("stdin32", Stream32, 32, false)
        INPUT_FACTORY("stdin64", Stream64, 64, false)
        INPUT_FACTORY("file", Stream8, 0, true)
        INPUT_FACTORY("file8", Stream8, 8, true)
        INPUT_FACTORY("file16", Stream16, 16, true)
        INPUT_FACTORY("file32", Stream32, 32, true)
        INPUT_FACTORY("file64", Stream64, 64, true)
#undef INPUT_FACTORY
        RNG_Factories::RNG_factory_index["dummy_rng"] = RNG_Factories::_generic_notrecommended_RNG_factory<Dummy>;
        RNG_Factories::RNG_factory_index["binarymult16"] = RNG_Factories::_generic_notrecommended_RNG_factory<BinaryMult16>;
        RNG_Factories::RNG_factory_index["fibmulmix16"] = RNG_Factories::_generic_notrecommended_RNG_factory<FibMulMix16>;
        RNG_Factories::RNG_factory_index["garthy16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Garthy16>;
        RNG_Factories::RNG_factory_index["mrsf16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mrsf16>;
        RNG_Factories::RNG_factory_index["mulcrax16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mulcrax16>;
        RNG_Factories::RNG_factory_index["mulcrx16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mulcrx16>;
        RNG_Factories::RNG_factory_index["multish4x16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_multish4x16>;
        RNG_Factories::RNG_factory_index["mwlac_varA"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwlac_varA>;
        RNG_Factories::RNG_factory_index["mwlac_varB"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwlac_varB>;
        RNG_Factories::RNG_factory_index["mwlac_varC"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwlac_varC>;
        RNG_Factories::RNG_factory_index["mwlac_varD"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwlac_varD>;
        RNG_Factories::RNG_factory_index["mwlac_varE"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwlac_varE>;
        RNG_Factories::RNG_factory_index["mwlac_varF"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwlac_varF>;
        RNG_Factories::RNG_factory_index["mwrca16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwrca16>;
        RNG_Factories::RNG_factory_index["mwrcc16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwrcc16>;
        RNG_Factories::RNG_factory_index["mwrcca16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_mwrcca16>;
        RNG_Factories::RNG_factory_index["old_mwlac16"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_old_mwlac16>;
        RNG_Factories::RNG_factory_index["varrotC"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_varrotC>;
        RNG_Factories::RNG_factory_index["gjishC"] = RNG_Factories::_generic_notrecommended_RNG_factory<Defined_gjishC>;
        RNG_Factories::RNG_factory_index["mrc16"] = RNG_Factories::_generic_recommended_RNG_factory<DefinedMrc16>;
        RNG_Factories::RNG_factory_index["vf16"] = RNG_Factories::_generic_recommended_RNG_factory<DefinedVeryFast16>;
        RNG_Factories::RNG_factory_index["sfc_alt8"] = RNG_Factories::_generic_recommended_RNG_factory<DefinedSfcAlternative8>;
        RNG_Factories::RNG_factory_index["sfc_alternative8"] = RNG_Factories::_generic_recommended_RNG_factory<DefinedSfcAlternative8>;
        RNG_Factories::RNG_factory_index["ranrot_var32"] = legacy_ranrot_factory<LegacyRanrot32, 1>;
        RNG_Factories::RNG_factory_index["ranrot_var64"] = legacy_ranrot_factory<LegacyRanrot64, 2>;
        RNG_Factories::RNG_factory_index["ranrot_var32_fixed"] = RNG_Factories::_generic_recommended_RNG_factory<FixedRanrot32>;
        RNG_Factories::RNG_factory_index["ranrot_var64_fixed"] = RNG_Factories::_generic_recommended_RNG_factory<FixedRanrot64>;
        for (const char *name : {"xsm16", "xsm32", "xsm64", "rarns16", "rarns32", "rarns64"})
            RNG_Factories::RNG_factory_index[name] = removed;
        return true;
    }();
    (void)initialized;
}
struct Generator {
    // Own stream resources independently of imported wrappers' child ownership.
    // Declared first so the RNG graph is destroyed before its borrowed readers.
    InputReaders inputs;
    std::unique_ptr<RNGs::vRNG> rng;
    std::string name;
    Uint64 pending = 0;
    unsigned remaining = 0;
    unsigned wide_sfc = 0;
    int target = PR_RNG_OUTPUT;
    void prime_inputs() {
        for (const auto &input : inputs) input->prime();
    }
    void seed(Uint64 low, Uint64 high) {
        // Wrappers can read while seeding. Reserve every reader's initial chunk
        // first, matching 0.96 even when several readers share stdin.
        prime_inputs();
        if (target == PR_RNG_ENTROPY) {
            // The three setup checks and HC256 draw follow RNG_test.cpp mode 2.
            // Keep these at the target boundary, not in the expression factory.
            RNGs::vRNG *pool = static_cast<EntropyPool_MetaRNG *>(rng.get())->base_entropy_pool;
            pool->reset_entropy();
            const Uint64 a = pool->raw64();
            pool->reset_entropy();
            const Uint64 b = pool->raw64();
            if (a != b) throw std::invalid_argument("entropy pooling RNG failed basic check 1");
            RNGs::Polymorphic::hc256 known_good(SEED_NONE);
            known_good.seed(low, high);
            const Uint64 entropy = known_good.raw64();
            pool->reset_entropy();
            pool->add_entropy64(entropy);
            const Uint64 c1 = pool->raw64();
            const Uint64 c2 = pool->raw64();
            pool->reset_entropy();
            pool->add_entropy64(entropy);
            const Uint64 d = pool->raw64();
            pool->reset_entropy();
            pool->add_entropy64(entropy + 1);
            const Uint64 e1 = pool->raw64();
            const Uint64 e2 = pool->raw64();
            if (c1 != d) throw std::invalid_argument("entropy pooling RNG failed basic check 2");
            if (c1 == e1 && c2 == e2) throw std::invalid_argument("entropy pooling RNG probably failed basic check 3");
        }
        rng->seed(low, high);
        pending = 0;
        remaining = 0;
    }
};
void error_text(char *buffer, size_t size, const char *message) {
    if (size) std::snprintf(buffer, size, "%s", message);
}
void append_warning(char *buffer, size_t size, const char *message) {
    if (!size) return;
    const size_t used = std::strlen(buffer);
    std::snprintf(buffer + used, size - used, "%s%s", used ? "; " : "", message);
}
template<typename T, bool swap_native32 = false> T draw(RNGs::vRNG *rng);
template<> Uint8 draw<Uint8>(RNGs::vRNG *rng) { return rng->raw8(); }
template<> Uint16 draw<Uint16>(RNGs::vRNG *rng) { return rng->raw16(); }
template<> Uint32 draw<Uint32>(RNGs::vRNG *rng) { return rng->raw32(); }
template<> Uint64 draw<Uint64>(RNGs::vRNG *rng) { return rng->raw64(); }
template<> Uint64 draw<Uint64, true>(RNGs::vRNG *rng) {
    // The upstream 32-bit wrapper puts the first draw in the high half.
    const Uint64 word = rng->raw64();
    return (word << 32) | (word >> 32);
}
template<typename T, bool swap_native32 = false> void fill(Generator &source, unsigned char *output, size_t bytes) {
    while (source.remaining && bytes) {
        *output++ = static_cast<unsigned char>(source.pending);
        source.pending >>= 8; --source.remaining; --bytes;
    }
    while (bytes >= sizeof(T)) {
        const T word = draw<T, swap_native32>(source.rng.get());
        std::memcpy(output, &word, sizeof word);
        output += sizeof word; bytes -= sizeof word;
    }
    if (bytes) {
        source.pending = draw<T, swap_native32>(source.rng.get());
        source.remaining = sizeof(T);
        while (bytes--) {
            *output++ = static_cast<unsigned char>(source.pending);
            source.pending >>= 8; --source.remaining;
        }
    }
}
}

// Portable counterparts for the upstream platform file's three host services.
// Explicit seeds never require entropy; no timestamps are mixed into a seed.
bool PractRand::Internals::add_entropy_automatically(RNGs::vRNG *rng, int) {
    Uint64 words[4];
    FILE *file = std::fopen("/dev/urandom", "rb");
    if (!file) return false;
    const bool complete = std::fread(words, sizeof words, 1, file) == 1;
    std::fclose(file);
    if (!complete) return false;
    for (Uint64 word : words) rng->add_entropy64(word);
    rng->flush_buffers();
    std::memset(words, 0, sizeof words);
    return true;
}
Uint64 PractRand::Internals::issue_unique_identifier() {
    static std::atomic<Uint64> next(0);
    return next.fetch_add(1, std::memory_order_relaxed);
}

// Upstream transforms use this helper; reproducing its native-width draw order
// avoids linking the original statistical batteries just for block filling.
void PractRand::Tests::TestBlock::fill(RNGs::vRNG *rng, unsigned long blocks) {
    const unsigned long bytes = blocks * SIZE;
    switch (rng->get_native_output_size()) {
    case 64: for (unsigned long i = 0; i < bytes / 8; ++i) as64[i] = rng->raw64(); break;
    case 32: for (unsigned long i = 0; i < bytes / 4; ++i) as32[i] = rng->raw32(); break;
    case 16: for (unsigned long i = 0; i < bytes / 2; ++i) as16[i] = rng->raw16(); break;
    default: for (unsigned long i = 0; i < bytes; ++i) as8[i] = rng->raw8(); break;
    }
}

extern "C" void *pr_rng_open(const char *expression, int seed_mode, unsigned *seed_bits, char *error, size_t size) {
    error_text(error, size, "");
    try {
        initialize_factories();
        std::string message;
        std::unique_ptr<Generator> source(new Generator);
        unsigned ranrot_warnings = 0;
        InputConstruction construction(source->inputs, ranrot_warnings);
        source->rng.reset(RNG_Factories::create_rng(expression, &message));
        if (!source->rng) throw std::invalid_argument(message.empty() ? "unsupported RNG or invalid RNG expression" : message);
        source->target = seed_mode;
        if (seed_mode == PR_RNG_ENTROPY) {
            if (!(source->rng->get_flags() & RNGs::FLAG::SUPPORTS_ENTROPY_ACCUMULATION))
                throw std::invalid_argument("entropy testing requires an RNG supporting entropy accumulation");
            source->rng.reset(new SafeEntropyPool(source->rng.release(), 57, 57));
            source->name = source->rng->get_name();
        } else if (seed_mode != PR_RNG_OUTPUT) {
            if (source->rng->get_flags() & RNGs::FLAG::SEEDING_UNSUPPORTED)
                throw std::invalid_argument("seed testing requires a seedable RNG");
            if (!*seed_bits) {
                Uint64 max_low, max_high;
                source->rng->get_maximum_seed(max_low, max_high);
                if (!max_low && !max_high) {
                    *seed_bits = 128;
                    error_text(error, size, "seed size metadata unavailable; defaulting to 128 bits");
                } else {
                    // Preserve 0.96's CLI autodetection, including its low-word
                    // +64 offset (UB050). Explicit -ttseedBITS avoids it.
                    *seed_bits = 64 + unsigned(std::floor(std::log2(1.0 + double(max_high ? max_high : max_low)) + 0.000001));
                }
            }
            // The original native CLI bypasses its factory's 16..128 check.
            // Keep that behavior for the imported walk, including tiny spaces.
            if (seed_mode != PR_RNG_SEED_ORIGINAL && (*seed_bits < 16 || *seed_bits > 128))
                throw std::invalid_argument("seed width must be between 16 and 128 bits");
            if (seed_mode == 1) {
                source->rng.reset(new FastSeeder128_MetaRNG(source->rng.release(), int(*seed_bits)));
                source->name = source->rng->get_name();
            } else {
                if (seed_mode == 3 && (*seed_bits & (*seed_bits - 1)))
                    throw std::invalid_argument("balanced-gray requires 16, 32, 64 or 128 seed bits");
                source->name = "SeedingTester(" + source->rng->get_name() + "," + std::to_string(*seed_bits) +
                    (seed_mode == 2 ? ",gray)" : ",balanced-gray)");
            }
        } else {
            source->name = source->rng->get_name();
        }
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
        // These exact upstream types concatenate native draws in raw64().
        // SFC32's halves need swapping to preserve native little-endian order.
        // Native-width reporting and transforms/subclasses keep their contract.
        const RNGs::vRNG &rng = *source->rng;
        if (seed_mode == PR_RNG_OUTPUT && typeid(rng) == typeid(RNGs::Polymorphic::sfc16)) source->wide_sfc = 16;
        else if (seed_mode == PR_RNG_OUTPUT && typeid(rng) == typeid(RNGs::Polymorphic::sfc32)) source->wide_sfc = 32;
#endif
        if (ranrot_warnings & 1)
            append_warning(error, size, "ranrot_var32 repeats the original 45-word buffer; use ranrot_var32_fixed for the intended recurrence");
        if (ranrot_warnings & 2)
            append_warning(error, size, "ranrot_var64 repeats the original 45-word buffer; use ranrot_var64_fixed for the intended recurrence");
        return source.release();
    } catch (const std::exception &e) { error_text(error, size, e.what()); return nullptr; }
}
extern "C" int pr_rng_seedable(const void *raw) {
    return !(static_cast<const Generator *>(raw)->rng->get_flags() & RNGs::FLAG::SEEDING_UNSUPPORTED);
}
extern "C" int pr_rng_has_stream(const void *raw) { return !static_cast<const Generator *>(raw)->inputs.empty(); }
extern "C" int pr_rng_seed(void *raw, uint64_t low, uint64_t high, char *error, size_t size) {
    try {
        static_cast<Generator *>(raw)->seed(low, high);
        return 0;
    } catch (const InputExhausted &) { error_text(error, size, "error reading from file"); return 1; }
    catch (const std::exception &e) { error_text(error, size, e.what()); return -1; }
}
// Native test tools can open and seed an adapter in one call.
extern "C" void *pr_rng_create(const char *expression, uint64_t low, uint64_t high, int seed_mode, unsigned *seed_bits, char *error, size_t size) {
    void *raw = pr_rng_open(expression, seed_mode, seed_bits, error, size);
    if (raw && seed_mode != PR_RNG_SEED_GRAY && seed_mode != PR_RNG_SEED_BALANCED_GRAY && pr_rng_seed(raw, low, high, error, size) != 0) {
        pr_rng_destroy(raw);
        return nullptr;
    }
    return raw;
}
extern "C" void pr_rng_destroy(void *source) { delete static_cast<Generator *>(source); }
extern "C" const char *pr_rng_name(const void *source) { return static_cast<const Generator *>(source)->name.c_str(); }
extern "C" int pr_rng_width(const void *raw) {
    const Generator &source = *static_cast<const Generator *>(raw);
    return source.target != PR_RNG_OUTPUT ? 64 : source.rng->get_native_output_size();
}
extern "C" int pr_rng_seed_word(void *raw, uint64_t low, uint64_t high, uint64_t *word, char *error, size_t size) {
    try {
        Generator &source = *static_cast<Generator *>(raw);
        source.seed(low, high);
        *word = source.rng->raw64();
        return 0;
    } catch (const InputExhausted &) { error_text(error, size, "error reading from file"); return 1; }
    catch (const std::exception &e) { error_text(error, size, e.what()); return -1; }
}
extern "C" int pr_rng_fill(void *raw, unsigned char *output, size_t bytes, char *error, size_t size) {
    try {
        Generator &source = *static_cast<Generator *>(raw);
        if (bytes) source.prime_inputs();
        if (source.wide_sfc == 16) fill<Uint64>(source, output, bytes);
        else if (source.wide_sfc == 32) fill<Uint64, true>(source, output, bytes);
        else switch (source.rng->get_native_output_size()) {
        case 64: fill<Uint64>(source, output, bytes); break;
        case 32: fill<Uint32>(source, output, bytes); break;
        case 16: fill<Uint16>(source, output, bytes); break;
        default: fill<Uint8>(source, output, bytes); break;
        }
        return 0;
    } catch (const InputExhausted &) { error_text(error, size, "error reading from file"); return 1; }
    catch (const std::exception &e) { error_text(error, size, e.what()); return -1; }
}
extern "C" int pr_rng_random_seed(uint64_t *seed) {
    Uint32 value;
    FILE *file = std::fopen("/dev/urandom", "rb");
    if (!file) return -1;
    const bool complete = std::fread(&value, sizeof value, 1, file) == 1;
    std::fclose(file);
    if (complete) *seed = value;
    return complete ? 0 : -1;
}
extern "C" size_t pr_rng_factory_count() { initialize_factories(); return RNG_Factories::RNG_factory_index.size(); }
extern "C" const char *pr_rng_factory_name(size_t index) {
    initialize_factories();
    if (index >= RNG_Factories::RNG_factory_index.size()) return nullptr;
    auto entry = RNG_Factories::RNG_factory_index.begin();
    std::advance(entry, index);
    return entry->first.c_str();
}
extern "C" const char *pr_rng_catalog_label(unsigned group) {
    static const char *labels[] = {"recommended_rngs", "nonrecommended_rngs_simple", "nonrecommended_rngs_oddball", "nonrecommended_rngs_lcgish", "nonrecommended_rngs_cbuf", "nonrecommended_rngs_indirect"};
    return group < 6 ? labels[group] : nullptr;
}
extern "C" const char *pr_rng_catalog_name(unsigned group, size_t index) {
    using namespace PractRand::RNG_Sets;
    const char **lists[] = {recommended_rngs, nonrecommended_simple, nonrecommended_oddball, nonrecommended_lcgish, nonrecommended_cbuf, nonrecommended_indirect};
    const size_t lengths[] = {num_recommended_rngs, num_nonrecommended_simple, num_nonrecommended_oddball, num_nonrecommended_lcgish, num_nonrecommended_cbuf, num_nonrecommended_indirect};
    return group < 6 && index < lengths[group] ? lists[group][index] : nullptr;
}
