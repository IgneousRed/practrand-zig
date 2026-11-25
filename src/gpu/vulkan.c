// Vulkan service and independent FPF lease own separate scratch and commands.
// Queue submission is synchronized briefly; neither owner holds that lock while waiting.
#define _POSIX_C_SOURCE 200809L
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "classification.h"
#include "counts.h"
#include "fpf.h"

typedef struct {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *mapped;
    VkMemoryPropertyFlags flags;
} Allocation;
typedef struct {
    Allocation host, local;
} Buffer;
// Current kernels share one storage-buffer set and one push-constant block.
enum { program_max_bindings = 3, dc7_lookup_bytes = 256u * sizeof(uint32_t) };
typedef struct {
    VkDescriptorSetLayout set_layout;
    VkPipelineLayout layout;
    VkShaderModule shader;
    VkPipeline pipeline;
    VkDescriptorPool pool;
    VkDescriptorSet set;
} Program;
typedef struct {
    VkCommandPool pool;
    VkCommandBuffer buffer;
    VkFence fence;
} Commands;
typedef struct CountContext CountContext;
typedef struct FpfContext FpfContext;
typedef struct {
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue, fpf_queue;
    uint32_t queue_family, max_groups_x;
    pthread_mutex_t queue_mutex, fpf_mutex;
    VkBool32 queue_mutex_ready, fpf_mutex_ready;
    FpfContext *fpf;
    size_t fpf_capacity;
    Buffer buffers[3];
    Program program;
    Commands commands;
    size_t capacity;
    CountContext *counts;
    uint32_t supports_counts;
} Context;

#define CHECK(call) do { VkResult status_ = (call); if (status_ != VK_SUCCESS) { snprintf(error, error_size, "%s: VkResult %d", #call, status_); return -1; } } while (0)

static void release_allocation(VkDevice device, Allocation *b) {
    if (b->mapped) vkUnmapMemory(device, b->memory);
    if (b->buffer) vkDestroyBuffer(device, b->buffer, NULL);
    if (b->memory) vkFreeMemory(device, b->memory, NULL);
}

// On failure, the owner releases any handles already stored in the zeroed buffer.
static int allocate_buffer(Context *t, Allocation *b, VkDeviceSize bytes, VkBool32 mapped, char *error, size_t error_size) {
    VkBufferCreateInfo info = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = bytes,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    CHECK(vkCreateBuffer(t->device, &info, NULL, &b->buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(t->device, b->buffer, &requirements);
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(t->physical, &properties);
    uint32_t type = UINT32_MAX;
    for (unsigned pass = 0; pass < 2 && type == UINT32_MAX; ++pass) {
        VkMemoryPropertyFlags wanted = mapped ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | (pass == 0 ? VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : 0)
                                             : (pass == 0 ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT : 0);
        for (uint32_t i = 0; i < properties.memoryTypeCount; ++i)
            if ((requirements.memoryTypeBits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) { type = i; break; }
    }
    if (type == UINT32_MAX) { snprintf(error, error_size, "no suitable Vulkan buffer memory"); return -1; }
    b->flags = properties.memoryTypes[type].propertyFlags;
    VkMemoryAllocateInfo allocation = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = type};
    CHECK(vkAllocateMemory(t->device, &allocation, NULL, &b->memory));
    CHECK(vkBindBufferMemory(t->device, b->buffer, b->memory, 0));
    if (mapped) CHECK(vkMapMemory(t->device, b->memory, 0, VK_WHOLE_SIZE, 0, &b->mapped));
    return 0;
}

static void destroy_buffer(VkDevice device, Buffer *b) {
    release_allocation(device, &b->local);
    release_allocation(device, &b->host);
}
static int create_buffer(Context *t, Buffer *b, VkDeviceSize bytes, char *error, size_t error_size) {
    if (allocate_buffer(t, &b->host, bytes, VK_TRUE, error, error_size)) return -1;
    // Unified memory can be bound directly. Keep shader reads and atomics
    // in device-local memory when a mapped allocation lives on another heap.
    if (b->host.flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) return 0;
    return allocate_buffer(t, &b->local, bytes, VK_FALSE, error, error_size);
}
static VkBuffer storage(const Buffer *b) {
    return b->local.buffer ? b->local.buffer : b->host.buffer;
}
static void memory_barrier(VkCommandBuffer command, VkPipelineStageFlags from_stage, VkAccessFlags from_access,
    VkPipelineStageFlags to_stage, VkAccessFlags to_access) {
    const VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = from_access, .dstAccessMask = to_access};
    vkCmdPipelineBarrier(command, from_stage, to_stage, 0, 1, &barrier, 0, NULL, 0, NULL);
}
static int upload(Context *t, VkCommandBuffer command, const Buffer *b, VkDeviceSize bytes, char *error, size_t error_size) {
    const VkMappedMemoryRange range = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = b->host.memory, .size = VK_WHOLE_SIZE};
    if (!(b->host.flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) CHECK(vkFlushMappedMemoryRanges(t->device, 1, &range));
    // Queue submission makes prior coherent or flushed host writes available.
    if (b->local.buffer && bytes) {
        const VkBufferCopy copy = {.size = bytes};
        vkCmdCopyBuffer(command, b->host.buffer, b->local.buffer, 1, &copy);
    }
    return 0;
}
static void transfers_to_compute(VkCommandBuffer command) {
    memory_barrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT);
}

