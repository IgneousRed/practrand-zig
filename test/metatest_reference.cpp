// Explicit capture only: exercise the unchanged upstream checkpoint reporter.
#define main practrand_original_main
#include "tools/RNG_test.cpp"
#undef main

class FixtureManager : public TestManager {
public:
    std::vector<PractRand::TestResult> results;
    FixtureManager(PractRand::Tests::ListOfTests *list, PractRand::RNGs::vRNG *source)
        : TestManager(list, source) {
        rng = source;
        blocks_so_far = 1;
    }
    void get_results(std::vector<PractRand::TestResult> &output) override {
        output = results;
    }
};

int main() {
    PractRand::Tests::ListOfTests tests;
    PractRand::RNGs::Polymorphic::sfc64 source(PractRand::Uint64(0));
    FixtureManager manager(&tests, &source);
    seed_low = seed_high = 0;
    char name[160], kind[2][32];
    int smart;
    double threshold, value[2], weight[2];
    while (std::scanf("%159s %d %lf %31s %lf %lf %31s %lf %lf", name,
                      &smart, &threshold, kind[0], &value[0], &weight[0],
                      kind[1], &value[1], &weight[1]) == 9) {
        manager.results.clear();
        for (int i = 0; i < 2; ++i) {
            if (!std::strcmp(kind[i], "none")) continue;
            const char *kinds[] = {"raw", "raw_normal", "bad_p", "bad_s", "good_p", "good_s", "passfail"};
            int type = 0;
            while (type < 7 && std::strcmp(kind[i], kinds[type])) ++type;
            if (type == 7) return 2;
            manager.results.push_back(PractRand::TestResult(i ? "a-result" : "z-result", 0, value[i], type, weight[i]));
        }
        std::printf("case=%s\n", name);
        show_checkpoint(manager, 0, 0, smart != 0, threshold, false, true, 0);
    }
    return std::ferror(stdin) || std::ferror(stdout) ? 1 : 0;
}
