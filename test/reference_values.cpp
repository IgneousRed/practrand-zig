// Isolated Birthday reference; this does not construct a statistical battery.
#include <cstdio>
#include <vector>
#include "PractRand.h"
#include "PractRand/tests.h"
#include "PractRand/Tests/Birthday.h"
int main() {
    PractRand::Tests::BirthdaySystematic2 birthday(4, 24);
    birthday.init(nullptr);
    std::vector<PractRand::Tests::TestBlock> zeros(16);
    for (int flush = 0; flush < 4; ++flush) {
        for (unsigned i = 0; i < 262144; ++i) birthday.test_blocks(zeros.data(), 16);
        std::vector<PractRand::TestResult> results;
        birthday.get_results(results);
        for (auto r : results) std::printf("%d\t%s\t%.17g\t%.17g\t%.17g\n", flush + 1, r.name.c_str(), r.get_raw(), r.get_suspicion(), r.get_weight());
    }
    birthday.deinit();
    return 0;
}