static void destroy_program(VkDevice device, Program *p) {
    if (p->pool) vkDestroyDescriptorPool(device, p->pool, NULL);
    if (p->pipeline) vkDestroyPipeline(device, p->pipeline, NULL);
    if (p->shader) vkDestroyShaderModule(device, p->shader, NULL);
    if (p->layout) vkDestroyPipelineLayout(device, p->layout, NULL);
    if (p->set_layout) vkDestroyDescriptorSetLayout(device, p->set_layout, NULL);
}

static int create_program(Context *t, Program *p, const uint32_t *code, size_t code_size,
    const VkDescriptorBufferInfo *infos, uint32_t bindings_count, uint32_t push_size,
    char *error, size_t error_size) {
    VkDescriptorSetLayoutBinding bindings[program_max_bindings];
    for (uint32_t i = 0; i < bindings_count; ++i) bindings[i] = (VkDescriptorSetLayoutBinding){
        .binding = i, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT};
    VkDescriptorSetLayoutCreateInfo set_layout = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings_count, .pBindings = bindings};
    CHECK(vkCreateDescriptorSetLayout(t->device, &set_layout, NULL, &p->set_layout));
    VkPushConstantRange push = {.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .size = push_size};
    VkPipelineLayoutCreateInfo layout = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &p->set_layout, .pushConstantRangeCount = 1, .pPushConstantRanges = &push};
    CHECK(vkCreatePipelineLayout(t->device, &layout, NULL, &p->layout));
    VkShaderModuleCreateInfo shader = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = code_size, .pCode = code};
    CHECK(vkCreateShaderModule(t->device, &shader, NULL, &p->shader));
    VkComputePipelineCreateInfo pipeline = {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .layout = p->layout,
        .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = p->shader, .pName = "main"}};
    CHECK(vkCreateComputePipelines(t->device, VK_NULL_HANDLE, 1, &pipeline, NULL, &p->pipeline));
    VkDescriptorPoolSize pool_size = {.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = bindings_count};
    VkDescriptorPoolCreateInfo pool = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size};
    CHECK(vkCreateDescriptorPool(t->device, &pool, NULL, &p->pool));
    VkDescriptorSetAllocateInfo set = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = p->pool, .descriptorSetCount = 1, .pSetLayouts = &p->set_layout};
    CHECK(vkAllocateDescriptorSets(t->device, &set, &p->set));
    VkWriteDescriptorSet writes[program_max_bindings];
    for (uint32_t i = 0; i < bindings_count; ++i) writes[i] = (VkWriteDescriptorSet){
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = p->set, .dstBinding = i,
        .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &infos[i]};
    vkUpdateDescriptorSets(t->device, bindings_count, writes, 0, NULL);
    return 0;
}

