#ifndef PRACTRAND_ZIG_BUILTIN_RNGS_H
#define PRACTRAND_ZIG_BUILTIN_RNGS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { PR_RNG_OUTPUT, PR_RNG_SEED_ORIGINAL, PR_RNG_SEED_GRAY, PR_RNG_SEED_BALANCED_GRAY, PR_RNG_ENTROPY };
void *pr_rng_create(const char *, uint64_t, uint64_t, int, unsigned *, char *, size_t);
void *pr_rng_open(const char *, int, unsigned *, char *, size_t);
int pr_rng_seedable(const void *);
int pr_rng_has_stream(const void *);
int pr_rng_seed(void *, uint64_t, uint64_t, char *, size_t);
void pr_rng_destroy(void *);
const char *pr_rng_name(const void *);
int pr_rng_width(const void *);
int pr_rng_fill(void *, unsigned char *, size_t, char *, size_t);
int pr_rng_seed_word(void *, uint64_t, uint64_t, uint64_t *, char *, size_t);
int pr_rng_random_seed(uint64_t *);
size_t pr_rng_factory_count(void);
const char *pr_rng_factory_name(size_t);
const char *pr_rng_catalog_name(unsigned, size_t);
const char *pr_rng_catalog_label(unsigned);
#ifdef __cplusplus
}
#endif
#endif
