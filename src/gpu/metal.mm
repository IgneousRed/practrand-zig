// Native Metal classification, Mod3/DC7 counters, and an independent FPF owner.
// Service scratch is confined to its worker. The FPF lease includes completion
// and CPU integer merging; authoritative stream totals and histories stay on
// CPU. Window arithmetic draws on prng-playground's gpu_fpf.mm and this
// project's bounded Vulkan kernels, preserving explicit history and first-call
// exclusions.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

constexpr uint32_t threadgroup_size = 256;
constexpr uint32_t fpf_common_exponents = 16;
constexpr uint32_t mod3_tile = 32, dc7_tile = 128;
// Nine levels keep complete pairs and a whole-u32 upper handoff at 1 KiB.
constexpr uint32_t mod3_gpu_layers = 9;

static int fail(char *error, size_t size, const char *message) {
    snprintf(error, size, "%s", message ? message : "native Metal operation failed");
    return -1;
}
struct Context {
    pthread_mutex_t fpf_mutex = PTHREAD_MUTEX_INITIALIZER;
    ~Context() { pthread_mutex_destroy(&fpf_mutex); }
    id<MTLCommandQueue> count_queue = nil;
    id<MTLComputePipelineState> classify = nil, pairs = nil, final_pairs = nil, modhist = nil,
                                dchist = nil, reduce = nil;
    id<MTLBuffer> raw = nil, ties = nil, classified = nil, count_delta = nil, count_output = nil,
                  digit[2] = {nil, nil}, lookup = nil;
    size_t capacity = 0, fpf_capacity = 0;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLComputePipelineState> histogram = nil, reduction = nil;
    id<MTLBuffer> input = nil, delta = nil, output = nil, highest = nil;
    uint32_t dirty_highest = 51;
};
constexpr uint32_t bins = 52 * 16384, shards = 8;
constexpr size_t fpf_batch_factor = 4;
static const char *source = R"MSL(