static void destroy_counts(Context *t);
static void destroy_fpf(Context *t);
static VkResult queue_submit(Context *t, VkQueue queue, const VkSubmitInfo *submit, VkFence fence) {
    pthread_mutex_lock(&t->queue_mutex);
    const VkResult result = vkQueueSubmit(queue, 1, submit, fence);
    pthread_mutex_unlock(&t->queue_mutex);
    return result;
}
static void destroy_commands(VkDevice device, Commands *c) {
    if (c->fence) vkDestroyFence(device, c->fence, NULL);
    if (c->pool) vkDestroyCommandPool(device, c->pool, NULL);
}
static int create_commands(Context *t, Commands *c, char *error, size_t error_size) {
    VkCommandPoolCreateInfo pool = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = t->queue_family};
    CHECK(vkCreateCommandPool(t->device, &pool, NULL, &c->pool));
    VkCommandBufferAllocateInfo buffer = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = c->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    CHECK(vkAllocateCommandBuffers(t->device, &buffer, &c->buffer));
    VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    CHECK(vkCreateFence(t->device, &fence, NULL, &c->fence));
    return 0;
}
static int begin_commands(Context *t, Commands *c, char *error, size_t error_size) {
    CHECK(vkResetCommandBuffer(c->buffer, 0));
    CHECK(vkResetFences(t->device, 1, &c->fence));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    CHECK(vkBeginCommandBuffer(c->buffer, &begin));
    return 0;
}
static int finish_commands(Context *t, Commands *c, VkQueue queue, const Buffer *output, VkDeviceSize bytes,
    char *error, size_t error_size) {
    const VkPipelineStageFlags writers = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT;
    const VkAccessFlags writes = VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT;
    if (output->local.buffer && bytes) {
        memory_barrier(c->buffer, writers, writes, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT);
        const VkBufferCopy copy = {.size = bytes};
        vkCmdCopyBuffer(c->buffer, output->local.buffer, output->host.buffer, 1, &copy);
    }
    memory_barrier(c->buffer, writers, writes, VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_READ_BIT);
    CHECK(vkEndCommandBuffer(c->buffer));
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1, .pCommandBuffers = &c->buffer};
    CHECK(queue_submit(t, queue, &submit, c->fence));
    CHECK(vkWaitForFences(t->device, 1, &c->fence, VK_TRUE, UINT64_MAX));
    const VkMappedMemoryRange range = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = output->host.memory, .size = VK_WHOLE_SIZE};
    if (!(output->host.flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) CHECK(vkInvalidateMappedMemoryRanges(t->device, 1, &range));
    return 0;
}
static uint32_t count_supported(Context *t, const VkPhysicalDeviceProperties *properties);
uint32_t pr_gpu_api_version(void) { return 11; }
void pr_gpu_destroy(void *raw) {
    Context *t = raw;
    if (!t) return;
    if (t->device) {
        (void)vkDeviceWaitIdle(t->device);
        destroy_counts(t);
        destroy_fpf(t);
        destroy_commands(t->device, &t->commands);
        destroy_program(t->device, &t->program);
        for (unsigned i = 0; i < 3; ++i) destroy_buffer(t->device, &t->buffers[i]);
        vkDestroyDevice(t->device, NULL);
    }
    if (t->instance) vkDestroyInstance(t->instance, NULL);
    if (t->fpf_mutex_ready) pthread_mutex_destroy(&t->fpf_mutex);
    if (t->queue_mutex_ready) pthread_mutex_destroy(&t->queue_mutex);
    free(t);
}

static uint32_t compute_family(VkPhysicalDevice device, uint32_t *queues) {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(device, &count, NULL);
    VkQueueFamilyProperties *families = calloc(count, sizeof(*families));
    if (!families) return UINT32_MAX;
    vkGetPhysicalDeviceQueueFamilyProperties(device, &count, families);
    uint32_t result = UINT32_MAX;
    for (uint32_t i = 0; i < count; ++i) if (families[i].queueCount && (families[i].queueFlags & VK_QUEUE_COMPUTE_BIT)) { result = i; *queues = families[i].queueCount; break; }
    free(families);
    return result;
}

// Portability drivers need explicit instance enumeration and device enablement.
// Query these extensions instead of assuming every Mac driver advertises them.
static VkResult has_extension(VkPhysicalDevice physical, const char *name, VkBool32 *present) {
    uint32_t count = 0;
    *present = VK_FALSE;
    VkResult result = physical ? vkEnumerateDeviceExtensionProperties(physical, NULL, &count, NULL)
                               : vkEnumerateInstanceExtensionProperties(NULL, &count, NULL);
    if (result != VK_SUCCESS || count == 0) return result;
    VkExtensionProperties *items = calloc(count, sizeof(*items));
    if (!items) return VK_ERROR_OUT_OF_HOST_MEMORY;
    result = physical ? vkEnumerateDeviceExtensionProperties(physical, NULL, &count, items)
                      : vkEnumerateInstanceExtensionProperties(NULL, &count, items);
    if (result == VK_SUCCESS) for (uint32_t i = 0; i < count; ++i)
        if (strcmp(items[i].extensionName, name) == 0) { *present = VK_TRUE; break; }
    free(items);
    return result;
}

