const std = @import("std");
const worker_limit = 4;
const gpu_worker_limit = 8;
const inline_job_capacity = 32;
pub const Job = struct { context: *anyopaque, run: *const fn (*anyopaque) anyerror!void };

// Borrowed FIFO requests remain owned by their callers until joined. Ordered
// input reuses one request; independent GPU roots may queue separate nodes.
pub const Service = struct {
    pub const Request = struct {
        job: Job = undefined,
        next: ?*Request = null,
        completed: bool = true,
        failure: ?anyerror = null,
        pub fn init(job: Job) Request {
            return .{ .job = job, .completed = false };
        }
    };
    mutex: std.c.pthread_mutex_t = .{},
    ready: std.c.pthread_cond_t = .{},
    done: std.c.pthread_cond_t = .{},
    head: ?*Request = null,
    tail: ?*Request = null,
    running: ?*Request = null,
    stopping: bool = false,
    thread: std.Thread = undefined,
    pub fn init(self: *Service) !void {
        self.* = .{};
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }
    pub fn start(self: *Service, request: *Request) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (@import("builtin").is_test) {
            if (request.completed or self.stopping or self.running == request) @panic("invalid service request");
            var node = self.head;
            while (node) |queued| : (node = queued.next) if (queued == request) @panic("request already queued");
        }
        request.next = null;
        if (self.tail) |tail| tail.next = request else self.head = request;
        self.tail = request;
        _ = std.c.pthread_cond_signal(&self.ready);
    }
    pub fn wait(self: *Service, request: *Request) !void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        while (!request.completed) _ = std.c.pthread_cond_wait(&self.done, &self.mutex);
        if (request.failure) |err| return err;
    }
    pub fn deinit(self: *Service) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        while (self.head != null or self.running != null) _ = std.c.pthread_cond_wait(&self.done, &self.mutex);
        self.stopping = true;
        _ = std.c.pthread_cond_signal(&self.ready);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.thread.join();
        _ = std.c.pthread_cond_destroy(&self.ready);
        _ = std.c.pthread_cond_destroy(&self.done);
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }
    fn worker(self: *Service) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        while (true) {
            while (self.head == null and !self.stopping) _ = std.c.pthread_cond_wait(&self.ready, &self.mutex);
            if (self.stopping) return;
            const request = self.head.?;
            self.head = request.next;
            if (self.head == null) self.tail = null;
            self.running = request;
            _ = std.c.pthread_mutex_unlock(&self.mutex);
            const failure: ?anyerror = if (request.job.run(request.job.context)) |_| null else |err| err;
            _ = std.c.pthread_mutex_lock(&self.mutex);
            request.failure = failure;
            request.completed = true;
            self.running = null;
            _ = std.c.pthread_cond_broadcast(&self.done);
        }
    }
};

