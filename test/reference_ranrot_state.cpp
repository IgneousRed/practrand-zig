// Capture only original seeding/state walking; never call its undefined refill.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <list>
#include <deque>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include <PractRand_full.h>
#include <PractRand/RNGs/all.h>
using namespace PractRand;
#include "tools/Candidate_RNGs.h"

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    std::unique_ptr<RNGs::vRNG> rng;
    if (!std::strcmp(argv[1], "32")) rng.reset(new Candidates::polymorphic_ranrot_variant32(SEED_NONE));
    else if (!std::strcmp(argv[1], "64")) rng.reset(new Candidates::polymorphic_ranrot_variant64(SEED_NONE));
    else return 2;
    rng->seed(std::strtoull(argv[2], nullptr, 16), std::strtoull(argv[3], nullptr, 16));
    std::printf("%s\n", rng->print_state().c_str());
    return 0;
}