static int create_context(Context *t, size_t capacity, char *name, size_t name_size, char *error, size_t error_size) {
    if (pthread_mutex_init(&t->queue_mutex, NULL)) { snprintf(error, error_size, "Vulkan queue mutex initialization failed"); return -1; }
    t->queue_mutex_ready = VK_TRUE;
    if (pthread_mutex_init(&t->fpf_mutex, NULL)) { snprintf(error, error_size, "Vulkan FPF mutex initialization failed"); return -1; }
    t->fpf_mutex_ready = VK_TRUE;
    VkApplicationInfo application = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "practrand-zig", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo instance = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &application};
    VkBool32 portability = VK_FALSE;
    const char *enumeration = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    CHECK(has_extension(VK_NULL_HANDLE, enumeration, &portability));
    if (portability) {
        instance.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        instance.enabledExtensionCount = 1;
        instance.ppEnabledExtensionNames = &enumeration;
    }
    CHECK(vkCreateInstance(&instance, NULL, &t->instance));
    uint32_t count = 0;
    CHECK(vkEnumeratePhysicalDevices(t->instance, &count, NULL));
    if (!count) { snprintf(error, error_size, "no Vulkan GPU; check the loader/driver environment"); return -1; }
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices) { snprintf(error, error_size, "Vulkan device-list allocation failed"); return -1; }
    VkResult enumerated = vkEnumeratePhysicalDevices(t->instance, &count, devices);
    if (enumerated != VK_SUCCESS) { free(devices); snprintf(error, error_size, "Vulkan device enumeration failed: %d", enumerated); return -1; }
    uint32_t family = UINT32_MAX, available_queues = 1;
    int best = -1;
    VkPhysicalDeviceProperties properties = {0};
    for (uint32_t i = 0; i < count; ++i) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(devices[i], &p);
        if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) continue;
        uint32_t queues = 0;
        uint32_t f = compute_family(devices[i], &queues);
        if (f == UINT32_MAX || p.apiVersion < VK_API_VERSION_1_1 || p.limits.maxStorageBufferRange < capacity) continue;
        int rank = p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ? 2 : 1;
        if (rank > best) { t->physical = devices[i]; family = f; available_queues = queues; properties = p; best = rank; }
    }
    free(devices);
    if (best < 0) { snprintf(error, error_size, "no hardware Vulkan 1.1 compute device with sufficient storage buffers"); return -1; }
    snprintf(name, name_size, "Vulkan %s", properties.deviceName);
    const float priority[2] = {1, 1};
    const uint32_t queue_count = available_queues > 1 ? 2 : 1;
    VkDeviceQueueCreateInfo queue = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family, .queueCount = queue_count, .pQueuePriorities = priority};
    VkDeviceCreateInfo device = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue};
    const char *subset = "VK_KHR_portability_subset";
    CHECK(has_extension(t->physical, subset, &portability));
    if (portability) { device.enabledExtensionCount = 1; device.ppEnabledExtensionNames = &subset; }
    CHECK(vkCreateDevice(t->physical, &device, NULL, &t->device));
    vkGetDeviceQueue(t->device, family, 0, &t->queue);
    vkGetDeviceQueue(t->device, family, queue_count - 1, &t->fpf_queue);
    t->queue_family = family;
    t->max_groups_x = properties.limits.maxComputeWorkGroupCount[0];
    t->fpf_capacity = capacity < (32u << 20) ? capacity * 2 : (64u << 20);
    const VkDeviceSize sizes[3] = {capacity + dc7_lookup_bytes, capacity / 32 * sizeof(uint32_t), (capacity / 16 + 3) / 4 * sizeof(uint32_t)};
    VkDescriptorBufferInfo infos[3];
    for (uint32_t i = 0; i < 3; ++i) {
        Buffer *b = &t->buffers[i];
        if (create_buffer(t, b, sizes[i], error, error_size)) return -1;
        infos[i] = (VkDescriptorBufferInfo){.buffer = storage(b), .range = i == 0 ? capacity : sizes[i]};
    }
    if (create_program(t, &t->program, classification_spv, sizeof(classification_spv),
        infos, 3, sizeof(uint32_t), error, error_size)) return -1;
    if (create_commands(t, &t->commands, error, error_size)) return -1;
    t->capacity = capacity;
    t->supports_counts = count_supported(t, &properties);
    return 0;
}
void *pr_gpu_create(size_t capacity, char *name, size_t name_size, char *error, size_t error_size) {
    Context *t = calloc(1, sizeof(*t));
    if (!t) { snprintf(error, error_size, "Vulkan context allocation failed"); return NULL; }
    if (create_context(t, capacity, name, name_size, error, error_size)) {
        pr_gpu_destroy(t);
        return NULL;
    }
    return t;
}