#include <metal_stdlib>
using namespace metal;
constant uint bins = 52u * 16384u;
struct Parameters {
    uint first_bit, samples;
};
kernel void histogram(device const ulong *input [[buffer(0)]],
                      device atomic_uint *delta [[buffer(1)]], constant Parameters &p [[buffer(2)]],
                      device atomic_uint *highest [[buffer(3)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= p.samples)
        return;
    uint bit = p.first_bit + id * 4u, word = bit >> 6u, shift = bit & 63u;
    ulong value = input[word] >> shift;
    if (shift != 0u)
        value |= input[word + 1u] << (64u - shift);
    uint exponent = min(uint(ctz(value)), 51u);
    uint significand = uint(value >> (exponent + uint(exponent < 51u))) & 16383u;
    // The common prefix is always merged. Only rare exponents consult the
    // bound; once raised, repeated rare windows need no additional atomic writes.
    if (exponent >= FPF_COMMON_EXPONENTS &&
        exponent > atomic_load_explicit(highest, memory_order_relaxed))
        atomic_fetch_max_explicit(highest, exponent, memory_order_relaxed);
    atomic_fetch_add_explicit(delta + (id & 7u) * bins + exponent * 16384u + significand, 1u,
                              memory_order_relaxed);
}
kernel void reduction(device const uint *delta [[buffer(0)]], device uint *output [[buffer(1)]],
                      device const uint *highest [[buffer(2)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= (highest[0] + 1u) * 16384u)
        return;
    uint total = 0;
    for (uint shard = 0; shard < 8u; ++shard)
        total += delta[shard * bins + id];
    output[id] = total;
}
)MSL";
static bool prepare(Context *t, char *error, size_t size) {
    @autoreleasepool {
        if (t->histogram)
            return true;
        NSError *problem = nil;
        auto options = [MTLCompileOptions new];
        options.preprocessorMacros = @{@"FPF_COMMON_EXPONENTS" : @(fpf_common_exponents)};
        id<MTLLibrary> library =
            [t->device newLibraryWithSource:[NSString stringWithUTF8String:source]
                                    options:options
                                      error:&problem];
        if (!library) {
            fail(error, size, problem.localizedDescription.UTF8String);
            return false;
        }
        auto histogram = [t->device
            newComputePipelineStateWithFunction:[library newFunctionWithName:@"histogram"]
                                          error:&problem];
        auto reduction = [t->device
            newComputePipelineStateWithFunction:[library newFunctionWithName:@"reduction"]
                                          error:&problem];
        if (!histogram || !reduction) {
            fail(error, size, problem.localizedDescription.UTF8String);
            return false;
        }
        if (histogram.maxTotalThreadsPerThreadgroup < threadgroup_size ||
            reduction.maxTotalThreadsPerThreadgroup < threadgroup_size) {
            fail(error, size, "Metal FPF threadgroup size is unsupported");
            return false;
        }
        t->input = [t->device newBufferWithLength:t->capacity + 8
                                          options:MTLResourceStorageModeShared];
        t->delta = [t->device newBufferWithLength:size_t(bins) * shards * 4
                                          options:MTLResourceStorageModePrivate];
        t->output = [t->device newBufferWithLength:size_t(bins) * 4
                                           options:MTLResourceStorageModeShared];
        t->highest = [t->device newBufferWithLength:sizeof(uint32_t)
                                            options:MTLResourceStorageModeShared];
        if (!t->input || !t->delta || !t->output || !t->highest) {
            fail(error, size, "Metal FPF allocation failed");
            return false;
        }
        t->histogram = histogram;
        t->reduction = reduction;
        return true;
    }
}

// The service owns these buffers independently from the locked FPF scratch.
struct Parameters {
    uint32_t samples, bytes, kind, level, bins, layers, tile, odd, mask, initial[9], warmup[9];
};
static const char *count_source = R"MSL(

#include <metal_stdlib>
using namespace metal;
struct Parameters {
    uint samples, bytes, kind, level, bins, layers, tile, odd, mask, initial[9], warmup[9];
};
kernel void classify(device const uint4 *input [[buffer(0)]], device const uint *ties [[buffer(1)]],
                     device uchar *output [[buffer(2)]], constant uint &outputs [[buffer(3)]],
                     uint id [[thread_position_in_grid]]) {
    if (id >= outputs)
        return;
    uint4 value = input[id];
    uint random = ties[id / 2] >> ((id & 1u) * 8u), result = 0;
    const uint masks[5] = {0x55555555u, 0x33333333u, 0x0f0f0f0fu, 0x00ff00ffu, 0x0000ffffu};
    for (uint bit = 0; bit < 8; ++bit) {
        uint4 mask = bit < 5    ? uint4(masks[bit])
                     : bit == 5 ? uint4(~0u, 0, ~0u, 0)
                     : bit == 6 ? uint4(~0u, ~0u, 0, 0)
                                : uint4(0);
        uint4 c = popcount(value ^ mask);
        uint count = c.x + c.y + c.z + c.w;
        result = (result << 1) | uint(count > 64 || (count == 64 && (random & 1u)));
        random >>= 1;
    }
    output[id] = uchar(result);
}
kernel void pairs(device const uchar *input [[buffer(0)]], device uchar *output [[buffer(1)]],
                  constant Parameters &p [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id < (p.bytes >> p.level))
        output[id] = (uint(input[id * 2]) + input[id * 2 + 1]) % 3u;
}
kernel void final_pairs(device const uchar *input [[buffer(0)]],
                        device ushort *output [[buffer(1)]], constant Parameters &p [[buffer(2)]],
                        uint id [[thread_position_in_grid]]) {
    if (id < (p.bytes >> p.level))
        output[p.bins * p.layers * 2u + id] = (uint(input[id * 2]) + input[id * 2 + 1]) % 3u;
}
kernel void modhist(device const uchar *input [[buffer(0)]],
                    device atomic_uint *delta [[buffer(1)]], constant Parameters &p [[buffer(2)]],
                    uint id [[thread_position_in_grid]]) {
    uint start = id * p.tile;
    if (start >= p.samples)
        return;
    uint begin = start ? start - 8 : 0, index = start ? 0 : p.initial[p.level],
         end = min(start + p.tile, p.samples);
    for (uint i = begin; i < end; ++i) {
        index = index * 3u + (p.level == 0 ? uint(input[i]) % 3u : uint(input[i]));
        index -= index >= p.bins * 2 ? p.bins * 2 : 0;
        index -= index >= p.bins ? p.bins : 0;
        if (i >= start && i >= p.warmup[p.level])
            atomic_fetch_add_explicit(delta + (p.level * 8 + (id & 7)) * p.bins + index, 1u,
                                      memory_order_relaxed);
    }
}
kernel void dchist(device const uchar *input [[buffer(0)]], device atomic_uint *delta [[buffer(1)]],
                   constant Parameters &p [[buffer(2)]], device const uint *lookup [[buffer(3)]],
                   uint id [[thread_position_in_grid]]) {
    uint start = id * p.tile;
    if (start >= p.samples)
        return;
    uint begin = start ? start - 8 : 0, index = start ? 0 : p.initial[0],
         end = min(start + p.tile, p.samples);
    for (uint i = begin; i < end; ++i) {
        index = ((index & p.mask) << 1) | lookup[input[i]];
        if (i >= start && i >= p.warmup[0])
            atomic_fetch_add_explicit(delta + (id & 7) * p.bins + ((p.odd + i) & 1) * (p.bins / 2) +
                                          index,
                                      1u, memory_order_relaxed);
    }
}
kernel void reduce_counts(device const uint *delta [[buffer(0)]], device uint *output [[buffer(1)]],
                          constant Parameters &p [[buffer(2)]],
                          uint id [[thread_position_in_grid]]) {
    if (id >= p.bins * p.layers)
        return;
    uint level = id / p.bins, bin = id % p.bins, total = 0;
    for (uint shard = 0; shard < 8; ++shard)
        total += delta[(level * 8 + shard) * p.bins + bin];
    output[id] = total;
}
)MSL";
static bool prepare_counts(Context *t, char *error, size_t size) {
    @autoreleasepool {
        if (t->count_delta)
            return true;
        auto delta = [t->device newBufferWithLength:2u * 262144u * 8u * 4u
                                            options:MTLResourceStorageModePrivate];
        auto output = [t->device newBufferWithLength:2u * 262144u * 4u
                                             options:MTLResourceStorageModeShared];
        auto a = [t->device newBufferWithLength:t->capacity / 4
                                        options:MTLResourceStorageModePrivate];
        auto b = [t->device newBufferWithLength:t->capacity / 2
                                        options:MTLResourceStorageModePrivate];
        auto lookup = [t->device newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared];
        if (!delta || !output || !a || !b || !lookup) {
            fail(error, size, "Metal count allocation failed");
            return false;
        }
        t->count_delta = delta;
        t->count_output = output;
        t->digit[0] = a;
        t->digit[1] = b;
        t->lookup = lookup;
        return true;
    }
}
static void dispatch(id<MTLComputeCommandEncoder> encoder, id<MTLComputePipelineState> pipeline,
                     id<MTLBuffer> input, id<MTLBuffer> output, const Parameters &p, uint32_t work,
                     id<MTLBuffer> lookup = nil) {
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:input offset:0 atIndex:0];
    [encoder setBuffer:output offset:0 atIndex:1];
    [encoder setBytes:&p length:sizeof(p) atIndex:2];
    if (lookup)
        [encoder setBuffer:lookup offset:0 atIndex:3];
    [encoder
         dispatchThreadgroups:MTLSizeMake((work + threadgroup_size - 1) / threadgroup_size, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(threadgroup_size, 1, 1)];
}
static bool complete(id<MTLCommandBuffer> command, char *error, size_t size) {
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        fail(error, size, command.error.localizedDescription.UTF8String);
        return false;
    }
    return true;
}
extern "C" uint32_t pr_gpu_api_version() { return 11; }
// Optional capacity metadata keeps older 16 MiB backends compatible.
extern "C" size_t pr_gpu_fpf_capacity_v1(void *raw) {
    return static_cast<Context *>(raw)->fpf_capacity;
}
extern "C" void *pr_gpu_create(size_t capacity, char *name, size_t name_size, char *error,
                               size_t size) {
    @autoreleasepool {
        if (!capacity || capacity > (16u << 20) || capacity % 1024) {
            fail(error, size, "invalid Metal capacity");
            return nullptr;
        }
        auto t = new Context();
        t->capacity = capacity;
        t->fpf_capacity = capacity * fpf_batch_factor;
        t->device = MTLCreateSystemDefaultDevice();
        t->queue = [t->device newCommandQueue];
        t->count_queue = [t->device newCommandQueue];
        if (!t->device || !t->queue || !t->count_queue) {
            delete t;
            fail(error, size, "no Metal device/queues");
            return nullptr;
        }
        NSError *problem = nil;
        auto library = [t->device newLibraryWithSource:[NSString stringWithUTF8String:count_source]
                                               options:nil
                                                 error:&problem];
        if (!library) {
            fail(error, size, problem.localizedDescription.UTF8String);
            delete t;
            return nullptr;
        }
        auto pipeline = [&](NSString *n) {
            return [t->device newComputePipelineStateWithFunction:[library newFunctionWithName:n]
                                                            error:&problem];
        };
        t->classify = pipeline(@"classify");
        t->pairs = pipeline(@"pairs");
        t->final_pairs = pipeline(@"final_pairs");
        t->modhist = pipeline(@"modhist");
        t->dchist = pipeline(@"dchist");
        t->reduce = pipeline(@"reduce_counts");
        if (!t->classify || !t->pairs || !t->final_pairs || !t->modhist || !t->dchist ||
            !t->reduce) {
            fail(error, size, problem.localizedDescription.UTF8String);
            delete t;
            return nullptr;
        }
        id<MTLComputePipelineState> pipelines[] = {t->classify, t->pairs,  t->final_pairs,
                                                   t->modhist,  t->dchist, t->reduce};
        for (auto pipeline : pipelines)
            if (pipeline.maxTotalThreadsPerThreadgroup < threadgroup_size) {
                fail(error, size, "Metal counter threadgroup size is unsupported");
                delete t;
                return nullptr;
            }
        t->raw = [t->device newBufferWithLength:capacity options:MTLResourceStorageModeShared];
        t->ties = [t->device newBufferWithLength:capacity / 8 options:MTLResourceStorageModeShared];
        t->classified = [t->device newBufferWithLength:capacity / 16
                                               options:MTLResourceStorageModeShared];
        if (!t->raw || !t->ties || !t->classified) {
            delete t;
            fail(error, size, "Metal classification allocation failed");
            return nullptr;
        }
        snprintf(name, name_size, "native Metal %s", t->device.name.UTF8String);
        return t;
    }
}
extern "C" void pr_gpu_destroy(void *raw) { delete static_cast<Context *>(raw); }
extern "C" uint32_t pr_gpu_count_supported(void *) { return 1; }
extern "C" int pr_gpu_classify(void *raw, const uint8_t *in, size_t bytes, const uint32_t *ties,
                               uint8_t *out, char *error, size_t size) {
    @autoreleasepool {
        auto t = static_cast<Context *>(raw);
        if (bytes > t->capacity || bytes % 32)
            return fail(error, size, "invalid Metal classification input");
        if (!bytes)
            return 0;
        memcpy(t->raw.contents, in, bytes);
        memcpy(t->ties.contents, ties, bytes / 8);
        auto command = [t->count_queue commandBuffer];
        auto encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:t->classify];
        [encoder setBuffer:t->raw offset:0 atIndex:0];
        [encoder setBuffer:t->ties offset:0 atIndex:1];
        [encoder setBuffer:t->classified offset:0 atIndex:2];
        uint32_t outputs = uint32_t(bytes / 16);
        [encoder setBytes:&outputs length:sizeof(outputs) atIndex:3];
        [encoder dispatchThreadgroups:MTLSizeMake(
                                          (outputs + threadgroup_size - 1) / threadgroup_size, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadgroup_size, 1, 1)];
        [encoder endEncoding];
        if (!complete(command, error, size))
            return -1;
        memcpy(out, t->classified.contents, outputs);
        return 0;
    }
}
static int count(void *raw, uint32_t kind, const uint8_t *in, size_t bytes,
                 const uint32_t *initial, const uint32_t *warmup, uint32_t odd,
                 uint32_t mask, const uint32_t *lookup, const uint32_t **result,
                 char *error, size_t size, uint32_t mod3_layers) {
    @autoreleasepool {
        auto t = static_cast<Context *>(raw);
        if (!bytes || bytes > t->capacity || bytes % 1024 || (kind != 0 && kind != 2) ||
            (kind == 2 && !lookup))
            return fail(error, size, "invalid Metal counter input");
        if (!prepare_counts(t, error, size))
            return -1;
        Parameters p = {};
        p.bytes = uint32_t(bytes);
        p.kind = kind;
        p.bins = kind == 0 ? 19683 : 524288;
        p.layers = kind == 0 ? mod3_layers : 1;
        p.tile = kind == 0 ? mod3_tile : dc7_tile;
        p.odd = odd;
        p.mask = mask;
        // The original entry point still borrows only six Mod3 history words.
        memcpy(p.initial, initial, p.layers * sizeof(uint32_t));
        memcpy(p.warmup, warmup, p.layers * sizeof(uint32_t));
        memcpy(t->raw.contents, in, bytes);
        if (kind == 2)
            memcpy(t->lookup.contents, lookup, 256 * 4);
        auto command = [t->count_queue commandBuffer];
        auto clear = [command blitCommandEncoder];
        [clear fillBuffer:t->count_delta
                    range:NSMakeRange(0, size_t(p.bins) * p.layers * 8 * 4)
                    value:0];
        [clear endEncoding];
        // A serial encoder preserves each producer/consumer dispatch dependency.
        // Reuse it for the entire counter pass instead of creating one per kernel.
        auto encoder = [command computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];

        for (p.level = 0; p.level < p.layers; ++p.level) {
            p.samples = p.bytes >> p.level;
            if (p.level)
                dispatch(encoder, t->pairs, p.level == 1 ? t->raw : t->digit[(p.level - 1) & 1],
                         t->digit[p.level & 1], p, p.samples);
            dispatch(encoder, kind == 0 ? t->modhist : t->dchist,
                     kind == 0 && p.level != 0 ? t->digit[p.level & 1] : t->raw, t->count_delta, p,
                     (p.samples + p.tile - 1) / p.tile, kind == 2 ? t->lookup : nil);
        }
        if (kind == 0) {
            p.level = p.layers;
            dispatch(encoder, t->final_pairs, t->digit[(p.level - 1) & 1], t->count_output, p,
                     p.bytes >> p.level);
        }
        dispatch(encoder, t->reduce, t->count_delta, t->count_output, p, p.bins * p.layers);
        [encoder endEncoding];

        if (!complete(command, error, size))
            return -1;
        *result = static_cast<const uint32_t *>(t->count_output.contents);
        return 0;
    }
}

