const std = @import("std");
pub fn build(b: *std.Build) void {
    if (b.graph.environ_map.get("PROJECT_NIX_ENVIRONMENT") == null)
        @panic("run builds through ./scripts/dev (the locked Nix environment)");
    const expected_zig = b.graph.environ_map.get("PRACTRAND_ZIG_VERSION") orelse
        @panic("locked Zig version metadata is missing");
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, expected_zig))
        @panic("Zig does not match the locked development environment");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const legacy_metal = b.option(bool, "metal-fpf", "Compatibility alias for -Dmetal=true") orelse false;
    const metal = b.option(bool, "metal", "Build the native Metal compute backend (macOS)") orelse legacy_metal;
    const reference = b.addSystemCommand(&.{ "python3", "-B", "tools/acquire_reference.py" });
    reference.setCwd(b.path("."));
    reference.has_side_effects = true;
    const generators = b.addLibrary(.{ .name = "practrand_generators", .linkage = .static, .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    }) });
    generators.step.dependOn(&reference.step);
    generators.root_module.addSystemIncludePath(b.path(".vendor/PractRand/include"));
    generators.root_module.addSystemIncludePath(b.path(".vendor/PractRand/tools"));
    var generator_sources = std.mem.tokenizeScalar(u8, @embedFile("src/builtin_rng_sources.txt"), '\n');
    while (generator_sources.next()) |relative| generators.root_module.addCSourceFile(.{
        .file = b.path(b.pathJoin(&.{ ".vendor/PractRand", relative })),
        .flags = &.{"-std=c++11"},
    });
    generators.root_module.addCSourceFile(.{ .file = b.path("src/builtin_rngs.cpp"), .flags = &.{ "-std=c++11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" } });
    const exe = b.addExecutable(.{ .name = "RNG_test", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    exe.root_module.linkLibrary(generators);
    exe.root_module.addRPathSpecial(if (target.result.os.tag == .macos) "@executable_path/../lib" else "$ORIGIN/../lib");
    b.installArtifact(exe);
    const test_step = b.step("test", "Run unit checks and durable SFC reference comparisons");
    const unit_step = b.step("test-unit", "Run Zig and Python checks without long parity runs");
    const check_step = b.step("check", "Check source formatting, syntax, C/C++ warnings, and imported data");
    const checks = b.addSystemCommand(&.{ "python3", "-B", "tools/check.py" });
    checks.setCwd(b.path("."));
    checks.step.dependOn(&reference.step);
    check_step.dependOn(&checks.step);
    check_step.dependOn(&generators.step);
    unit_step.dependOn(check_step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    tests.root_module.linkLibrary(generators);
    unit_step.dependOn(&b.addRunArtifact(tests).step);
    const generator_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/builtin_rngs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    generator_tests.root_module.addImport("builtin_rngs", b.createModule(.{
        .root_source_file = b.path("src/builtin_rngs.zig"),
        .target = target,
        .optimize = optimize,
    }));
    generator_tests.root_module.linkLibrary(generators);
    const generator_run = b.addRunArtifact(generator_tests);
    unit_step.dependOn(&generator_run.step);
    const fpf64_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/fpf64.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }), .filters = &.{"FPF64 "} });
    fpf64_tests.root_module.addImport("battery", b.createModule(.{
        .root_source_file = b.path("src/battery.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const fpf64_run = b.addRunArtifact(fpf64_tests);
    unit_step.dependOn(&fpf64_run.step);
    b.step("test-fpf64", "Check independent FPF/64 windows and retained original scoring").dependOn(&fpf64_run.step);
    const python_tests = b.addSystemCommand(&.{ "python3", "-B", "-m", "unittest", "discover", "-s", "test" });
    python_tests.setCwd(b.path("."));
    const bootstrap_tests = b.addSystemCommand(&.{ "python3", "-B", "scripts/test-dev.py" });
    bootstrap_tests.setCwd(b.path("."));
    unit_step.dependOn(&bootstrap_tests.step);
    unit_step.dependOn(&python_tests.step);
    const seed_cli = b.addSystemCommand(&.{ "python3", "-B", "test/seed_cli.py" });
    seed_cli.addArtifactArg(exe);
    seed_cli.setCwd(b.path("."));
    seed_cli.has_side_effects = true;
    unit_step.dependOn(&seed_cli.step);
    const seed_step = b.step("test-seed", "Check retained generator/seeding vectors and bounded seed CLI behavior");
    seed_step.dependOn(&generator_run.step);
    seed_step.dependOn(&seed_cli.step);

    const input_probe = b.addExecutable(.{ .name = "input-probe", .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    input_probe.root_module.addCSourceFile(.{ .file = b.path("test/input_probe.cpp"), .flags = &.{ "-std=c++11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" } });
    input_probe.root_module.linkLibrary(generators);
    const input_cli = b.addSystemCommand(&.{ "python3", "-B", "test/input_cli.py" });
    input_cli.addArtifactArg(exe);
    input_cli.addArtifactArg(input_probe);
    input_cli.setCwd(b.path("."));
    input_cli.has_side_effects = true;
    unit_step.dependOn(&input_cli.step);
    b.step("test-input", "Check original input vectors and stream CLI behavior").dependOn(&input_cli.step);

    const entropy_cli = b.addSystemCommand(&.{ "python3", "-B", "test/entropy_cli.py" });
    entropy_cli.addArtifactArg(exe);
    entropy_cli.addArtifactArg(input_probe);
    entropy_cli.setCwd(b.path("."));
    entropy_cli.has_side_effects = true;
    unit_step.dependOn(&entropy_cli.step);
    b.step("test-entropy", "Check entropy target vectors, setup, lengths and reports").dependOn(&entropy_cli.step);

    const report_probe = b.addExecutable(.{ .name = "report-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("test/report_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    report_probe.root_module.addImport("report", b.createModule(.{
        .root_source_file = b.path("src/report.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const report_cli = b.addSystemCommand(&.{ "python3", "-B", "test/report_cli.py" });
    report_cli.addArtifactArg(exe);
    report_cli.addArtifactArg(report_probe);
    report_cli.setCwd(b.path("."));
    report_cli.has_side_effects = true;
    unit_step.dependOn(&report_cli.step);
    b.step("test-reports", "Compare finished report layouts with original formatter fixtures").dependOn(&report_cli.step);

    const numerical_probe = b.addExecutable(.{ .name = "numerical-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("test/numerical_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    numerical_probe.root_module.addImport("statistics", b.createModule(.{
        .root_source_file = b.path("src/statistics.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.step("numerical-probe", "Print improved-mode binary64 results for cross-machine comparison").dependOn(&b.addRunArtifact(numerical_probe).step);

    const test_output = b.option([]const u8, "test-output", "Directory for fresh SFC comparison captures") orelse ".work/full-tests/parity";
    const parity = b.addSystemCommand(&.{ "python3", "-B", "test/compare_fixtures.py", "--output", test_output, "--rewrite" });
    parity.addArtifactArg(exe);
    parity.has_side_effects = true;
    parity.setCwd(b.path("."));
    parity.step.dependOn(unit_step);
    test_step.dependOn(&parity.step);

    const vulkan = b.option(bool, "vulkan", "Build the optional Vulkan libraries and hardware checks") orelse false;
    if (vulkan) {
        const sdk = b.option([]const u8, "vulkan-sdk", "Vulkan SDK root containing include/lib/bin") orelse b.graph.environ_map.get("VULKAN_SDK");
        if (target.result.os.tag == .macos and sdk == null) @panic("activate the Vulkan SDK or pass -Dvulkan-sdk=PATH");
        const compiler = if (sdk) |root| b.pathJoin(&.{ root, "bin", "glslc" }) else "glslc";
        const validator = if (sdk) |root| b.pathJoin(&.{ root, "bin", "spirv-val" }) else "spirv-val";
        const shader = b.addSystemCommand(&.{ "python3", "-B" });
        shader.addFileArg(b.path("tools/compile_gpu_shader.py"));
        shader.addFileArg(b.findProgramLazy(.{ .names = &.{compiler} }));
        shader.addFileArg(b.findProgramLazy(.{ .names = &.{validator} }));
        shader.addFileArg(b.path("src/gpu/classification.comp"));
        const header = shader.addOutputFileArg("classification.h");
        const counts_shader = b.addSystemCommand(&.{ "python3", "-B" });
        counts_shader.addFileArg(b.path("tools/compile_gpu_shader.py"));
        counts_shader.addFileArg(b.findProgramLazy(.{ .names = &.{compiler} }));
        counts_shader.addFileArg(b.findProgramLazy(.{ .names = &.{validator} }));
        counts_shader.addFileArg(b.path("src/gpu/counts.comp"));
        const counts_header = counts_shader.addOutputFileArg("counts.h");
        const fpf_shader = b.addSystemCommand(&.{ "python3", "-B" });
        fpf_shader.addFileArg(b.path("tools/compile_gpu_shader.py"));
        fpf_shader.addFileArg(b.findProgramLazy(.{ .names = &.{compiler} }));
        fpf_shader.addFileArg(b.findProgramLazy(.{ .names = &.{validator} }));
        fpf_shader.addFileArg(b.path("src/gpu/fpf.comp"));
        const fpf_header = fpf_shader.addOutputFileArg("fpf.h");
        const backend = b.addLibrary(.{ .name = "practrand_vulkan", .linkage = .dynamic, .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        backend.root_module.addCSourceFile(.{ .file = b.path("src/gpu/vulkan.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror", "-fvisibility=default" } });
        backend.root_module.addIncludePath(header.dirname());
        backend.root_module.addIncludePath(counts_header.dirname());
        backend.root_module.addIncludePath(fpf_header.dirname());
        if (sdk) |root| {
            backend.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "include" }) });
            backend.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib" }) });
            backend.root_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib" }) });
        }
        backend.root_module.linkSystemLibrary("vulkan", .{});
        backend.root_module.linkSystemLibrary("pthread", .{});
        b.installArtifact(backend);
        check_step.dependOn(&backend.step);
    }
    if (metal) {
        if (target.result.os.tag != .macos) @panic("metal requires macOS");
        const native = b.addLibrary(.{ .name = "practrand_metal", .linkage = .dynamic, .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = false,
        }) });
        native.root_module.addCSourceFile(.{ .file = b.path("src/gpu/metal.mm"), .flags = &.{ "-std=c++17", "-fobjc-arc", "-Wall", "-Wextra", "-Werror" } });
        native.root_module.linkFramework("Foundation", .{});
        native.root_module.linkFramework("Metal", .{});
        native.root_module.linkSystemLibrary("objc", .{});
        // Reuse the platform C++ runtime already used by these frameworks.
        const cxx_lib = b.graph.environ_map.get("PRACTRAND_SYSTEM_CXX_LIB") orelse
            @panic("locked system C++ link stubs are missing");
        native.root_module.addLibraryPath(.{ .cwd_relative = cxx_lib });
        native.root_module.linkSystemLibrary("c++.1", .{});
        b.installArtifact(native);
        // Keep existing explicit sidecar paths usable during the transition.
        b.getInstallStep().dependOn(&b.addInstallFile(native.getEmittedBin(), "lib/libpractrand_metal_fpf.dylib").step);
        check_step.dependOn(&native.step);
    }
    if (vulkan or metal) {
        const gpu_options = b.addOptions();
        gpu_options.addOption(bool, "native_fpf", metal);
        gpu_options.addOption([]const u8, "native_fpf_library", "@rpath/libpractrand_metal.dylib");
        const hardware_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        hardware_tests.root_module.addRPath(.{ .relative = .{ .base = .install_lib, .sub_path = "" } });
        hardware_tests.root_module.addOptions("gpu_options", gpu_options);
        const hardware_run = b.addRunArtifact(hardware_tests);
        // Runtime hardware, driver and validation settings are not build-cache inputs.
        hardware_run.has_side_effects = true;
        hardware_run.step.dependOn(b.getInstallStep());
        const hardware_step = b.step("test-gpu", "Check the selected GPU backend alongside CPU workers");
        hardware_step.dependOn(&hardware_run.step);
        test_step.dependOn(hardware_step);
    }
}