int pr_gpu_classify(void *raw, const uint8_t *input, size_t bytes, const uint32_t *ties, uint8_t *output, char *error, size_t error_size) {
    Context *t = raw;
    memcpy(t->buffers[0].host.mapped, input, bytes);
    memcpy(t->buffers[1].host.mapped, ties, bytes / 32 * sizeof(uint32_t));
    if (begin_commands(t, &t->commands, error, error_size)) return -1;
    if (upload(t, t->commands.buffer, &t->buffers[0], bytes, error, error_size) ||
        upload(t, t->commands.buffer, &t->buffers[1], bytes / 32 * sizeof(uint32_t), error, error_size)) return -1;
    transfers_to_compute(t->commands.buffer);
    vkCmdBindPipeline(t->commands.buffer, VK_PIPELINE_BIND_POINT_COMPUTE, t->program.pipeline);
    vkCmdBindDescriptorSets(t->commands.buffer, VK_PIPELINE_BIND_POINT_COMPUTE, t->program.layout, 0, 1, &t->program.set, 0, NULL);
    const uint32_t outputs = (uint32_t)(bytes / 16);
    vkCmdPushConstants(t->commands.buffer, t->program.layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(outputs), &outputs);
    vkCmdDispatch(t->commands.buffer, (outputs + 255u) / 256u, 1, 1);
    const VkDeviceSize packed_bytes = (outputs + 3u) / 4u * sizeof(uint32_t);
    if (finish_commands(t, &t->commands, t->queue, &t->buffers[2], packed_bytes, error, error_size)) return -1;
    memcpy(output, t->buffers[2].host.mapped, bytes / 16);
    return 0;
}

