// Isolated calls into the unmodified upstream library; no battery is constructed.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cfloat>
#include <cfenv>
#include <memory>
#include <map>
#include <vector>
#include "PractRand.h"
#include "PractRand/tests.h"
#include "PractRand/test_helpers.h"
#include "PractRand/RNGs/arbee.h"
#include "PractRand/Tests/BCFN.h"
#include "PractRand/Tests/BRank.h"
#include "PractRand/Tests/Birthday.h"
#include "PractRand/Tests/CoupGap.h"
#include "PractRand/Tests/DistC6.h"
#include "PractRand/Tests/DistFreq4.h"
#include "PractRand/Tests/FPF.h"
#include "PractRand/Tests/FPMulti.h"
#include "PractRand/Tests/Gap16.h"
#include "PractRand/Tests/NearSeq.h"
#include "PractRand/Tests/Pat5.h"
#include "PractRand/Tests/coup16.h"
#include "PractRand/Tests/mod3.h"
#include "PractRand/Tests/permutation.h"
namespace PractRand { namespace Tests {
double rarity_test_old(unsigned long, const double *, const Uint64 *);
double math_lower_incomplete_gamma(double, double);
double uniformity_test_with_brute_force2(unsigned long, const double *, const Uint64 *, PractRand::RNGs::Polymorphic::vRNG *);
}}
using namespace PractRand;
using namespace PractRand::Tests;
static TestBaseclass *make(const char *name) {
#define TEST(T, ...) if (!std::strcmp(name, #T)) return new T(__VA_ARGS__)
    TEST(DistC6, ); TEST(DistC7, ); TEST(BCFN, ); TEST(BCFN_FF, ); TEST(FPF, );
    TEST(BRank, 12); TEST(BRank_old, 12); TEST(mod3_simple, ); TEST(mod3n, 0);
    TEST(BirthdaySystematic2, 0, 22); TEST(Gap16, ); TEST(GapUniversal1, );
    TEST(GapUniversal2, ); TEST(GapUniversal3, ); TEST(LimitedBigGapPrototype, );
    TEST(FPMulti, ); TEST(Birthday32, ); TEST(Birthday64, );
    TEST(BirthdayLambda1, 16); TEST(BirthdaySystematic128, 16);
    TEST(BirthdayAlt, 12); TEST(Pat5, ); TEST(CoupGap, ); TEST(NearSeq, );
    TEST(NearSeq2, ); TEST(NearSeq3, ); TEST(Coup16, ); TEST(Coup32, );
    TEST(DistFreq4, 1); TEST(TripleFreq, 1, 1); TEST(TripleMirrorFreq, 1, 1);
    TEST(TripleMirrorFreqN, 0); TEST(TripleMirrorCoup, 1, 1);
    TEST(SimpleClassifyWord, ); TEST(LPerm16, 8); TEST(LPerm16A, 8);
#undef TEST
    return nullptr;
}
static void show(const char *name, double value) {
    std::printf("math\t%s\t%.17g\t%s\n", name, value, std::isnan(value) ? "NAN" : "ok");
}
static void math_probes() {
    double p[2] = {.25, .75}, flat[2] = {.5, .5};
    Uint64 empty[2] = {0, 0}, nonempty[2] = {10, 10};
    show("rarity old empty", rarity_test_old(2, p, empty));
    show("rarity old flat", rarity_test_old(2, flat, nonempty));
    show("chi-square normal(0,0) invalid DoF", math_chisquared_to_normal(0, 0));
    show("factorial(-1) invalid argument", math_factorial(-1));
    show("lower gamma(2,inf)", math_lower_incomplete_gamma(2, INFINITY));
    show("chi_squared_test empty (infinity expected)", chi_squared_test(2, p, empty));
    show("g_test empty", g_test(2, p, empty));
    show("g_test_flat empty", g_test_flat(2, empty));
    show("g_test_flat_merge_normal empty", g_test_flat_merge_normal(2, empty));
    G_TEST g; g.add_category(0, .25); g.add_category(0, .75); g.finalize();
    show("G_TEST empty", g.get_result());
    show("rarity unordered empty", rarity_test(2, p, empty, false, false));
    show("rarity ordered empty", rarity_test(2, p, empty, true, false));
    show("rarity unordered flat", rarity_test(2, flat, nonempty, false, false));
    show("rarity ordered flat", rarity_test(2, flat, nonempty, true, false));
    show("poisson(0,0)", math_poisson_pmf(0, 0));
    show("factorial_log(UINT64_MAX)", math_factorial_log(Uint64(-1)));
    for (int dof = 1; dof <= 8; ++dof) {
        char label[80]; std::snprintf(label, sizeof(label), "chi-square(inf,%d)", dof);
        show(label, math_chisquared_to_pvalue(INFINITY, dof));
    }
    for (double x : {0., 10., 1e100, 1e154, 1e155, DBL_MAX, double(INFINITY)}) {
        char label[100]; std::snprintf(label, sizeof(label), "normal suspicion(%.3g)", x);
        show(label, math_normaldist_to_suspicion(x));
    }
    SampleSet samples;
    double large[] = {-DBL_MAX, -DBL_MAX, DBL_MAX, DBL_MAX}; samples.add(large, 4);
    show("SampleSet percentile(.375) extreme finite", samples.get_result_by_percentile(.375));
    show("SampleSet stddev extreme finite", samples.get_stddev());
    for (double x : {1.1, 1e8, 1e12, 1e16, 1e100, 1e155}) {
        SampleSet same; for (int i = 0; i < 100; ++i) same._add(x);
        char label[100]; std::snprintf(label, sizeof(label), "SampleSet stddev 100 equal %.3g", x);
        show(label, same.get_stddev());
    }
    double rounding[] = {.5, .5 + 2e-16, 0}; Uint64 rounding_counts[] = {10, 10, 0};
    show("ordered rarity accepted rounded sum with zero tail", rarity_test(3, rounding, rounding_counts, true, true));
    RNGs::Polymorphic::arbee rng(Uint64(0));
    for (int ordered = 0; ordered < 2; ++ordered) {
        show(ordered ? "uniformity histogram empty" : "uniformity histogram nonempty",
             uniformity_test(2, p, ordered ? empty : nonempty));
        show(ordered ? "uniformity brute force empty" : "uniformity brute force nonempty",
             uniformity_test_with_brute_force(2, p, ordered ? empty : nonempty, &rng));
    }
    show("uniformity brute force2 empty", uniformity_test_with_brute_force2(2, p, empty, &rng));
    show("uniformity brute force2 nonempty", uniformity_test_with_brute_force2(2, p, nonempty, &rng));
    RawTestCalibrationData_117 raw117 = {};
    RawTestCalibrationData_129 raw129 = {};
    for (int i = 0; i < 117; ++i) raw117.table[i] = i;
    for (int i = 0; i < 129; ++i) raw129.table[i] = i;
    show("raw117 inverse interpolation index1.5 (expected1.5)", raw117.index_to_sample(1.5));
    show("raw129 inverse interpolation index1.5 (expected1.5)", raw129.index_to_sample(1.5));
    SampleSet unit; show("uniformity SampleSet empty", uniformity_test(unit));
    for (double x : {0., 0., .5, 1., 1.}) unit.add(x);
    show("uniformity SampleSet duplicate endpoints", uniformity_test(unit));
    for (double lambda : {4., 8.}) {
        int nans = 0, first = -1;
        for (int i = 0; i < 64 + lambda * 4; ++i) {
            double v = std::exp(-lambda) * std::pow(lambda, i) / math_factorial(i);
            if (std::isnan(v)) {++nans; if (first < 0) first = i;}
        }
        std::printf("formula\tbirthday Poisson lambda=%.3g\tNaNs=%d\tfirst=%d\n", lambda, nans, first);
    }
}
static void calibration_probes() {
    char name[256]; unsigned long long blocks; unsigned rows = 0, calls = 0, nans = 0;
    while (std::scanf("%255s %llu", name, &blocks) == 2) {
        auto *calib = calibration_manager.get_calibration_data(name, blocks);
        if (!calib) { std::fprintf(stderr, "missing calibration %s %llu\n", name, blocks); std::exit(2); }
        ++rows;
        for (double x : {-double(INFINITY), -DBL_MAX, -1e100, -100., -1., 0., 1., 100., 1e100, DBL_MAX, double(INFINITY)}) {
            for (double v : {calib->sample_to_suspicion(x), calib->suspicion_to_sample(x)}) {
                ++calls; if (std::isnan(v)) { ++nans; std::printf("calibration NAN\t%s\t%llu\t%.17g\n", name, blocks, x); }
            }
        }
        for (double p : {0., 1.}) {
            ++calls;
            if (std::isnan(calib->pvalue_to_sample(p))) {
                ++nans; std::printf("calibration endpoint NAN\t%s\t%llu\tp=%.0f\n", name, blocks, p);
            }
        }
    }
    std::printf("calibration\trows=%u\tcalls=%u\tNaNs=%u\n", rows, calls, nans);
}
static int stream_probe(char **argv) {
    std::unique_ptr<TestBaseclass> test(make(argv[1])); if (!test) return 2;
    RNGs::Polymorphic::arbee aux(Uint64(0)), data_rng(1);
    test->init(&aux);
    char *end;
    unsigned long requested = std::strtoul(argv[3], &end, 0);
    if (*end || requested > (1u << 20)) return 2;
    unsigned limit = requested;
    bool empty = std::atoi(argv[4]);
    if (!limit && !empty) return 2;
    if (std::strcmp(argv[2], "random") && std::strcmp(argv[2], "zero") &&
        std::strcmp(argv[2], "ones") && std::strcmp(argv[2], "ramp") &&
        std::strcmp(argv[2], "alternating") && std::strcmp(argv[2], "empty")) return 2;
    int repeat = test->get_blocks_to_repeat();
    std::vector<TestBlock> data(repeat + 64);
    unsigned done = 0, next = empty ? 0 : 1;
    while (true) {
        if (done == next) {
            std::feclearexcept(FE_ALL_EXCEPT);
            std::vector<TestResult> results;
            std::printf("checkpoint\t%s\t%s\t%u\n", argv[1], argv[2], done * 1024);
            test->get_results(results);
            int invalid = std::fetestexcept(FE_INVALID);
            for (auto &r : results) {
                double p = r.get_pvalue(), s = r.get_suspicion();
                bool nan = std::isnan(r.raw) || std::isnan(r.processed) || std::isnan(p) || std::isnan(s);
                std::printf("row\t%u\t%s\t%ld\t%.17g\t%.17g\t%.17g\t%.17g\t%s\n", done * 1024, r.name.c_str(), r.type, r.raw, r.processed, p, s, nan ? "NAN" : "ok");
            }
            if (invalid) std::printf("invalid\t%u\n", done * 1024);
            if (done == limit) break;
            next = next ? next * 2 : 1; if (next > limit) next = limit;
        }
        int n = std::min(64u, next - done);
        for (int b = 0; b < n; ++b) {
            auto &block = data[repeat + b];
            if (!std::strcmp(argv[2], "alternating")) {
                for (int i = 0; i < 256; ++i) block.as32[i] = i & 1 ? ~Uint32(0) : 0;
            }
            else if (!std::strcmp(argv[2], "random")) block.fill(&data_rng);
            else for (int i = 0; i < 1024; ++i) block.as8[i] = !std::strcmp(argv[2], "ones") ? 255 : !std::strcmp(argv[2], "ramp") ? Uint8(i) : 0;
        }
        test->test_blocks(data.data() + repeat, n);
        done += n;
        if (repeat) std::memmove(data.data(), data.data() + n, repeat * sizeof(TestBlock));
    }
    test->deinit();
    return 0;
}
int main(int argc, char **argv) {
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    if (argc == 2 && !std::strcmp(argv[1], "calibration")) { calibration_probes(); return 0; }
    if (argc == 2 && !std::strcmp(argv[1], "math")) { math_probes(); return 0; }
    if (argc == 5) return stream_probe(argv);
    std::fprintf(stderr, "usage: probe math | calibration | CLASS FIXTURE BLOCKS INCLUDE_EMPTY\n");
    return 2;
}
