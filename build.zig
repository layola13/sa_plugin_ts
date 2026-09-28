const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const requested_optimize = b.standardOptimizeOption(.{});
    const optimize = effectiveOptimizeForDevInstall(b, requested_optimize);
    const test_filter = b.option([]const u8, "test-filter", "Only compile and run Zig tests whose name contains this filter.");

    const is_windows = target.result.os.tag == .windows;

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);

    const lib = b.addLibrary(.{
        .name = "sa_plugin_ts",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    linkHostSystemLibs(lib, is_windows);
    b.installArtifact(lib);

    const install_sap = b.addInstallFile(b.path("sap.json"), "lib/sap.json");
    b.getInstallStep().dependOn(&install_sap.step);

    // Standard Zig test suite
    const main_tests = b.addTest(.{
        .root_module = root_module,
        .filter = test_filter,
    });
    main_tests.root_module.addImport("plugin_api", plugin_api);
    linkHostSystemLibs(main_tests, is_windows);

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

fn linkHostSystemLibs(compile: *std.Build.Step.Compile, is_windows: bool) void {
    if (!is_windows) return;
    compile.linkSystemLibrary("ws2_32");
    compile.linkSystemLibrary("iphlpapi");
}

fn effectiveOptimizeForDevInstall(b: *std.Build, requested: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    if (requested != .ReleaseFast) return requested;
    const value = std.process.getEnvVarOwned(b.allocator, "SA_PLUGIN_DEV") catch return requested;
    defer b.allocator.free(value);
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return .Debug;
    return requested;
}