// Try each tile on two useful submissions of comparable size. A transient stall
// can only raise a measured time; retain the fastest observed time per KiB.
enum { tile_options = 5, tile_rounds = 2 };
typedef struct {
    uint64_t fastest;
    uint32_t calls, width;
} TileTrial;
static uint64_t monotonic_ns(void) {
    struct timespec now;
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0
        ? (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec : 0;
}
struct CountContext {
    TileTrial tiles[32];
    Buffer readback;
    Program program;
};
typedef struct {
    uint32_t bytes, kind, level, bins, layers, tile, odd, mask;
    uint32_t initial, warmup;
    uint32_t result_offset;
} CountParameters;
_Static_assert(sizeof(CountParameters) == 44, "count shader parameter layout");

static void destroy_counts(Context *t) {
    CountContext *c = t->counts;
    if (!c) return;
    destroy_program(t->device, &c->program);
    destroy_buffer(t->device, &c->readback);
    free(c);
    t->counts = NULL;
}

static VkDeviceSize count_readback_bytes(size_t capacity) {
    return (2u * 262144u + 9u * 19683u + (capacity >> 10)) * sizeof(uint32_t);
}
static int create_counts(Context *t, char *error, size_t error_size) {
    t->counts = calloc(1, sizeof(*t->counts));
    if (!t->counts) { snprintf(error, error_size, "counter context allocation failed"); return -1; }
    CountContext *c = t->counts;
    const VkDeviceSize bytes = count_readback_bytes(t->capacity);
    if (create_buffer(t, &c->readback, bytes, error, error_size)) return -1;
    VkDescriptorBufferInfo infos[2] = {
        {.buffer = storage(&t->buffers[0]), .range = t->capacity + dc7_lookup_bytes},
        {.buffer = storage(&c->readback), .range = bytes},
    };
    return create_program(t, &c->program, counts_spv, sizeof(counts_spv),
        infos, 2, sizeof(CountParameters), error, error_size);
}

// Balance large batches within the caller's X limit. Counters retain their
// portable 65535 cap; FPF retains the device limit. Bounded capacities fit Y.
static void dispatch_groups(VkCommandBuffer command, uint32_t groups, uint32_t max_x) {
    const uint32_t rows = 1u + (groups - 1u) / max_x;
    const uint32_t columns = 1u + (groups - 1u) / rows;
    vkCmdDispatch(command, columns, rows, 1);
}
static int prepare_count(Context *t, const uint8_t *input, size_t bytes,
    const uint32_t *lookup, char *error, size_t error_size) {
    if (!bytes || bytes > t->capacity || bytes % 1024) { snprintf(error, error_size, "invalid counter input"); return -1; }
    if (!t->supports_counts) { snprintf(error, error_size, "counter capabilities unavailable"); return -1; }
    if (!t->counts && create_counts(t, error, error_size)) { destroy_counts(t); return -1; }
    // C8 and counters use one ordered service. Append the DC7 lookup after
    // this upload so a short input uses the same descriptor and flush.
    Buffer *upload = &t->buffers[0];
    memcpy(upload->host.mapped, input, bytes);
    if (lookup) memcpy((uint8_t *)upload->host.mapped + bytes, lookup, dc7_lookup_bytes);
    return 0;
}
static int begin_count(Context *t, size_t bytes, uint32_t clear_words, char *error, size_t error_size) {
    CountContext *c = t->counts;
    if (begin_commands(t, &t->commands, error, error_size)) return -1;
    VkCommandBuffer command = t->commands.buffer;
    if (upload(t, command, &t->buffers[0], bytes, error, error_size)) return -1;
    vkCmdFillBuffer(command, storage(&c->readback), 0, (VkDeviceSize)clear_words * sizeof(uint32_t), 0);
    transfers_to_compute(command);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, c->program.pipeline);
    vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, c->program.layout, 0, 1, &c->program.set, 0, NULL);
    return 0;
}
static void record_count(Context *t, CountParameters p, const uint32_t *initial, const uint32_t *warmup) {
    for (p.level = 0; p.level < p.layers; ++p.level) {
        p.initial = initial[p.level];
        p.warmup = warmup[p.level];
        const uint32_t samples = p.bytes >> p.level;
        uint32_t tiles = (samples + p.tile - 1u) / p.tile;
        const uint32_t handoff = !p.kind && !p.level ? p.bytes >> (p.layers + 1u) : 0;
        if (tiles < handoff) tiles = handoff;
        vkCmdPushConstants(t->commands.buffer, t->counts->program.layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(p), &p);
        dispatch_groups(t->commands.buffer, (tiles + 63u) / 64u, 65535u);
    }
}
static int count(void *raw, uint32_t kind, const uint8_t *input, size_t bytes,
    const uint32_t *initial, const uint32_t *warmup, uint32_t odd, uint32_t mask,
    const uint32_t *lookup, const uint32_t **output, char *error, size_t error_size,
    uint32_t mod3_layers) {
    Context *t = raw;
    if (kind != 0 && kind != 2) { snprintf(error, error_size, "invalid counter kind"); return -1; }
    if (prepare_count(t, input, bytes, kind == 2 ? lookup : NULL, error, error_size)) return -1;
    CountParameters p = {.bytes = (uint32_t)bytes, .kind = kind, .odd = odd, .mask = mask,
        .bins = kind == 0 ? 19683 : 524288, .layers = kind == 0 ? mod3_layers : 1,
        .tile = kind == 2 ? 128 : 64};
    if (begin_count(t, bytes + (kind ? dc7_lookup_bytes : 0), p.bins * p.layers, error, error_size)) return -1;
    record_count(t, p, initial, warmup);
    const VkDeviceSize words = p.bins * p.layers + (kind ? 0 : (p.bytes >> (p.layers + 1u)));
    if (finish_commands(t, &t->commands, t->queue, &t->counts->readback, words * sizeof(uint32_t), error, error_size)) return -1;
    *output = t->counts->readback.host.mapped;
    return 0;
}