const Group = struct { remaining: usize, failure: ?anyerror = null };
const Task = struct { job: Job, group: *Group, next: ?*Task = null };
pub const Pool = struct {
    mutex: std.c.pthread_mutex_t = .{},
    ready: std.c.pthread_cond_t = .{},
    threads: std.ArrayList(std.Thread) = .empty,
    head: ?*Task = null,
    tail: ?*Task = null,
    stopping: bool = false,
    pub fn init(p: *Pool) !void {
        try p.initWithLimit(worker_limit);
    }
    // GPU service waits overlap independent CPU families; the cap is still
    // bounded by the hardware CPU count. CPU-only execution keeps its own cap.
    pub fn initForGpu(p: *Pool) !void {
        try p.initWithLimit(gpu_worker_limit);
    }
    pub fn initWithLimit(p: *Pool, limit: usize) !void {
        p.* = .{};
        errdefer p.deinit();
        const n = @min(limit, std.Thread.getCpuCount() catch 1);
        try p.threads.ensureTotalCapacityPrecise(std.heap.page_allocator, n -| 1);
        while (p.threads.items.len + 1 < n)
            p.threads.appendAssumeCapacity(try std.Thread.spawn(.{}, worker, .{p}));
    }
    pub fn deinit(p: *Pool) void {
        _ = std.c.pthread_mutex_lock(&p.mutex);
        p.stopping = true;
        _ = std.c.pthread_cond_broadcast(&p.ready);
        _ = std.c.pthread_mutex_unlock(&p.mutex);
        for (p.threads.items) |thread| thread.join();
        p.threads.deinit(std.heap.page_allocator);
        _ = std.c.pthread_cond_destroy(&p.ready);
        _ = std.c.pthread_mutex_destroy(&p.mutex);
    }
    // The queue holds borrowed nodes until their own group joins. A joining
    // caller helps unrelated ready work, so nested fanout reserves no worker.
    fn one(p: *Pool) bool {
        const task = p.head orelse return false;
        const job = task.job;
        const group = task.group;
        p.head = task.next;
        if (p.head == null) p.tail = null;
        _ = std.c.pthread_mutex_unlock(&p.mutex);
        const failure: ?anyerror = if (job.run(job.context)) |_| null else |err| err;
        _ = std.c.pthread_mutex_lock(&p.mutex);
        if (group.failure == null) group.failure = failure;
        group.remaining -= 1;
        if (group.remaining == 0) _ = std.c.pthread_cond_broadcast(&p.ready);
        return true;
    }
    fn worker(p: *Pool) void {
        _ = std.c.pthread_mutex_lock(&p.mutex);
        defer _ = std.c.pthread_mutex_unlock(&p.mutex);
        while (true) {
            while (p.head == null and !p.stopping) _ = std.c.pthread_cond_wait(&p.ready, &p.mutex);
            if (p.stopping) return;
            _ = p.one();
        }
    }
    pub fn run(p: *Pool, jobs: []const Job) !void {
        if (p.threads.items.len == 0 or jobs.len < 2) {
            for (jobs) |job| try job.run(job.context);
            return;
        }
        var local: [inline_job_capacity]Task = undefined;
        const nodes = if (jobs.len <= local.len) local[0..jobs.len] else try std.heap.page_allocator.alloc(Task, jobs.len);
        defer if (jobs.len > local.len) std.heap.page_allocator.free(nodes);
        var group = Group{ .remaining = jobs.len };
        for (nodes, jobs) |*node, job| node.* = .{ .job = job, .group = &group };
        for (nodes[0 .. nodes.len - 1], nodes[1..]) |*node, *next| node.next = next;
        _ = std.c.pthread_mutex_lock(&p.mutex);
        defer _ = std.c.pthread_mutex_unlock(&p.mutex);
        if (p.tail) |tail| tail.next = &nodes[0] else p.head = &nodes[0];
        p.tail = &nodes[nodes.len - 1];
        _ = std.c.pthread_cond_broadcast(&p.ready);
        while (group.remaining != 0) {
            if (!p.one()) _ = std.c.pthread_cond_wait(&p.ready, &p.mutex);
        }
        if (group.failure) |err| return err;
    }
};

test "job failure joins the batch and the executor can be reused" {
    const Context = struct {
        calls: usize = 0,
        fail: bool = false,
        fn run(raw: *anyopaque) !void {
            const context: *@This() = @ptrCast(@alignCast(raw));
            context.calls += 1;
            if (context.fail) return error.ExpectedJobFailure;
        }
    };
    var pool: Pool = undefined;
    try pool.init();
    defer pool.deinit();
    var contexts: [inline_job_capacity + 5]Context = @splat(.{});
    var jobs: [contexts.len]Job = undefined;
    for (&contexts, &jobs) |*context, *job| job.* = .{ .context = context, .run = Context.run };
    // Last in serial order also tests a one-CPU executor without depending on scheduling.
    contexts[contexts.len - 1].fail = true;
    try std.testing.expectError(error.ExpectedJobFailure, pool.run(&jobs));
    for (&contexts) |*context| {
        try std.testing.expectEqual(@as(usize, 1), context.calls);
        context.fail = false;
    }
    try pool.run(&jobs);
    for (contexts) |context| try std.testing.expectEqual(@as(usize, 2), context.calls);
}

test "nested groups drain failures and retain stack job storage" {
    const Child = struct {
        value: usize = 0,
        fail: bool = false,
        fn run(raw: *anyopaque) !void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.value += 1;
            if (c.fail) return error.ExpectedNestedFailure;
        }
    };
    const Parent = struct {
        pool: *Pool,
        children: [9]Child = @splat(.{}),
        done: bool = false,
        fn run(raw: *anyopaque) !void {
            const parent: *@This() = @ptrCast(@alignCast(raw));
            var jobs: [9]Job = undefined;
            for (&parent.children, &jobs) |*child, *job| job.* = .{ .context = child, .run = Child.run };
            const result = parent.pool.run(&jobs);
            parent.done = true;
            try result;
        }
    };
    var pool: Pool = undefined;
    try pool.init();
    defer pool.deinit();
    var parents: [8]Parent = @splat(.{ .pool = &pool });
    var jobs: [8]Job = undefined;
    for (&parents, &jobs) |*parent, *job| job.* = .{ .context = parent, .run = Parent.run };
    parents[parents.len - 1].children[8].fail = true;
    try std.testing.expectError(error.ExpectedNestedFailure, pool.run(&jobs));
    for (&parents) |*parent| {
        try std.testing.expect(parent.done);
        for (parent.children) |child| try std.testing.expectEqual(@as(usize, 1), child.value);
        parent.done = false;
    }
    parents[parents.len - 1].children[8].fail = false;
    try pool.run(&jobs);
    for (parents) |parent| for (parent.children) |child| try std.testing.expectEqual(@as(usize, 2), child.value);
}

