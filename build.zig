const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("plugin_api", plugin_api);

    const lib = b.addLibrary(.{
        .name = "sa_plugin_ts",
        .root_module = root_module,
        .linkage = .dynamic,
    });

    b.installArtifact(lib);

    // Standard Zig test suite
    const main_tests = b.addTest(.{
        .root_module = root_module,
    });
    main_tests.root_module.addImport("plugin_api", plugin_api);

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