typedef struct {
    uint32_t initial[9], warmup[9];
    uint32_t dc_initial, dc_warmup, dc_odd, dc_mask;
} CountPairParameters;
_Static_assert(sizeof(CountPairParameters) == 88, "paired counter ABI layout");
// Optional nine-level pair. Both results borrow one readback allocation until
// the next counter/classification call; the service owns input for the whole call.
int pr_gpu_count_pair_v1(void *raw, const uint8_t *input, size_t bytes,
    const CountPairParameters *parameters, const uint32_t *lookup,
    const uint32_t **output, char *error, size_t error_size) {
    Context *t = raw;
    if (prepare_count(t, input, bytes, lookup, error, error_size)) return -1;
    // Calls in one size class differ by less than a factor of two.
    TileTrial *trial = &t->counts->tiles[31u - (unsigned)__builtin_clz((uint32_t)bytes)];
    const int sampling = trial->calls < tile_options * tile_rounds;
    const unsigned slot = (trial->calls + trial->calls / tile_options) % tile_options;
    const uint32_t tile = sampling ? 8u << slot : trial->width;
    const uint64_t start = sampling ? monotonic_ns() : 0;
    CountParameters mod3 = {.bytes = (uint32_t)bytes, .bins = 19683, .layers = 9, .tile = tile};
    CountParameters dc = {.bytes = (uint32_t)bytes, .kind = 2, .bins = 524288, .layers = 1,
        .tile = tile * 2, .odd = parameters->dc_odd, .mask = parameters->dc_mask,
        .result_offset = 9u * 19683u + ((uint32_t)bytes >> 10)};
    if (begin_count(t, bytes + dc7_lookup_bytes, dc.result_offset + dc.bins, error, error_size)) return -1;
    record_count(t, mod3, parameters->initial, parameters->warmup);
    record_count(t, dc, &parameters->dc_initial, &parameters->dc_warmup);
    if (finish_commands(t, &t->commands, t->queue, &t->counts->readback,
        (dc.result_offset + dc.bins) * sizeof(uint32_t), error, error_size)) return -1;
    if (sampling) {
        const uint64_t end = monotonic_ns();
        if (!start || end <= start) {
            trial->width = 64;
            trial->calls = tile_options * tile_rounds;
        } else {
            const uint64_t cost = (end - start) / (bytes / 1024);
            if (!trial->calls || cost < trial->fastest) {
                trial->width = tile;
                trial->fastest = cost;
            }
            ++trial->calls;
        }
    }
    *output = t->counts->readback.host.mapped;
    return 0;
}
// Version 11's original entry point reads only six Mod3 history words.
int pr_gpu_count(void *raw, uint32_t kind, const uint8_t *input, size_t bytes,
    const uint32_t *initial, const uint32_t *warmup, uint32_t odd, uint32_t mask,
    const uint32_t *lookup, const uint32_t **output, char *error, size_t error_size) {
    return count(raw, kind, input, bytes, initial, warmup, odd, mask, lookup, output, error, error_size, 6);
}
uint32_t pr_gpu_mod3_layers_v1(void *raw) { (void)raw; return 9; }
int pr_gpu_mod3_count_v1(void *raw, uint32_t kind, const uint8_t *input, size_t bytes,
    const uint32_t *initial, const uint32_t *warmup, uint32_t odd, uint32_t mask,
    const uint32_t *lookup, const uint32_t **output, char *error, size_t error_size) {
    if (kind != 0) { snprintf(error, error_size, "invalid extended Vulkan Mod3 kind"); return -1; }
    return count(raw, kind, input, bytes, initial, warmup, odd, mask, lookup, output, error, error_size, 9);
}

uint32_t pr_gpu_count_supported(void *raw) {
    return ((Context *)raw)->supports_counts;
}
static uint32_t count_supported(Context *t, const VkPhysicalDeviceProperties *properties) {
    const VkPhysicalDeviceLimits *limits = &properties->limits;
    // The counter descriptors cover the input with lookup and the paired readback.
    VkDeviceSize range = count_readback_bytes(t->capacity);
    if (t->capacity + dc7_lookup_bytes > range) range = t->capacity + dc7_lookup_bytes;
    return limits->maxPerStageDescriptorStorageBuffers >= 2 && limits->maxStorageBufferRange >= range
        && limits->maxPushConstantsSize >= sizeof(CountParameters)
        && limits->maxComputeWorkGroupSize[0] >= 64 && limits->maxComputeWorkGroupInvocations >= 64;
}