// Preserve the version-11 entry point and result layout for existing clients.
extern "C" int pr_gpu_count(void *raw, uint32_t kind, const uint8_t *in, size_t bytes,
                            const uint32_t *initial, const uint32_t *warmup, uint32_t odd,
                            uint32_t mask, const uint32_t *lookup, const uint32_t **result,
                            char *error, size_t size) {
    return count(raw, kind, in, bytes, initial, warmup, odd, mask, lookup, result, error, size, 6);
}
extern "C" uint32_t pr_gpu_mod3_layers_v1(void *) { return mod3_gpu_layers; }
extern "C" int pr_gpu_mod3_count_v1(void *raw, uint32_t kind, const uint8_t *in, size_t bytes,
                                   const uint32_t *initial, const uint32_t *warmup, uint32_t odd,
                                   uint32_t mask, const uint32_t *lookup, const uint32_t **result,
                                   char *error, size_t size) {
    if (kind != 0)
        return fail(error, size, "invalid extended Metal Mod3 kind");
    return count(raw, kind, in, bytes, initial, warmup, odd, mask, lookup, result, error, size,
                 mod3_gpu_layers);
}

struct FpfLock {
    pthread_mutex_t *p;
    explicit FpfLock(pthread_mutex_t &value) : p(&value) { pthread_mutex_lock(p); }
    ~FpfLock() { pthread_mutex_unlock(p); }
};
static int fpf_count(Context *t, const uint8_t *in, size_t bytes, const uint8_t *tail,
                     uint32_t started, const uint32_t **result, char *error, size_t size) {
    if (!bytes || bytes > t->fpf_capacity || bytes % 1024)
        return fail(error, size, "invalid single-call Metal FPF input");
    if (!prepare(t, error, size))
        return -1;
    // Grow only this independent owner's input scratch. The lease and command
    // completion keep the previous allocation private until it can be released.
    if (bytes + 8 > t->input.length) {
        auto input = [t->device newBufferWithLength:bytes + 8 options:MTLResourceStorageModeShared];
        if (!input)
            return fail(error, size, "Metal FPF input allocation failed");
        t->input = input;
    }
    *static_cast<uint32_t *>(t->highest.contents) = fpf_common_exponents - 1;
    memcpy(t->input.contents, tail, 8);
    memcpy((uint8_t *)t->input.contents + 8, in, bytes);
    uint32_t parameters[2] = {started ? 4u : 68u, uint32_t(bytes * 2 - (started ? 0 : 16))};
    auto command = [t->queue commandBuffer];
    auto clear = [command blitCommandEncoder];
    // Keep all replicas for structured inputs; clear only the prefix that
    // the preceding call could have changed in each independently placed shard.
    for (uint32_t shard = 0; shard < shards; ++shard) {
        [clear fillBuffer:t->delta
                    range:NSMakeRange(size_t(shard) * bins * 4,
                                      size_t(t->dirty_highest + 1) * 16384 * 4)
                    value:0];
    }
    [clear endEncoding];
    auto histogram = [command computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
    [histogram setComputePipelineState:t->histogram];
    [histogram setBuffer:t->input offset:0 atIndex:0];
    [histogram setBuffer:t->delta offset:0 atIndex:1];
    [histogram setBytes:parameters length:sizeof(parameters) atIndex:2];
    [histogram setBuffer:t->highest offset:0 atIndex:3];
    [histogram
         dispatchThreadgroups:MTLSizeMake((parameters[1] + threadgroup_size - 1) / threadgroup_size,
                                          1, 1)
        threadsPerThreadgroup:MTLSizeMake(threadgroup_size, 1, 1)];
    auto reduction = histogram;
    [reduction setComputePipelineState:t->reduction];
    [reduction setBuffer:t->delta offset:0 atIndex:0];
    [reduction setBuffer:t->output offset:0 atIndex:1];
    [reduction setBuffer:t->highest offset:0 atIndex:2];
    [reduction
         dispatchThreadgroups:MTLSizeMake((bins + threadgroup_size - 1) / threadgroup_size, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(threadgroup_size, 1, 1)];
    [reduction endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        t->dirty_highest = 51;
        return fail(error, size, command.error.localizedDescription.UTF8String);
    }
    t->dirty_highest = *static_cast<const uint32_t *>(t->highest.contents);
    *result = (const uint32_t *)t->output.contents;
    return 0;
}
extern "C" int pr_gpu_fpf_add_v1(void *raw, const uint8_t *in, size_t bytes, const uint8_t *tail,
                                 uint32_t started, uint64_t *totals, char *error, size_t size) {
    @autoreleasepool {
        auto t = (Context *)raw;
        FpfLock lock(t->fpf_mutex);
        const uint32_t *values = nullptr;
        const int status = fpf_count(t, in, bytes, tail, started, &values, error, size);
        if (status)
            return status;
        for (uint32_t i = 0; i < (t->dirty_highest + 1) * 16384; ++i)
            totals[i] += values[i];
        return 0;
    }
}
