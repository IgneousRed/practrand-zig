// Explicit fixture capture only: call the unchanged PractRand CLI formatter.
#define main practrand_original_main
#include "tools/RNG_test.cpp"
#undef main

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const int format = std::atoi(argv[1]);
    if (format != 0 && format != 1 && format != 3) return 2;
    char name[160], kind[32];
    double raw, value, weight;
    while (std::scanf("%159s %31s %lf %lf %lf", name, kind, &raw, &value, &weight) == 5) {
        const char *kinds[] = {"raw", "raw_normal", "bad_p", "bad_s", "good_p", "good_s", "passfail"};
        int type = 0;
        while (type < 7 && std::strcmp(kind, kinds[type])) ++type;
        if (type == 7) return 2;
        print_result(PractRand::TestResult(name, raw, value, type, weight), true, format);
    }
    return std::ferror(stdin) || std::ferror(stdout) ? 1 : 0;
}