// Independent FPF resources. The lease spans upload, completion and integer merge.
struct FpfContext {
    Buffer buffers[2]; // input with prior tail, histogram readback
    Program program;
    Commands commands;
};
enum { fpf_bins = 52u * 16384u, fpf_result_bytes = 2u * fpf_bins * sizeof(uint32_t) };
static const uint32_t fpf_words_per_group = 128u * 8u;
static void destroy_fpf(Context *t) {
    FpfContext *f = t->fpf;
    if (!f) return;
    destroy_commands(t->device, &f->commands);
    destroy_program(t->device, &f->program);
    for (unsigned i = 0; i < 2; ++i) destroy_buffer(t->device, &f->buffers[i]);
    free(f);
    t->fpf = NULL;
}
static int create_fpf(Context *t, char *error, size_t error_size) {
    t->fpf = calloc(1, sizeof(*t->fpf));
    if (!t->fpf) { snprintf(error, error_size, "FPF context allocation failed"); return -1; }
    FpfContext *f = t->fpf;
    const VkDeviceSize sizes[2] = {t->fpf_capacity + 8, fpf_result_bytes};
    VkDescriptorBufferInfo infos[2];
    for (unsigned i = 0; i < 2; ++i) {
        if (create_buffer(t, &f->buffers[i], sizes[i], error, error_size)) return -1;
        infos[i] = (VkDescriptorBufferInfo){.buffer = storage(&f->buffers[i]), .range = sizes[i]};
    }
    if (create_program(t, &f->program, fpf_spv, sizeof(fpf_spv),
        infos, 2, 2 * sizeof(uint32_t), error, error_size)) return -1;
    if (create_commands(t, &f->commands, error, error_size)) return -1;
    return 0;
}
static int fpf_count(Context *t, const uint8_t *input, size_t bytes, const uint8_t *tail,
    uint32_t started, char *error, size_t error_size) {
    if (!bytes || bytes > t->fpf_capacity || bytes % 1024) { snprintf(error, error_size, "invalid Vulkan FPF input"); return -1; }
    if (!t->fpf && create_fpf(t, error, error_size)) { destroy_fpf(t); return -1; }
    FpfContext *f = t->fpf;
    memcpy(f->buffers[0].host.mapped, tail, 8);
    memcpy((uint8_t *)f->buffers[0].host.mapped + 8, input, bytes);
    if (begin_commands(t, &f->commands, error, error_size)) return -1;
    if (upload(t, f->commands.buffer, &f->buffers[0], bytes + 8, error, error_size)) return -1;
    vkCmdFillBuffer(f->commands.buffer, storage(&f->buffers[1]), 0, VK_WHOLE_SIZE, 0);
    transfers_to_compute(f->commands.buffer);
    // A continuing input can use its two-word tail from the preceding call.
    const uint32_t first_word = started ? 0u : 2u;
    const uint32_t words = (uint32_t)(bytes / sizeof(uint32_t)) - first_word;
    const uint32_t parameters[2] = {first_word, words};
    vkCmdBindDescriptorSets(f->commands.buffer, VK_PIPELINE_BIND_POINT_COMPUTE, f->program.layout, 0, 1, &f->program.set, 0, NULL);
    vkCmdPushConstants(f->commands.buffer, f->program.layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(parameters), parameters);
    vkCmdBindPipeline(f->commands.buffer, VK_PIPELINE_BIND_POINT_COMPUTE, f->program.pipeline);
    const uint32_t groups = (words + fpf_words_per_group - 1u) / fpf_words_per_group;
    dispatch_groups(f->commands.buffer, groups, t->max_groups_x);
    return finish_commands(t, &f->commands, t->fpf_queue, &f->buffers[1], fpf_result_bytes, error, error_size);
}
size_t pr_gpu_fpf_capacity_v1(void *raw) { return ((Context *)raw)->fpf_capacity; }
int pr_gpu_fpf_add_pair_v1(void *raw, const uint8_t *input, size_t bytes, const uint8_t *tail,
    uint32_t started, uint64_t *totals, uint64_t *aligned, char *error, size_t error_size) {
    Context *t = raw;
    pthread_mutex_lock(&t->fpf_mutex);
    const int status = fpf_count(t, input, bytes, tail, started, error, error_size);
    if (!status) {
        const FpfContext *f = t->fpf;
        const uint32_t *counts = f->buffers[1].host.mapped;
        for (uint32_t i = 0; i < fpf_bins; ++i) {
            const uint32_t aligned_count = counts[2u * i + 1u];
            totals[i] += counts[2u * i] + aligned_count;
            if (aligned) aligned[i] += aligned_count;
        }
    }
    pthread_mutex_unlock(&t->fpf_mutex);
    return status;
}

int pr_gpu_fpf_add_v1(void *raw, const uint8_t *input, size_t bytes, const uint8_t *tail,
    uint32_t started, uint64_t *totals, char *error, size_t error_size) {
    return pr_gpu_fpf_add_pair_v1(raw, input, bytes, tail, started, totals, NULL, error, error_size);
}