test "dedicated service and CPU pool progress independently and join failures before reuse" {
    const Gate = struct {
        mutex: std.c.pthread_mutex_t = .{},
        changed: std.c.pthread_cond_t = .{},
        ready: bool = false,
        released: bool = false,
        cpu_ran: bool = false,
        fn run(raw: *anyopaque) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            _ = std.c.pthread_mutex_lock(&gate.mutex);
            defer _ = std.c.pthread_mutex_unlock(&gate.mutex);
            gate.ready = true;
            _ = std.c.pthread_cond_broadcast(&gate.changed);
            while (!gate.released) _ = std.c.pthread_cond_wait(&gate.changed, &gate.mutex);
            return error.ExpectedServiceJobFailure;
        }
        fn cpu(raw: *anyopaque) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            _ = std.c.pthread_mutex_lock(&gate.mutex);
            defer _ = std.c.pthread_mutex_unlock(&gate.mutex);
            while (!gate.ready) _ = std.c.pthread_cond_wait(&gate.changed, &gate.mutex);
            gate.cpu_ran = true;
            gate.released = true;
            _ = std.c.pthread_cond_broadcast(&gate.changed);
        }
    };
    var service: Service = undefined;
    try service.init();
    defer service.deinit();
    var pool: Pool = undefined;
    try pool.init();
    defer pool.deinit();
    var gate = Gate{};
    defer _ = std.c.pthread_cond_destroy(&gate.changed);
    defer _ = std.c.pthread_mutex_destroy(&gate.mutex);
    var request = Service.Request.init(.{ .context = &gate, .run = Gate.run });
    service.start(&request);
    try pool.run(&.{ .{ .context = &gate, .run = Gate.cpu }, .{ .context = &gate, .run = Gate.cpu } });
    try std.testing.expectError(error.ExpectedServiceJobFailure, service.wait(&request));
    try std.testing.expect(gate.cpu_ran);
    gate.released = true;
    request = Service.Request.init(.{ .context = &gate, .run = Gate.cpu });
    service.start(&request);
    try service.wait(&request);
}

test "service teardown joins its outstanding borrowed job" {
    const Context = struct {
        calls: usize = 0,
        fn run(raw: *anyopaque) !void {
            const context: *@This() = @ptrCast(@alignCast(raw));
            context.calls += 1;
            return error.ExpectedServiceJobFailure;
        }
    };
    var service: Service = undefined;
    try service.init();
    var context = Context{};
    var request = Service.Request.init(.{ .context = &context, .run = Context.run });
    service.start(&request);
    service.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}

test "queued service requests preserve FIFO failures reuse and teardown draining" {
    const Context = struct {
        id: usize,
        order: *[10]usize,
        used: *usize,
        fail: bool = false,
        fn run(raw: *anyopaque) !void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.order[c.used.*] = c.id;
            c.used.* += 1;
            if (c.fail) return error.ExpectedQueuedServiceFailure;
        }
    };
    var service: Service = undefined;
    try service.init();
    var active = true;
    defer if (active) service.deinit();
    var order: [10]usize = undefined;
    var used: usize = 0;
    var contexts: [9]Context = undefined;
    var requests: [9]Service.Request = undefined;
    for (&contexts, &requests, 0..) |*context, *request, i| {
        context.* = .{ .id = i, .order = &order, .used = &used, .fail = i == 3 };
        request.* = Service.Request.init(.{ .context = context, .run = Context.run });
        if (i < 8) service.start(request);
    }
    for (requests[0..8], 0..) |*request, i| {
        if (i == 3) try std.testing.expectError(error.ExpectedQueuedServiceFailure, service.wait(request)) else try service.wait(request);
    }
    contexts[3].fail = false;
    requests[3] = Service.Request.init(.{ .context = &contexts[3], .run = Context.run });
    service.start(&requests[3]);
    service.start(&requests[8]);
    service.deinit();
    active = false;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 3, 8 }, &order);
    try std.testing.expectEqual(@as(usize, 10), used);
    for (requests) |request| try std.testing.expect(request.completed and request.failure == null);
}
