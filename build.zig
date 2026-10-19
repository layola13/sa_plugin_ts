const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const requested_optimize = b.standardOptimizeOption(.{});
    const optimize = effectiveOptimizeForDevInstall(b, requested_optimize);
    const test_filter = b.option([]const u8, "test-filter", "Only compile and run Zig tests whose name contains this filter.");

    const is_windows = target.result.os.tag == .windows;
    const sci_root = b.option([]const u8, "sci-root", "Path to the sci checkout") orelse "../sci";
    const sio_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ sci_root, "src", "sa_io.zig" }) },
        .target = target,
        .optimize = optimize,
    });

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
    root_module.addImport("sio", sio_module);

    const lib = b.addLibrary(.{
        .name = "sa_plugin_ts",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    linkHostSystemLibs(root_module, is_windows);
    b.installArtifact(lib);

    const install_sap = b.addInstallFile(b.path("sap.json"), "lib/sap.json");
    b.getInstallStep().dependOn(&install_sap.step);

    // Standard Zig test suite
    const main_tests = b.addTest(.{
        .root_module = root_module,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    main_tests.root_module.addImport("plugin_api", plugin_api);
    linkHostSystemLibs(main_tests.root_module, is_windows);

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

fn linkHostSystemLibs(module: *std.Build.Module, is_windows: bool) void {
    if (!is_windows) return;
    module.linkSystemLibrary("ws2_32", .{});
    module.linkSystemLibrary("iphlpapi", .{});
}

fn effectiveOptimizeForDevInstall(b: *std.Build, requested: std.builtin.Optimize) std.builtin.Optimize {
    if (requested != .fast) return requested;
    const value = b.graph.environ_map.get("SA_PLUGIN_DEV") orelse return requested;
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return .debug;
    return requested;
}
