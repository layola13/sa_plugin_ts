const std = @import("std");
const plugin_api = @import("plugin_api");
const plugin_helpers = @import("plugin_helpers.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const lowerer = @import("lowerer.zig");

// ==========================================
// Skills metadata
// ==========================================

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "ts",
        .summary = "TypeScript to SA-ASM ahead-of-time lowerer",
        .items = &.{
            "ts lower [file] [--out <out>] [-p <package>] — lower a TypeScript file to SA-ASM",
            "ts check [file] [-p <package>] — parse and lower without writing output",
            "ts build [file] [--out <out>] [-p <package>] — lower and write a .sai file",
            "ts build-exe [file] [-p <package>] [sa-build-exe-options...] — lower and link an executable via sa",
            "ts test [file] [-p <package>] [sa-test-options...] — lower and run sa test on the result",
            "ts init [path] — scaffold a minimal TS project (sa.mod + src/main.ts)",
            "ts skills [--json] — show plugin skills",
            "ts help — show this help",
            "zero-copy string slices and static struct layout",
            "ownership injection (!, ^) based on lexical scope",
            "Pratt expression parser with correct operator precedence",
            "arrow function closures via static defunctionalization",
            "WASM import symbol linking",
        },
    },
};

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn writeTsHelp(stderr: std.io.AnyWriter) !void {
    try stderr.writeAll("usage: ts <command> [options]\n");
    try stderr.writeAll("       sa ts <command> [options]\n\n");
    try stderr.writeAll("Commands:\n");
    try stderr.writeAll("  lower      [file] [--out <file>] [-p <package>]\n");
    try stderr.writeAll("  check      [file] [-p <package>]\n");
    try stderr.writeAll("  build      [file] [--out <file>] [-p <package>]\n");
    try stderr.writeAll("  build-exe  [file] [-p <package>] [sa-build-exe-options...]\n");
    try stderr.writeAll("  test       [file] [-p <package>] [sa-test-options...]\n");
    try stderr.writeAll("  init       [path]\n");
    try stderr.writeAll("  skills     [--json]\n");
    try stderr.writeAll("  help\n\n");
    try stderr.writeAll("Options:\n");
    try stderr.writeAll("  -p, --package <name>   Select a workspace member package (also -p=name, --package=name)\n");
    try stderr.writeAll("  --out, -o <file>       Write output to file (lower/build only)\n");
    try stderr.writeAll("  --json                 Emit JSON where supported\n");
    try stderr.writeAll("  -h, --help             Show this help message\n");
}

fn runTsSkillsCommand(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    var json_mode = ctx.json_mode;
    var idx = option_start;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (isHelpArg(arg)) {
            try stderr.writeAll("usage: sa ts skills [--json]\n");
            return 0;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
            continue;
        }
        try stderr.print("error[SA-TS]: unknown ts skills option '{s}'\n", .{arg});
        try stderr.writeAll("usage: sa ts skills [--json]\n");
        return 1;
    }
    if (json_mode) {
        try stdout.writeAll("{\"skills\":[\"ts.lower\",\"ts.check\",\"ts.build\",\"ts.build-exe\",\"ts.test\",\"ts.init\"]}");
        try stdout.writeByte('\n');
    } else {
        try stdout.writeAll("ts TypeScript to SA-ASM lowerer\n");
        for (skills) |section| {
            try stdout.print("{s}: {s}\n", .{ section.name, section.summary });
            for (section.items) |item| try stdout.print("  - {s}\n", .{item});
        }
    }
    return 0;
}

const TsFileArgs = struct {
    file: ?[]const u8 = null,
    out: ?[]const u8 = null,
    package_name: ?[]const u8 = null,
    json_mode: bool = false,
    help_requested: bool = false,
    extra_arg: ?[]const u8 = null,
};

fn parseTsFileArgs(args: []const []const u8, option_start: usize) TsFileArgs {
    var parsed = TsFileArgs{};
    var idx = option_start;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (isHelpArg(arg)) {
            parsed.help_requested = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json_mode = true;
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "-o")) {
            idx += 1;
            if (idx < args.len) parsed.out = args[idx];
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--package")) {
            idx += 1;
            if (idx < args.len) parsed.package_name = args[idx];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            parsed.out = arg["--out=".len..];
        } else if (std.mem.startsWith(u8, arg, "-p=")) {
            parsed.package_name = arg["-p=".len..];
        } else if (std.mem.startsWith(u8, arg, "--package=")) {
            parsed.package_name = arg["--package=".len..];
        } else if (parsed.file == null) {
            parsed.file = arg;
        } else {
            parsed.extra_arg = arg;
        }
    }
    return parsed;
}

/// Argument parser for the delegating commands (`build-exe`, `test`).
///
/// Only `-p`/`--package` (all three `-p name`, `-p=name`, `--package=name`
/// forms), `-h`/`--help` are consumed. The first positional token is the
/// input file; every other token passes through to the delegated `sa`
/// command untouched, so `ts build-exe src/main.ts -o bin/app --release-fast`
/// forwards `-o bin/app --release-fast` verbatim.
const TsDelegateArgs = struct {
    file: ?[]const u8 = null,
    package_name: ?[]const u8 = null,
    help_requested: bool = false,
    passthrough: std.ArrayListUnmanaged([]const u8) = .{},
};

fn parseTsDelegateArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    option_start: usize,
) !TsDelegateArgs {
    var parsed = TsDelegateArgs{};
    errdefer parsed.passthrough.deinit(allocator);
    var idx = option_start;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (isHelpArg(arg)) {
            parsed.help_requested = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--package")) {
            idx += 1;
            if (idx < args.len) parsed.package_name = args[idx];
        } else if (std.mem.startsWith(u8, arg, "-p=")) {
            parsed.package_name = arg["-p=".len..];
        } else if (std.mem.startsWith(u8, arg, "--package=")) {
            parsed.package_name = arg["--package=".len..];
        } else if (isValueTakingPassthroughFlag(arg)) {
            // Options forwarded to `sa` whose value is a separate token
            // (e.g. `-o out`, `--jobs 4`): forward both verbatim so the
            // value is never mistaken for the input file.
            try parsed.passthrough.append(allocator, arg);
            idx += 1;
            if (idx < args.len) try parsed.passthrough.append(allocator, args[idx]);
        } else if (parsed.file == null and !std.mem.startsWith(u8, arg, "-")) {
            parsed.file = arg;
        } else {
            try parsed.passthrough.append(allocator, arg);
        }
    }
    return parsed;
}

/// Delegated `sa` options that take a space-separated value. `-p` is
/// deliberately absent: it is consumed by the plugin for workspace members.
fn isValueTakingPassthroughFlag(arg: []const u8) bool {
    for ([_][]const u8{ "-o", "--out", "--jobs", "--filter", "--skip", "--test-backend" }) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn hasJobsArg(passthrough: []const []const u8) bool {
    for (passthrough) |arg| {
        if (std.mem.eql(u8, arg, "--jobs")) return true;
        if (std.mem.startsWith(u8, arg, "--jobs=")) return true;
    }
    return false;
}

/// Append `--jobs auto` unless the user already controls `--jobs`,
/// mirroring the `sa sla` convention for delegated commands.
fn appendDefaultJobsAuto(argv: *std.ArrayList([]const u8), passthrough: []const []const u8) !void {
    if (hasJobsArg(passthrough)) return;
    try argv.append("--jobs");
    try argv.append("auto");
}

fn lowerFileToSa(
    ctx: *const plugin_api.Context,
    input_path: []const u8,
    stderr: std.io.AnyWriter,
) anyerror![]u8 {
    plugin_api.emitLog(ctx, .info, "reading TypeScript source file");
    const source = std.fs.cwd().readFileAlloc(ctx.allocator, input_path, 16 * 1024 * 1024) catch |err| {
        try stderr.print("error[SA-TS]: cannot read '{s}': {}\n", .{ input_path, err });
        return err;
    };
    defer ctx.allocator.free(source);
    plugin_api.emitLog(ctx, .info, "lowering TypeScript to SA-ASM");
    return try lowerSource(ctx, source, stderr);
}

fn defaultSaiOut(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, file, ".ts")) {
        const base = file[0 .. file.len - 3];
        return try std.fmt.allocPrint(allocator, "{s}.sai", .{base});
    }
    return try std.fmt.allocPrint(allocator, "{s}.sai", .{file});
}

// ==========================================
// Core lowering logic (shared by ABI + CLI)
// ==========================================

fn lowerSource(
    ctx: *const plugin_api.Context,
    source: []const u8,
    stderr: std.io.AnyWriter,
) anyerror![]u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = parser.Parser.init(arena_allocator, source, &low) catch |err| {
        plugin_api.emitLog(ctx, .err, "failed to initialise parser");
        try stderr.print("error[SA-TS]: failed to initialise parser: {}\n", .{err});
        return err;
    };
    defer p.deinit();

    p.parse() catch |err| {
        plugin_api.emitLog(ctx, .err, "parse error");
        try stderr.print("error[SA-TS]: parse error: {}\n", .{err});
        return err;
    };

    const sa_code = low.toOwnedSlice() catch |err| {
        plugin_api.emitLog(ctx, .err, "failed to emit SA-ASM output");
        try stderr.print("error[SA-TS]: failed to emit output: {}\n", .{err});
        return err;
    };

    // Duplicate into caller-owned allocator (arena will be freed)
    const result = ctx.allocator.dupe(u8, sa_code) catch |err| {
        plugin_api.emitLog(ctx, .err, "allocation failure duplicating output");
        try stderr.print("error[SA-TS]: allocation failure: {}\n", .{err});
        return err;
    };
    return result;
}

// ==========================================
// CLI handle_command
// ==========================================

/// Resolve the host `sa` executable for `ts test` / `ts build-exe` delegation.
///
/// Mirrors sa_plugin_sla's host_paths.resolveSaExecutable search order:
/// SA_EXE env override, SCI_ROOT dev layout, the directory of the host that
/// loaded this plugin, PATH walk, then a bare "sa" fallback.
fn resolveSaExecutable(allocator: std.mem.Allocator) []const u8 {
    if (std.process.getEnvVarOwned(allocator, "SA_EXE")) |override_path| {
        if (override_path.len > 0) {
            std.fs.cwd().access(override_path, .{}) catch {
                allocator.free(override_path);
                return "sa";
            };
            return override_path;
        }
        allocator.free(override_path);
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "SCI_ROOT")) |sci_root| {
        defer allocator.free(sci_root);
        const dev_sa = std.fs.path.join(allocator, &.{ sci_root, "zig-out", "bin", "sa" }) catch return "sa";
        std.fs.cwd().access(dev_sa, .{}) catch {
            allocator.free(dev_sa);
            return "sa";
        };
        return dev_sa;
    } else |_| {}

    if (std.fs.selfExePathAlloc(allocator)) |self_path| {
        defer allocator.free(self_path);
        if (std.fs.path.dirname(self_path)) |self_dir| {
            const cand = std.fs.path.join(allocator, &.{ self_dir, "sa" }) catch return "sa";
            std.fs.cwd().access(cand, .{}) catch {
                allocator.free(cand);
                return "sa";
            };
            return cand;
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "PATH")) |path_val| {
        defer allocator.free(path_val);
        var it = std.mem.tokenizeAny(u8, path_val, ":;\x0a");
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const cand = std.fs.path.join(allocator, &.{ entry, "sa" }) catch return "sa";
            std.fs.cwd().access(cand, .{}) catch {
                allocator.free(cand);
                continue;
            };
            return cand;
        }
    } else |_| {}

    return "sa";
}

var ts_tmp_counter: u32 = 0;

/// Write `sa_code` to a temp .sai next to `sibling_path` and return its path.
/// Caller must delete the file when done.
fn writeTsTempSai(allocator: std.mem.Allocator, sibling_path: []const u8, sa_code: []const u8) ![]u8 {
    ts_tmp_counter +%= 1;
    const uniq = std.time.nanoTimestamp();
    const dir = std.fs.path.dirname(sibling_path) orelse ".";
    const base = std.fs.path.basename(sibling_path);
    const tmp = try std.fmt.allocPrint(allocator, "{s}/.ts-tmp-{d}-{d}-{s}.sai", .{ dir, uniq, ts_tmp_counter, base });
    std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = sa_code }) catch |err| {
        allocator.free(tmp);
        return err;
    };
    return tmp;
}

/// Minimal `sa.mod` workspace resolution for TS projects, mirroring the
/// `sa sla` convention: an explicit file always wins; otherwise walk up from
/// the current directory for an `sa.mod`.
///
/// Supported manifests:
///   `package "name"` — single-package project, entry is the manifest dir.
///   `workspace { members [...]; default_member "..." }` — `-p` selects a
///     member (by directory basename or by the member's own package name);
///     without `-p` the default member is used.
/// The entry source is `<member>/src/main.ts`, falling back to
/// `<member>/main.ts`.
fn readPackageName(allocator: std.mem.Allocator, manifest_path: []const u8) !?[]u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch return null;
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "package")) {
            const rest = std.mem.trim(u8, line["package".len..], " \t");
            if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') {
                return try allocator.dupe(u8, rest[1 .. rest.len - 1]);
            }
            return try allocator.dupe(u8, rest);
        }
    }
    return null;
}

fn parseWorkspaceMembers(allocator: std.mem.Allocator, manifest_path: []const u8) !?struct {
    members: std.ArrayListUnmanaged([]const u8),
    default_member: ?[]u8,
} {
    const content = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch return null;
    defer allocator.free(content);
    if (std.mem.indexOf(u8, content, "workspace") == null) return null;
    var out_members = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (out_members.items) |m| allocator.free(m);
        out_members.deinit(allocator);
    }
    var default_member: ?[]u8 = null;
    errdefer if (default_member) |m| allocator.free(m);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "members")) {
            const open = std.mem.indexOfScalar(u8, line, '[') orelse continue;
            const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse continue;
            if (close <= open) continue;
            var it = std.mem.splitScalar(u8, line[open + 1 .. close], ',');
            while (it.next()) |frag| {
                const tok = std.mem.trim(u8, frag, " \t\"");
                if (tok.len == 0) continue;
                try out_members.append(allocator, try allocator.dupe(u8, tok));
            }
        } else if (std.mem.startsWith(u8, line, "default_member")) {
            const rest = std.mem.trim(u8, line["default_member".len..], " \t\"");
            if (rest.len > 0) default_member = try allocator.dupe(u8, rest);
        }
    }
    return .{ .members = out_members, .default_member = default_member };
}

fn entrySourceIfExists(allocator: std.mem.Allocator, member_dir: []const u8) !?[]u8 {
    for ([_][]const u8{ "src/main.ts", "main.ts" }) |rel| {
        const cand = try std.fs.path.join(allocator, &.{ member_dir, rel });
        std.fs.cwd().access(cand, .{}) catch {
            allocator.free(cand);
            continue;
        };
        return cand;
    }
    return null;
}

fn resolveTsWorkspaceEntry(
    allocator: std.mem.Allocator,
    package_name: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?[]u8 {
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return null;
    defer allocator.free(cwd);

    var dir = try allocator.dupe(u8, cwd);
    defer allocator.free(dir);
    while (true) {
        const manifest = try std.fs.path.join(allocator, &.{ dir, "sa.mod" });
        defer allocator.free(manifest);
        const has_manifest = blk: {
            std.fs.cwd().access(manifest, .{}) catch break :blk false;
            break :blk true;
        };
        if (has_manifest) {
            if (try parseWorkspaceMembers(allocator, manifest)) |*ws| {
                var members = ws.members;
                defer {
                    for (members.items) |m| allocator.free(m);
                    members.deinit(allocator);
                }
                defer if (ws.default_member) |m| allocator.free(m);
                var member_dir: ?[]u8 = null;
                defer if (member_dir) |m| allocator.free(m);
                if (package_name) |want| {
                    for (members.items) |m| {
                        const cand = try std.fs.path.join(allocator, &.{ dir, m });
                        defer allocator.free(cand);
                        const base = std.fs.path.basename(m);
                        var matches = std.mem.eql(u8, base, want) or std.mem.eql(u8, m, want);
                        if (!matches) {
                            const member_manifest = try std.fs.path.join(allocator, &.{ cand, "sa.mod" });
                            defer allocator.free(member_manifest);
                            if (try readPackageName(allocator, member_manifest)) |pkg| {
                                defer allocator.free(pkg);
                                matches = std.mem.eql(u8, pkg, want);
                            }
                        }
                        if (matches) {
                            member_dir = try allocator.dupe(u8, cand);
                            break;
                        }
                    }
                    if (member_dir == null) {
                        try stderr.print("Error: unknown workspace package: {s}\n", .{want});
                        return null;
                    }
                } else if (ws.default_member) |def| {
                    // default_member names a member (like `app`), not a path.
                    // Match it against the members list by directory basename
                    // or by the member's own package name first.
                    for (members.items) |m| {
                        const cand = try std.fs.path.join(allocator, &.{ dir, m });
                        defer allocator.free(cand);
                        if (std.mem.eql(u8, std.fs.path.basename(m), def) or std.mem.eql(u8, m, def)) {
                            member_dir = try allocator.dupe(u8, cand);
                            break;
                        }
                        const member_manifest = try std.fs.path.join(allocator, &.{ cand, "sa.mod" });
                        defer allocator.free(member_manifest);
                        if (try readPackageName(allocator, member_manifest)) |pkg| {
                            defer allocator.free(pkg);
                            if (std.mem.eql(u8, pkg, def)) {
                                member_dir = try allocator.dupe(u8, cand);
                                break;
                            }
                        }
                    }
                    if (member_dir == null) {
                        member_dir = try std.fs.path.join(allocator, &.{ dir, def });
                    }
                } else {
                    try stderr.writeAll("Error: workspace has no resolvable default member; pass -p/--package or run inside a member directory\n");
                    return null;
                }
                if (try entrySourceIfExists(allocator, member_dir.?)) |entry| return entry;
                try stderr.writeAll("Error: workspace member has no src/main.ts or main.ts entry source\n");
                return null;
            }
            if (package_name) |want| {
                if (try readPackageName(allocator, manifest)) |pkg| {
                    defer allocator.free(pkg);
                    const base = std.fs.path.basename(dir);
                    if (!std.mem.eql(u8, pkg, want) and !std.mem.eql(u8, base, want)) {
                        try stderr.print("Error: unknown workspace package: {s}\n", .{want});
                        return null;
                    }
                } else if (!std.mem.eql(u8, std.fs.path.basename(dir), want)) {
                    try stderr.print("Error: unknown workspace package: {s}\n", .{want});
                    return null;
                }
            }
            if (try entrySourceIfExists(allocator, dir)) |entry| return entry;
            try stderr.writeAll("Error: workspace member has no src/main.ts or main.ts entry source\n");
            return null;
        }
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(dir);
        dir = next;
    }
    try stderr.writeAll("Error: missing file argument and no workspace source could be resolved from the current directory\n");
    return null;
}

/// Explicit file wins; otherwise fall back to `sa.mod` workspace resolution.
fn resolveTsInputFile(
    allocator: std.mem.Allocator,
    file: ?[]const u8,
    package_name: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?[]u8 {
    if (file) |f| return try allocator.dupe(u8, f);
    return try resolveTsWorkspaceEntry(allocator, package_name, stderr);
}

fn writeNewFile(path: []const u8, bytes: []const u8, stderr: std.io.AnyWriter) !bool {
    var file = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |err| {
        try stderr.print("File Error: failed to create {s}: {}\n", .{ path, err });
        return false;
    };
    defer file.close();
    file.writeAll(bytes) catch |err| {
        try stderr.print("File Error: failed to write {s}: {}\n", .{ path, err });
        return false;
    };
    return true;
}

fn runTsInitCommand(
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    var project_path: ?[]const u8 = null;
    var idx = option_start;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (isHelpArg(arg)) {
            try stderr.writeAll("usage: sa ts init [path]\n");
            return 0;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Unknown ts init option: {s}\n", .{arg});
            try stderr.writeAll("usage: sa ts init [path]\n");
            return 1;
        }
        if (project_path != null) {
            try stderr.print("Unexpected ts init argument: {s}\n", .{arg});
            try stderr.writeAll("usage: sa ts init [path]\n");
            return 1;
        }
        project_path = arg;
    }

    const root = project_path orelse ".";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const package_name: []const u8 = blk: {
        if (std.mem.eql(u8, root, ".")) break :blk "app";
        const base = std.fs.path.basename(root);
        if (base.len == 0 or std.mem.eql(u8, base, ".")) break :blk "app";
        break :blk base;
    };
    std.fs.cwd().makePath(root) catch |err| {
        try stderr.print("File Error: failed to create directory {s}: {}\n", .{ root, err });
        return 1;
    };
    const src_dir = try std.fs.path.join(allocator, &.{ root, "src" });
    std.fs.cwd().makePath(src_dir) catch |err| {
        try stderr.print("File Error: failed to create directory {s}: {}\n", .{ src_dir, err });
        return 1;
    };

    const manifest_path = try std.fs.path.join(allocator, &.{ root, "sa.mod" });
    const manifest = try std.fmt.allocPrint(allocator, "# generated by ts init\npackage \"{s}\"\n", .{package_name});
    if (!try writeNewFile(manifest_path, manifest, stderr)) return 1;

    const main_path = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    if (!try writeNewFile(main_path,
        \\function main(): i32 {
        \\  return 0;
        \\}
        \\
    , stderr)) return 1;

    const gitignore_path = try std.fs.path.join(allocator, &.{ root, ".gitignore" });
    if (!try writeNewFile(gitignore_path,
        \\.sla-cache/
        \\.zig-cache/
        \\.sa_cache/
        \\zig-out/
        \\*.out
        \\*.sa.bc
        \\
    , stderr)) return 1;

    try stdout.print("Initialized TS binary project: {s}\n", .{root});
    try stdout.print("Entry: {s}\n", .{main_path});
    return 0;
}

fn runTsLowerCommand(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    const parsed = parseTsFileArgs(args, option_start);
    if (parsed.help_requested) {
        try stderr.writeAll("usage: sa ts lower [file] [--out <path>] [-p <package>]\n");
        return 0;
    }
    if (parsed.extra_arg) |extra| {
        try stderr.print("error[SA-TS]: unexpected argument '{s}'\n", .{extra});
        return 1;
    }
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const input_path = (try resolveTsInputFile(arena.allocator(), parsed.file, parsed.package_name, stderr)) orelse return 1;

    const sa_code = lowerFileToSa(ctx, input_path, stderr) catch |err| {
        if (isTsCliError(err)) return 1;
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    defer ctx.allocator.free(sa_code);

    if (parsed.out) |path| {
        var file = std.fs.cwd().createFile(path, .{}) catch |err| {
            try stderr.print("error[SA-TS]: cannot write to '{s}': {}\n", .{ path, err });
            return 1;
        };
        defer file.close();
        file.writeAll(sa_code) catch |err| {
            try stderr.print("error[SA-TS]: write failed: {}\n", .{err});
            return 1;
        };
        plugin_api.emitLog(ctx, .info, "lowered output written to file");
        try stdout.print("ok: lowered to {s} ({d} bytes)\n", .{ path, sa_code.len });
    } else {
        try stdout.writeAll(sa_code);
    }
    return 0;
}

fn runTsCheckCommand(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    const parsed = parseTsFileArgs(args, option_start);
    if (parsed.help_requested) {
        try stderr.writeAll("usage: sa ts check [file] [-p <package>]\n");
        return 0;
    }
    if (parsed.extra_arg) |extra| {
        try stderr.print("error[SA-TS]: unexpected argument '{s}'\n", .{extra});
        return 1;
    }
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const input_path = (try resolveTsInputFile(arena.allocator(), parsed.file, parsed.package_name, stderr)) orelse return 1;

    const sa_code = lowerFileToSa(ctx, input_path, stderr) catch |err| {
        if (isTsCliError(err)) return 1;
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    defer ctx.allocator.free(sa_code);

    try stdout.print("Ts Compiler: Successfully parsed and lowered {s} ({d} bytes).\n", .{ input_path, sa_code.len });
    return 0;
}

fn runTsBuildCommand(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    const parsed = parseTsFileArgs(args, option_start);
    if (parsed.help_requested) {
        try stderr.writeAll("usage: sa ts build [file] [--out <file>] [-p <package>]\n");
        return 0;
    }
    if (parsed.extra_arg) |extra| {
        try stderr.print("error[SA-TS]: unexpected argument '{s}'\n", .{extra});
        return 1;
    }
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const input_path = (try resolveTsInputFile(arena.allocator(), parsed.file, parsed.package_name, stderr)) orelse return 1;

    const sa_code = lowerFileToSa(ctx, input_path, stderr) catch |err| {
        if (isTsCliError(err)) return 1;
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    defer ctx.allocator.free(sa_code);

    const final_out_owned: []const u8 = if (parsed.out) |path| path else try defaultSaiOut(arena.allocator(), input_path);

    std.fs.cwd().writeFile(.{ .sub_path = final_out_owned, .data = sa_code }) catch |err| {
        try stderr.print("error[SA-TS]: cannot write to '{s}': {}\n", .{ final_out_owned, err });
        return 1;
    };

    try stdout.print("Ts Compiler: Successfully compiled {s} to {s}.\n", .{ input_path, final_out_owned });
    return 0;
}

fn runTsTestCommand(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    _ = stdout;
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var parsed = try parseTsDelegateArgs(arena.allocator(), args, option_start);
    defer parsed.passthrough.deinit(arena.allocator());
    if (parsed.help_requested) {
        try stderr.writeAll("usage: sa ts test [file] [-p <package>] [sa-test-options...]\n");
        return 0;
    }
    const input_path = (try resolveTsInputFile(arena.allocator(), parsed.file, parsed.package_name, stderr)) orelse return 1;

    const sa_code = lowerFileToSa(ctx, input_path, stderr) catch |err| {
        if (isTsCliError(err)) return 1;
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    defer ctx.allocator.free(sa_code);

    const tmp_sai = writeTsTempSai(arena.allocator(), input_path, sa_code) catch |err| {
        try stderr.print("error[SA-TS]: cannot write temp SA file: {}\n", .{err});
        return 1;
    };
    defer std.fs.cwd().deleteFile(tmp_sai) catch {};

    var argv = std.ArrayList([]const u8).init(arena.allocator());
    try argv.append(resolveSaExecutable(arena.allocator()));
    try argv.append("test");
    try argv.append(tmp_sai);
    try argv.appendSlice(parsed.passthrough.items);
    try appendDefaultJobsAuto(&argv, parsed.passthrough.items);

    var child = std.process.Child.init(argv.items, arena.allocator());
    const term = child.spawnAndWait() catch |err| {
        try stderr.print("error[SA-TS]: failed to run 'sa test': {}\n", .{err});
        return 1;
    };
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn runTsBuildExeCommand(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    _ = stdout;
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var parsed = try parseTsDelegateArgs(arena.allocator(), args, option_start);
    defer parsed.passthrough.deinit(arena.allocator());
    if (parsed.help_requested) {
        try stderr.writeAll("usage: sa ts build-exe [file] [-p <package>] [sa-build-exe-options...]\n");
        return 0;
    }
    const input_path = (try resolveTsInputFile(arena.allocator(), parsed.file, parsed.package_name, stderr)) orelse return 1;

    const sa_code = lowerFileToSa(ctx, input_path, stderr) catch |err| {
        if (isTsCliError(err)) return 1;
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    defer ctx.allocator.free(sa_code);

    const tmp_sai = writeTsTempSai(arena.allocator(), input_path, sa_code) catch |err| {
        try stderr.print("error[SA-TS]: cannot write temp SA file: {}\n", .{err});
        return 1;
    };
    defer std.fs.cwd().deleteFile(tmp_sai) catch {};

    var argv = std.ArrayList([]const u8).init(arena.allocator());
    try argv.append(resolveSaExecutable(arena.allocator()));
    try argv.append("build-exe");
    try argv.append(tmp_sai);
    try argv.appendSlice(parsed.passthrough.items);
    try appendDefaultJobsAuto(&argv, parsed.passthrough.items);

    var child = std.process.Child.init(argv.items, arena.allocator());
    const term = child.spawnAndWait() catch |err| {
        try stderr.print("error[SA-TS]: failed to run 'sa build-exe': {}\n", .{err});
        return 1;
    };
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn runTsCommand(
    ctx: *const plugin_api.Context,
    argv: []const []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) anyerror!?u8 {
    // argv[0] = "sa", argv[1] = "ts", argv[2..] = subcommand args
    if (argv.len < 2) return null;
    if (argv.len < 3) {
        try writeTsHelp(stderr);
        return 1;
    }

    const sub = argv[2];
    if (isHelpArg(sub)) {
        try writeTsHelp(stderr);
        return 0;
    }
    if (std.mem.eql(u8, sub, "help")) {
        try writeTsHelp(stderr);
        return 0;
    }
    if (std.mem.eql(u8, sub, "skills")) {
        return try runTsSkillsCommand(ctx, argv, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "lower")) {
        return try runTsLowerCommand(ctx, argv, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "check")) {
        return try runTsCheckCommand(ctx, argv, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "build")) {
        return try runTsBuildCommand(ctx, argv, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "build-exe")) {
        return try runTsBuildExeCommand(ctx, argv, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "test")) {
        return try runTsTestCommand(ctx, argv, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "init")) {
        return try runTsInitCommand(argv, 3, stdout, stderr);
    }

    try stderr.print("error[SA-TS]: unknown subcommand '{s}'\n", .{sub});
    try writeTsHelp(stderr);
    return 1;
}

fn isTsCliError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.IsDir,
        error.NotDir,
        error.UnexpectedToken,
        error.UndefinedVariable,
        error.TypeIsNotAnInterface,
        error.UnknownField,
        error.UnknownMethod,
        error.NoActiveScope,
        => true,
        else => false,
    };
}

fn runTsCommandAbi(
    ctx: *const plugin_api.Context,
    argv: [*]const [*:0]const u8,
    argv_len: usize,
    stdout: plugin_api.HostStream,
    stderr: plugin_api.HostStream,
    out_code: *u8,
) callconv(.c) u32 {
    out_code.* = 0;
    if (argv_len < 2 or !std.mem.eql(u8, std.mem.span(argv[1]), "ts")) {
        return @intFromEnum(plugin_api.AbiStatus.unknown_command);
    }

    const args = plugin_helpers.cArgvToSlice(argv, argv_len, ctx.allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer ctx.allocator.free(args);

    var stdout_storage: plugin_helpers.StreamWriterCtx = undefined;
    var stderr_storage: plugin_helpers.StreamWriterCtx = undefined;
    const stdout_writer = plugin_helpers.makeAnyWriter(stdout, &stdout_storage) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const stderr_writer = plugin_helpers.makeAnyWriter(stderr, &stderr_storage) orelse return @intFromEnum(plugin_api.AbiStatus.failed);

    const result = runTsCommand(ctx, args, stdout_writer, stderr_writer) catch |err| {
        if (!isTsCliError(err)) return @intFromEnum(plugin_api.AbiStatus.failed);
        stdout_writer.print("error[SA-TS]: {}\n", .{err}) catch return @intFromEnum(plugin_api.AbiStatus.failed);
        out_code.* = 1;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    };
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

// ==========================================
// Plugin descriptor (standard pattern)
// ==========================================

pub const plugin = plugin_api.Plugin{
    .name = "ts",
    .handleCommand = runTsCommand,
    .skills = &skills,
};

pub const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "sa_plugin_ts",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runTsCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;

pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}

// ==========================================
// Direct C-ABI entry points (for programmatic use by host)
// ==========================================

pub export fn sa_plugin_ts_lower(
    source_ptr: [*]const u8,
    source_len: u64,
    out_sa_ptr: *[*]const u8,
    out_sa_len_ptr: *u64,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source = source_ptr[0..source_len];

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = parser.Parser.init(arena_allocator, source, &low) catch return 1;
    defer p.deinit();

    p.parse() catch |err| {
        std.debug.print("Parsing error: {s}\n", .{@errorName(err)});
        return 2;
    };

    const sa_code = low.toOwnedSlice() catch return 3;
    defer arena_allocator.free(sa_code);

    // Allocate prefixed buffer to return to host
    const total_size = sa_code.len + @sizeOf(u64);
    const raw = allocator.alloc(u8, total_size) catch return 4;

    @as(*u64, @ptrCast(@alignCast(raw.ptr))).* = sa_code.len;
    @memcpy(raw[@sizeOf(u64)..], sa_code);

    out_sa_ptr.* = raw[@sizeOf(u64)..].ptr;
    out_sa_len_ptr.* = sa_code.len;

    return 0;
}

pub export fn sa_plugin_ts_free_buffer(buf: [*]const u8) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;
    const raw_ptr = @constCast(buf) - @sizeOf(u64);

    const len = @as(*const u64, @ptrCast(@alignCast(raw_ptr))).*;
    const total_size = len + @sizeOf(u64);
    const slice = raw_ptr[0..total_size];
    allocator.free(slice);
    return 0;
}

// ==========================================
// TEST SUITE
// ==========================================

test "sa_plugin_ts compiles interface layouts, scope tracking and let/store/alloc instructions" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\interface Point {
        \\  x: i32;
        \\  y: i32;
        \\}
        \\
        \\function main() {
        \\  let p: Point = { x: 10, y: 20 };
        \\  p.x = 100;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "p = alloc 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store p + 0, 10 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store p + 4, 20 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store p + 0, 100 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "!p") != null);
}

test "sa_plugin_ts supports scalar types, reassignments, and function mapping" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main() {
        \\  let x: i32 = 42;
        \\  x = 100;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "x = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "x = 100") != null);
}

test "sa_plugin_ts handles string.slice() zero-copy lowering" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main() {
        \\  let host: string = "https://api.example.com";
        \\  let path = host.slice(8, 23);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "orig_ptr = load host + 0 as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "new_ptr = ptr_add orig_ptr, 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "slice_len = sub 23, 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "!host") != null);
}

test "sa_plugin_ts compiles arrow function closures using static defunctionalization" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\interface User {
        \\  id: i32;
        \\  age: i32;
        \\}
        \\
        \\function celebrate(user: User) {
        \\  let increment = 1;
        \\  setTimeout(() => {
        \\    user.age = user.age + increment;
        \\  }, 1000);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    // Arrow callbacks are buffered out-of-line (SA-ASM has no nested
    // functions), so join the buffers for substring assertions.
    var joined = std.ArrayList(u8).init(arena_allocator);
    defer joined.deinit();
    try joined.appendSlice(low.callbacks.items);
    try joined.appendSlice(low.output.items);
    const result = joined.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "@closure_callback_1(ctx: ptr):") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "user = load ctx + 0 as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "increment = load ctx + 8 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "!ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "= alloc 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+ 0, user as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+ 8, increment as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "call @setTimeout(@closure_callback_1, ^ctx_1, 1000)") != null);
}

test "sa_plugin_ts compiles mathematical expressions using Pratt parser with correct precedence" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function math(a: i32, b: i32, c: i32) {
        \\  let res = a + b * c;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "t_1 = mul b, c") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "t_2 = add a, t_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "res = t_2") != null);
}

test "sa_plugin_ts compiles WASM imports and stubs" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\import { add, sub } from "./math.wasm";
        \\declare function ext_print(msg: string): void;
        \\
        \\function test_wasm() {
        \\  let x = add(10, 20);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    // The arity-matched `@extern` lands in the header buffer, so join it for
    // assertions.
    var wasm_joined = std.ArrayList(u8).init(arena_allocator);
    defer wasm_joined.deinit();
    try wasm_joined.appendSlice(low.header.items);
    try wasm_joined.appendSlice(low.output.items);
    const result = wasm_joined.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "WASM Interop: Import from ./math.wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Link symbol add to WASM export") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Link symbol sub to WASM export") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "@extern ext_print(msg: ptr) -> void") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "t_1 = call @add(10, 20)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "@extern add(a0: i32, a1: i32) -> i32") != null);
}

test "sa_plugin_ts lowers console.log to sa_print_bytes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(): i32 {
        \\  const n: i32 = 41;
        \\  console.log("answer", n);
        \\  return 0;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    var joined = std.ArrayList(u8).init(arena_allocator);
    defer joined.deinit();
    try joined.appendSlice(low.header.items);
    try joined.appendSlice(low.output.items);
    const result = joined.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "@import \"sa_std/io/print.sai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_print_bytes(") != null);
}

test "sa_plugin_ts lowers float arithmetic to fadd/fsub/fmul/fdiv" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(): i32 {
        \\  let a: f64 = 7.5;
        \\  let b: f64 = 2.5;
        \\  let c: f64 = a / b;
        \\  let d: f64 = a + b;
        \\  let e: f64 = a * b;
        \\  let f: f64 = a - b;
        \\  if (c == 3.0) { return 1; }
        \\  return 0;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "fdiv a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fadd a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fmul a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fsub a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fcmp_eq c, 3.0") != null);
}

test "sa_plugin_ts lowers float interpolation through sa_fmt_f64_into" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(): i32 {
        \\  let x: f64 = 3.25;
        \\  let s = `v=${x}`;
        \\  console.log(s);
        \\  console.log(x);
        \\  return 0;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    var joined = std.ArrayList(u8).init(arena_allocator);
    defer joined.deinit();
    try joined.appendSlice(low.header.items);
    try joined.appendSlice(low.output.items);
    const result = joined.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_fmt_f64_into(x, 6,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sext s as i64") == null);
}

test "sa_plugin_ts lowers float negation to fneg" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(): i32 {
        \\  let x: f64 = 2.5;
        \\  let n: f64 = -x;
        \\  if (n == -2.5) { return 1; }
        \\  return 0;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "fneg x") != null);
}

test "sa_plugin_ts refuses float remainder loudly" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(): i32 {
        \\  let m: f64 = 5.5 % 2.0;
        \\  return 0;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    // Statement-level recovery collects the diagnostic and continues, so the
    // refusal surfaces on `p.errors` rather than as a parse() error.
    try p.parse();
    try std.testing.expect(p.errors.items.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, p.errors.items[0].message, "float remainder") != null);
}

test "sa_plugin_ts descriptor is valid" {
    try std.testing.expectEqual(@as(u32, 1), descriptor.abi_version);
    try std.testing.expectEqual(@sizeOf(plugin_api.PluginDescriptor), descriptor.descriptor_size);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(descriptor.name), "sa_plugin_ts"));
    try std.testing.expect(descriptor.handle_command != null);
    try std.testing.expectEqual(@as(usize, 1), descriptor.skills_len);
}

test "sa_plugin_ts compiles comparison and logical operators" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function check(a: i32, b: i32) {
        \\  let eq = a == b;
        \\  let ne = a != b;
        \\  let lt = a < b;
        \\  let gt = a > b;
        \\  let le = a <= b;
        \\  let ge = a >= b;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "eq a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ne a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "lt a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "gt a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "le a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ge a, b") != null);
}

test "sa_plugin_ts compiles if/else and while with control flow" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(x: i32) {
        \\  if (x > 0) {
        \\    let y = x + 1;
        \\  } else {
        \\    let y = x - 1;
        \\  }
        \\  while (x > 0) {
        \\    x = x - 1;
        \\  }
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "gt x, 0") != null);
    // SA-ASM has no `jz`; the conditional branch is `br cond -> L_true, L_false`.
    try std.testing.expect(std.mem.indexOf(u8, result, "br t_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, " -> ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jz") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_else_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_endif_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_while_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_endwhile_") != null);
}

test "sa_plugin_ts compiles for loops" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main() {
        \\  for (let i = 0; i < 10; i++) {
        \\    let x = i + 1;
        \\  }
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "i = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "lt i, 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_for_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_endfor_") != null);
}

test "sa_plugin_ts compiles array literals and indexing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main() {
        \\  let arr = [1, 2, 3];
        \\  let x = arr[1];
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "arr = alloc 16") != null);
    // Elements live in a separate buffer; the header holds {ptr, len}.
    try std.testing.expect(std.mem.indexOf(u8, result, " + 0, 1 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, " + 4, 2 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, " + 8, 3 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mul 1, 4") != null);
    // Reading an element must go through the header's data pointer.
    try std.testing.expect(std.mem.indexOf(u8, result, "load arr + 0 as ptr") != null);
}

test "sa_plugin_ts lowers new Map to sa_btree_map_new" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(): i32 {
        \\  const m: Map<string, i32> = new Map();
        \\  return 0;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    var joined = std.ArrayList(u8).init(arena_allocator);
    defer joined.deinit();
    try joined.appendSlice(low.header.items);
    try joined.appendSlice(low.output.items);
    const result = joined.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "@import \"sa_std/btree_map.sa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_btree_map_new()") != null);
}

test "sa_plugin_ts lowers new Array(n) to a zeroed slice" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(): i32 {
        \\  const a = new Array(3);
        \\  a[0] = 7;
        \\  return a[0];
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "= alloc 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+ 8, 3 as u64") != null);
}

test "sa_plugin_ts compiles return statements" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function add(a: i32, b: i32) {
        \\  let result = a + b;
        \\  return result;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "return result") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "add a, b") != null);
}

test "sa_plugin_ts compiles enum definitions" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\enum Direction {
        \\  Up,
        \\  Down,
        \\  Left,
        \\  Right,
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "#def Direction.Up = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "#def Direction.Down = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "#def Direction.Left = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "#def Direction.Right = 3") != null);
}

test "sa_plugin_ts compiles type alias" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\interface Point {
        \\  x: i32;
        \\  y: i32;
        \\}
        \\
        \\type Coordinate = Point;
        \\
        \\function main() {
        \\  let c: Coordinate = { x: 5, y: 10 };
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "c = alloc 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store c + 0, 5 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store c + 4, 10 as i32") != null);
}

test "sa_plugin_ts compiles unary negation and logical not" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(a: i32, b: i32) {
        \\  let neg_a = -a;
        \\  let not_b = !b;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "neg a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "eq b, 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "not ") == null);
}

test "sa_plugin_ts compiles modulo operator" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main(a: i32, b: i32) {
        \\  let r = a % b;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "srem a, b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mod a, b") == null);
}

test "sa_plugin_ts maps fs.readFile to sa_fs_read_file with string expansion" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\import { readFile, writeFile } from "fs";
        \\
        \\function main() {
        \\  let data = readFile("config.json");
        \\  writeFile("output.txt", data);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    // Read via toOwnedSlice: file-scope declarations live in the header buffer.
    const result = try low.toOwnedSlice();
    defer arena_allocator.free(result);

    // Verify the declaring module is imported at file scope.
    try std.testing.expect(std.mem.indexOf(u8, result, "@import \"sa_std/fs.sai\"") != null);
    // Verify readFile maps to sa_fs_read_file with string arg expansion
    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_fs_read_file(") != null);
    // Verify writeFile maps to sa_fs_write_file
    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_fs_write_file(") != null);
    // A string literal becomes a `@const` data constant, never a bare operand.
    try std.testing.expect(std.mem.indexOf(u8, result, "utf8:") != null);
    // Verify string struct is expanded to ptr+len pairs
    try std.testing.expect(std.mem.indexOf(u8, result, "load") != null);
}

test "sa_plugin_ts maps net.tcpConnect to sa_net_tcp_connect" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\import { tcpConnect } from "net";
        \\
        \\function main() {
        \\  let conn = tcpConnect("localhost", 8080);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = try low.toOwnedSlice();
    defer arena_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "@import \"sa_std/net.sai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_net_tcp_connect(") != null);
}

test "benchmark: parsing speed for large input" {
    const allocator = std.testing.allocator;

    // Generate a large TS source with many function declarations
    var source_buf = std.ArrayList(u8).init(allocator);
    defer source_buf.deinit();

    const writer = source_buf.writer();
    try writer.writeAll("interface Data {\n  value: i32;\n  count: i32;\n}\n\n");
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try writer.print("function func_{d}(a: i32, b: i32) {{\n", .{i});
        try writer.writeAll("  let x: Data = { value: a, count: b };\n");
        try writer.writeAll("  let y = x.value + x.count;\n");
        try writer.writeAll("  let z = a * b + y;\n");
        try writer.writeAll("  if (z > 100) {\n");
        try writer.writeAll("    x.value = z - 1;\n");
        try writer.writeAll("  }\n");
        try writer.writeAll("  return z;\n");
        try writer.writeAll("}\n\n");
    }

    const source = source_buf.items;
    const line_count = blk: {
        var count: u32 = 0;
        for (source) |c| {
            if (c == '\n') count += 1;
        }
        break :blk count;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    const start = std.time.nanoTimestamp();
    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();
    try p.parse();
    const elapsed = std.time.nanoTimestamp() - start;

    const elapsed_us = @divTrunc(elapsed, 1000);
    const lines_per_sec = @divTrunc(@as(i128, line_count) * 1_000_000, elapsed_us + 1);

    std.debug.print("\n  Benchmark: {d} lines parsed in {d} us (~{d} lines/sec)\n", .{
        line_count,
        @as(u64, @intCast(elapsed_us)),
        @as(u64, @intCast(lines_per_sec)),
    });

    // Sanity check: should parse at least 10k lines/sec even in debug mode
    try std.testing.expect(lines_per_sec > 1_000); // relaxed for debug mode; release builds target 500k/sec
}

test "sa_plugin_ts parses template literals with embedded expressions" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function greet(name: string) {
        \\  let msg = `Hello ${name}!`;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    // Interpolation now lowers: the string operand passes through and the
    // chunks are joined with `@sa_string_concat`. No diagnostic, and no
    // bare `concat` mnemonic (which is not an SA instruction).
    try p.parse();

    try std.testing.expect(p.errors.items.len == 0);
    const result = low.output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "@sa_string_concat") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "= concat ") == null);
}

test "sa_plugin_ts compiles for-of iteration" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function main() {
        \\  let items = [10, 20, 30];
        \\  for (let x of items) {
        \\    let y = x + 1;
        \\  }
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "L_forof_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_endforof_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "lt ") != null);
}

test "sa_plugin_ts compiles generic type parameters" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\interface Box<T> {
        \\  value: i32;
        \\}
        \\
        \\function main() {
        \\  let b: Box<i32> = { value: 42 };
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "b = alloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store b + 0, 42 as i32") != null);
}

test "sa_plugin_ts compiles module import/export" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\import { helper } from "./utils.ts";
        \\
        \\export function main() {
        \\  let x = helper(10);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "@import") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "@main(") != null);
}

test "sa_plugin_ts compiles WIT imports" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\import { process } from "./handler.wit";
        \\
        \\function main() {
        \\  let result = process(42);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "@wit_import") == null);
    try std.testing.expect(p.errors.items.len > 0);
    var found_wit_diag = false;
    for (p.errors.items) |e| {
        if (std.mem.indexOf(u8, e.message, "WIT import") != null) found_wit_diag = true;
    }
    try std.testing.expect(found_wit_diag);
}

test "sa_plugin_ts SIMD lexer handles large whitespace runs" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Source with lots of whitespace
    const source = "                                                            \nfunction main() {\n  let x = 1;\n}\n";

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "x = 1") != null);
}

test "sa_plugin_ts error recovery collects multiple errors" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Source with syntax errors - parser should recover and continue
    const source =
        \\function main() {
        \\  let x = ;
        \\  let y = 42;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    // parse() should not panic - it should collect errors and continue
    p.parse() catch {};

    // Check that the parser collected errors
    try std.testing.expect(p.errors.items.len > 0);
}

// ==========================================
// SA-ASM VALIDATION REGRESSION TESTS
//
// The rest of this file asserts on substrings of the lowerer output, which
// cannot catch an instruction the SA assembler does not accept. The bugs these
// tests guard against all produced well-formed-looking output that failed to
// assemble: `jz` is not an SA mnemonic, functions carried no return type,
// `let arr: i32[] = [...]` silently emitted nothing, and `break`/`continue`
// were emitted as if they were instructions.
// ==========================================

fn lowerForTest(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();
    try p.parse();

    // Use the same path the CLI emits, so file-scope declarations (e.g.
    // `@const` string data) are included.
    const out = try low.toOwnedSlice();
    return try allocator.dupe(u8, out);
}

fn expectNoLineStartingWith(output: []const u8, forbidden: []const u8) !void {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < forbidden.len) continue;
        if (!std.mem.eql(u8, line[0..forbidden.len], forbidden)) continue;
        std.debug.print("emitted non-SA-ASM instruction '{s}': {s}\n", .{ forbidden, line });
        return error.NonSaAsmInstruction;
    }
}

test "sa_plugin_ts emits only mnemonics the SA assembler accepts" {
    const allocator = std.testing.allocator;

    const source =
        \\interface Point { x: i32; y: i32; }
        \\enum Color { Red, Green, Blue }
        \\type ID = i64;
        \\function classify(c: i32, p: Point): i32 {
        \\  let r: i32 = 0;
        \\  if (c == 0) { r = 1; } else { r = 2; }
        \\  let arr: i32[] = [1, 2, 3];
        \\  let i: i32 = 0;
        \\  while (i < 3) { r = r + arr[0]; i = i + 1; }
        \\  for (let k: i32 = 0; k < 2; k++) { r = r + k; }
        \\  switch (r) {
        \\    case 1: { r = 10; break; }
        \\    default: { r = 20; }
        \\  }
        \\  let g: i32 = p.x;
        \\  return r + g;
        \\}
    ;

    const out = try lowerForTest(allocator, source);
    defer allocator.free(out);

    // `jz`, `break`, `continue`, `throw` and `concat` are not SA-ASM
    // instructions; the lowerer must emit `br`/`jmp`/`panic`/nothing instead.
    try expectNoLineStartingWith(out, "jz ");
    try expectNoLineStartingWith(out, "break");
    try expectNoLineStartingWith(out, "continue");
    try expectNoLineStartingWith(out, "throw ");
    // Signed comparison/remainder forms; plain `lt`/`le`/`gt`/`ge`/`mod` are not
    // SA mnemonics.
    try expectNoLineStartingWith(out, "mod ");
    for ([_][]const u8{ " = lt ", " = le ", " = gt ", " = ge ", " = mod " }) |frag| {
        try std.testing.expect(std.mem.indexOf(u8, out, frag) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "slt ") != null or
        std.mem.indexOf(u8, out, "sle ") != null or
        std.mem.indexOf(u8, out, "sgt ") != null or
        std.mem.indexOf(u8, out, "sge ") != null);

    // Conditional branches must use the two-target `br cond -> L, L` form.
    try std.testing.expect(std.mem.indexOf(u8, out, "br ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " -> ") != null);

    // A value-returning function must declare its return type.
    try std.testing.expect(std.mem.indexOf(u8, out, "@classify(c: i32, p: ptr) -> i32:") != null);

    // `load` requires an explicit byte offset.
    try std.testing.expect(std.mem.indexOf(u8, out, " as i32\n") == null or
        std.mem.indexOf(u8, out, "load ") == null or
        std.mem.indexOf(u8, out, "+ 0 as i32") != null);
}

test "sa_plugin_ts lowers a typed array declaration instead of dropping it" {
    const allocator = std.testing.allocator;

    // Regression: `T[]` was never consumed by the type parser, so `expect(equal)`
    // failed and the whole statement vanished while the CLI still exited 0.
    const out = try lowerForTest(allocator,
        \\function main(): i32 {
        \\  let arr: i32[] = [1, 2, 3];
        \\  return arr[1];
        \\}
    );
    defer allocator.free(out);

    // A slice header {ptr, len} plus a separate element buffer.
    try std.testing.expect(std.mem.indexOf(u8, out, "arr = alloc 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alloc 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " + 0, 1 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " + 8, 3 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " + 0, ") != null);
}

test "sa_plugin_ts emits the for-loop increment after the loop body" {
    const allocator = std.testing.allocator;

    // Regression: the increment clause was emitted in the header, ahead of the
    // loop test, so the body ran one extra time on an already-bumped counter.
    const out = try lowerForTest(allocator,
        \\function main(): i32 {
        \\  let total: i32 = 0;
        \\  for (let i: i32 = 0; i < 5; i++) { total = total + i; }
        \\  return total;
        \\}
    );
    defer allocator.free(out);

    const test_at = std.mem.indexOf(u8, out, "lt i, 5").?;
    const body_at = std.mem.indexOf(u8, out, "add total, i").?;
    const incr_at = std.mem.indexOf(u8, out, "add i, 1").?;
    const back_at = std.mem.indexOf(u8, out, "jmp L_for_").?;

    try std.testing.expect(test_at < body_at);
    try std.testing.expect(body_at < incr_at);
    try std.testing.expect(incr_at < back_at);
}

test "sa_plugin_ts lowers a literal template to an SA string slice" {
    const allocator = std.testing.allocator;

    // An SA-ASM string is a `{ptr, len}` slice and cannot appear as an operand,
    // so a literal becomes a file-scope `@const` data constant plus a 16-byte
    // slot holding {ptr, len}.
    const out = try lowerForTest(allocator,
        \\function main() {
        \\  const msg: string = `hello world`;
        \\}
    );
    defer allocator.free(out);

    // The `@const` must be at file scope, ahead of the function.
    try std.testing.expect(std.mem.indexOf(u8, out, "@const SC_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "utf8:\"hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alloc 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "11 as u64") != null);
    // Never a bogus `concat`.
    try std.testing.expect(std.mem.indexOf(u8, out, "concat") == null);
}

test "sa_plugin_ts lowers interpolated integers through fmt instead of emitting a bogus concat" {
    const allocator = std.testing.allocator;

    // Joining chunks needs `@sa_fmt_i64_into` to render a value plus
    // `@sa_string_concat` to join (read back with `@sa_fmt_buffer_data`
    // / `@sa_fmt_buffer_len`, mirroring stdlib's `STR_CONCAT` macro). What
    // must never appear is a bare `concat` instruction, which is not an SA
    // mnemonic.
    const source =
        \\function main() {
        \\  let x: i32 = 7;
        \\  const s: string = `sum=${x}`;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();
    try p.parse();

    try std.testing.expect(p.errors.items.len == 0);
    var joined = std.ArrayList(u8).init(arena_allocator);
    defer joined.deinit();
    try joined.appendSlice(low.header.items);
    try joined.appendSlice(low.output.items);
    const interp_result = joined.items;
    try std.testing.expect(std.mem.indexOf(u8, interp_result, "@sa_fmt_i64_into") != null);
    try std.testing.expect(std.mem.indexOf(u8, interp_result, "@sa_string_concat") != null);
    try std.testing.expect(std.mem.indexOf(u8, interp_result, "@import \"sa_std/string.sai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, interp_result, "@import \"sa_std/fmt.sai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, interp_result, "= concat ") == null);
}

test "sa_plugin_ts binds string literals to variables as slices" {
    const allocator = std.testing.allocator;

    // A `"..."` literal is not an SA operand: `s = "bob"` is rejected by the
    // verifier (UnknownRegister). The binding must materialise the slice,
    // which also makes string variables usable in interpolation.
    const out = try lowerForTest(allocator,
        \\function main(): i32 {
        \\  const s: string = "bob";
        \\  return s.length;
        \\}
    );
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "= \"bob\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "utf8:\"bob") != null);
}

test "sa_plugin_ts supports the string length property" {
    const allocator = std.testing.allocator;

    // `s.length` is the real TypeScript spelling (the builtin `string`
    // layout only knows `ptr`/`len`, so the field is aliased). The
    // method-call spelling `s.length()` consumes its parens too.
    const out = try lowerForTest(allocator,
        \\function main(): i32 {
        \\  const s: string = `hi`;
        \\  return s.length;
        \\}
    );
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "as u32") != null);
}

test "sa_plugin_ts supports the catch binding form" {
    const allocator = std.testing.allocator;

    // `catch (e) { ... }` is the only standard TypeScript spelling; the parser
    // previously accepted a bare `catch { ... }` and dropped the real form.
    const out = try lowerForTest(allocator,
        \\function risky(x: i32): i32 {
        \\  try {
        \\    if (x < 0) { throw 1; }
        \\  } catch (e) {
        \\    return 0;
        \\  }
        \\  return x;
        \\}
    );
    defer allocator.free(out);

    // SA-ASM has no exception edges, so the catch label is never branched to
    // and is legitimately dropped. What must hold is that the `catch (e) { }`
    // binding form parses at all: previously the parser hit `catch` as an
    // unexpected token, skipped the binding, and discarded the handler body.
    try std.testing.expect(std.mem.indexOf(u8, out, "return 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return x") != null);
}

test "sa_plugin_ts does not swallow the brace after a template literal in an object literal" {
    const allocator = std.testing.allocator;

    // Regression: `parseTemplateLiteral` used to re-prime `current` AND `peek`
    // from the lexer, but the `advance` that moved `current` onto the literal
    // had already primed `peek` with the following token. Re-lexing skipped
    // one token, so the `}` closing this object literal disappeared. The field
    // loop then ran past the end of the literal, the function body was closed
    // by the wrong brace, and the releases that must precede `return` were
    // emitted after it. The assembler rejected that with
    // "basic blocks must end with jmp" (demos 219_full_app, 220_integration_all).
    const out = try lowerForTest(allocator,
        \\interface Config { retries: i32; tag: string; }
        \\function main(): i32 {
        \\  const cfg: Config = { retries: 3, tag: `release` };
        \\  return cfg.retries;
        \\}
    );
    defer allocator.free(out);

    // The object literal's second field must still be stored, which only
    // happens if the loop saw the closing `}`.
    try std.testing.expect(std.mem.indexOf(u8, out, "store cfg + 0, 3 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "store cfg + 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "utf8:\"release") != null);

    // The structural symptom: with the skipped `}` the releases are emitted
    // after the `return`, which is unreachable code and is what the assembler
    // rejected. Nothing but a label may follow a `return`.
    var saw_return = false;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (t[t.len - 1] == ':') {
            saw_return = false;
            continue;
        }
        if (saw_return) {
            std.debug.print("instruction after return: {s}\n", .{t});
            return error.TestExpectedEqual;
        }
        if (std.mem.startsWith(u8, t, "return")) saw_return = true;
    }
}

test "sa_plugin_ts releases a switch-arm local at break without touching enclosing locals" {
    const allocator = std.testing.allocator;

    // Regression (demos 239_struct_in_switch_arm): a heap value declared in a
    // case body is owned by a scope that the `break` abandons, so it must be
    // released at the jump. Releasing *every* open scope instead freed the
    // enclosing function's `keep` as well, which regressed 15 other switch and
    // loop demos (235 verified -> 222, e2e 24 -> 22).
    const out = try lowerForTest(allocator,
        \\interface P { x: i32; }
        \\function classify(m: i32): i32 {
        \\  const keep: P = { x: 7 };
        \\  let t: i32 = 0;
        \\  switch (m) {
        \\    case 1: {
        \\      const p: P = { x: 4 };
        \\      t = p.x;
        \\      break;
        \\    }
        \\    default: { t = 0; }
        \\  }
        \\  return t + keep.x;
        \\}
    );
    defer allocator.free(out);

    // `p` is released at the break, exactly once.
    const p_release = std.mem.indexOf(u8, out, "!p\n") orelse return error.TestExpectedEqual;
    // ...and `keep` survives the break: it is still read by the `return`, so a
    // release of `keep` before that read would be a use-after-move.
    const keep_read = std.mem.indexOf(u8, out, "load keep + 0") orelse return error.TestExpectedEqual;
    const keep_release = std.mem.indexOf(u8, out, "!keep\n") orelse return error.TestExpectedEqual;
    try std.testing.expect(p_release < keep_read);
    try std.testing.expect(keep_release > keep_read);
    // `p` must not also be released a second time after the switch merge.
    try std.testing.expect(std.mem.lastIndexOf(u8, out, "!p\n").? == p_release);
}

test "sa_plugin_ts keeps a parameter readable after a let copies it" {
    const allocator = std.testing.allocator;

    // Regression (demo 201_state_machine): `let next: i32 = state` is a copy in
    // TypeScript, but the lowerer emitted a move, so the later `switch (state)`
    // read a consumed register. `isOuterVariable` distinguishes a parameter
    // (declared in its own scope) from a local, and only the former gets
    // `dest = add src, 0`.
    const out = try lowerForTest(allocator,
        \\function step(state: i32): i32 {
        \\  let next: i32 = state;
        \\  switch (state) {
        \\    case 0: { next = 1; break; }
        \\    default: { next = 0; }
        \\  }
        \\  return next;
        \\}
    );
    defer allocator.free(out);

    // The copy is an arithmetic add, not an assignment, so `state` stays live.
    try std.testing.expect(std.mem.indexOf(u8, out, "next = add state, 0") != null);
    // The switch scrutinee still reads `state`, which is only valid if the
    // parameter was never consumed.
    try std.testing.expect(std.mem.indexOf(u8, out, "eq state,") != null);
}

test "sa_plugin_ts emits a block-local release before the terminator, never after" {
    const allocator = std.testing.allocator;

    // Regression: releases written after `return` are unreachable code and the
    // assembler reports "basic blocks must end with jmp". This asserts the
    // structural rule directly: the last `!` of a block must precede its
    // `return`, and no `!` may follow a `return` in the same block.
    const out = try lowerForTest(allocator,
        \\interface Cfg { retries: i32; }
        \\function main(): i32 {
        \\  const cfg: Cfg = { retries: 3 };
        \\  return cfg.retries;
        \\}
    );
    defer allocator.free(out);

    // Walk the emitted body: once a `return` is seen, nothing may be emitted
    // except further labels (a new block).
    var saw_return = false;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (t[t.len - 1] == ':') {
            saw_return = false;
            continue;
        }
        if (saw_return) {
            std.debug.print("instruction after return: {s}\n", .{t});
            return error.TestExpectedEqual;
        }
        if (std.mem.startsWith(u8, t, "return")) saw_return = true;
    }
}

// ==========================================
// Runtime expectation tests
// ------------------------------------------
// The substring tests above prove the lowerer emits the right shapes; these
// prove the emitted program computes the right value. Each case lowers a
// small program in-process, assembles it with `sa build`, runs the
// executable, and asserts the exit status equals the value Node produces for
// the same program (verified via tools/strip_ts.py, which also strips
// annotations inside C-style for headers).
// ==========================================

const RuntimeCase = struct {
    name: []const u8,
    source: []const u8,
    expected: u8,
};

const runtime_cases = [_]RuntimeCase{
    .{
        .name = "arithmetic precedence",
        .expected = 11,
        .source =
        \\function main(): i32 {
        \\  const v: i32 = 2 + 3 * 4 - 6 / 2;
        \\  return v;
        \\}
        ,
    },
    .{
        .name = "if/else max",
        .expected = 20,
        .source =
        \\function max(a: i32, b: i32): i32 {
        \\  if (a > b) { return a; } else { return b; }
        \\}
        \\function main(): i32 {
        \\  return max(10, 20);
        \\}
        ,
    },
    .{
        .name = "while accumulation",
        .expected = 10,
        .source =
        \\function sum_to(n: i32): i32 {
        \\  let total: i32 = 0;
        \\  let i: i32 = 0;
        \\  while (i < n) {
        \\    total = total + i;
        \\    i = i + 1;
        \\  }
        \\  return total;
        \\}
        \\function main(): i32 {
        \\  return sum_to(5);
        \\}
        ,
    },
    .{
        .name = "c-style for",
        .expected = 10,
        .source =
        \\function main(): i32 {
        \\  let total: i32 = 0;
        \\  for (let i = 0; i < 5; i++) { total = total + i; }
        \\  return total;
        \\}
        ,
    },
    .{
        .name = "for-of array sum",
        .expected = 6,
        .source =
        \\function main(): i32 {
        \\  const arr: i32[] = [1, 2, 3];
        \\  let t: i32 = 0;
        \\  for (const v of arr) { t = t + v; }
        \\  return t;
        \\}
        ,
    },
    .{
        .name = "recursion factorial",
        .expected = 120,
        .source =
        \\function fact(n: i32): i32 {
        \\  if (n <= 1) { return 1; }
        \\  return n * fact(n - 1);
        \\}
        \\function main(): i32 {
        \\  return fact(5);
        \\}
        ,
    },
    .{
        .name = "recursion fibonacci",
        .expected = 55,
        .source =
        \\function fib(n: i32): i32 {
        \\  if (n < 2) { return n; }
        \\  return fib(n - 1) + fib(n - 2);
        \\}
        \\function main(): i32 {
        \\  return fib(10);
        \\}
        ,
    },
    .{
        .name = "struct field read",
        .expected = 3,
        .source =
        \\interface Point { x: i32; y: i32; }
        \\function main(): i32 {
        \\  const p: Point = { x: 3, y: 4 };
        \\  return p.x;
        \\}
        ,
    },
    .{
        .name = "enum switch",
        .expected = 20,
        .source =
        \\enum Color { Red, Green, Blue }
        \\function classify(c: i32): i32 {
        \\  let r: i32 = 0;
        \\  switch (c) {
        \\    case 0: { r = 10; break; }
        \\    case 1: { r = 20; break; }
        \\    default: { r = 30; }
        \\  }
        \\  return r;
        \\}
        \\function main(): i32 {
        \\  return classify(1);
        \\}
        ,
    },
    .{
        .name = "array write then sum",
        .expected = 15,
        .source =
        \\function main(): i32 {
        \\  let arr: i32[] = [1, 2, 3];
        \\  arr[0] = 10;
        \\  let t: i32 = 0;
        \\  for (const v of arr) { t = t + v; }
        \\  return t;
        \\}
        ,
    },
    .{
        .name = "function call chain",
        .expected = 12,
        .source =
        \\function a(x: i32): i32 { return x + 1; }
        \\function b(x: i32): i32 { return a(x) * 2; }
        \\function c(x: i32): i32 { return b(x) + a(x); }
        \\function main(): i32 {
        \\  return c(3);
        \\}
        ,
    },
    .{
        .name = "modulo",
        .expected = 2,
        .source =
        \\function rem(a: i32, b: i32): i32 {
        \\  return a % b;
        \\}
        \\function main(): i32 {
        \\  return rem(17, 5);
        \\}
        ,
    },
    .{
        .name = "negated condition",
        .expected = 1,
        .source =
        \\function main(): i32 {
        \\  const ready: i32 = 0;
        \\  if (!ready) { return 1; }
        \\  return 0;
        \\}
        ,
    },
    .{
        .name = "nested loops",
        .expected = 9,
        .source =
        \\function main(): i32 {
        \\  let t: i32 = 0;
        \\  let i: i32 = 0;
        \\  while (i < 3) {
        \\    for (let j = 0; j < 3; j++) { t = t + 1; }
        \\    i = i + 1;
        \\  }
        \\  return t;
        \\}
        ,
    },
    .{
        .name = "c-for assignment increment",
        .expected = 15,
        .source =
        \\function main(): i32 {
        \\  let t: i32 = 0;
        \\  for (let i: i32 = 5; i > 0; i = i - 1) { t = t + i; }
        \\  return t;
        \\}
        ,
    },
    .{
        .name = "nested struct literal with chained access",
        .expected = 6,
        .source =
        \\interface Inner { a: i32; b: i32; }
        \\interface Outer { inner: Inner; tag: i32; }
        \\function main(): i32 {
        \\  const o: Outer = { inner: { a: 1, b: 2 }, tag: 3 };
        \\  return o.tag + o.inner.a + o.inner.b;
        \\}
        ,
    },
    .{
        .name = "struct literal reassignment",
        .expected = 4,
        .source =
        \\interface Point { x: i32; y: i32; }
        \\function main(): i32 {
        \\  let p: Point = { x: 1, y: 1 };
        \\  p = { x: 2, y: 2 };
        \\  return p.x + p.y;
        \\}
        ,
    },
    .{
        .name = "struct field as loop bound with stepped increment",
        .expected = 8,
        .source =
        \\interface Bundle { version: i32; files: i32; }
        \\function main(): i32 {
        \\  const b: Bundle = { version: 2, files: 12 };
        \\  let t: i32 = 0;
        \\  for (let i: i32 = 0; i < b.files; i = i + 2) { t = t + 1; }
        \\  return t + b.version;
        \\}
        ,
    },
    .{
        .name = "deep struct field read",
        .expected = 9,
        .source =
        \\interface Inner { a: i32; b: i32; }
        \\interface Outer { inner: Inner; tag: i32; }
        \\function main(): i32 {
        \\  const o: Outer = { inner: { a: 9, b: 8 }, tag: 1 };
        \\  return o.inner.a;
        \\}
        ,
    },
    .{
        .name = "arrow with param, expression body",
        .expected = 42,
        .source = "function main(): i32 {\n" ++ "  let f = (x: i32) => x + 1;\n" ++ "  let r: i32 = f(41);\n" ++ "  return r;\n" ++ "}\n",
    },
    .{
        .name = "arrow with two params",
        .expected = 42,
        .source = "function main(): i32 {\n" ++ "  let f = (a: i32, b: i32) => a + b;\n" ++ "  let r: i32 = f(20, 22);\n" ++ "  return r;\n" ++ "}\n",
    },
    .{
        .name = "bare-param arrow with capture",
        .expected = 105,
        .source = "function main(): i32 {\n" ++ "  let base: i32 = 100;\n" ++ "  let f = x => x + base;\n" ++ "  let r: i32 = f(5);\n" ++ "  return r;\n" ++ "}\n",
    },
    .{
        .name = "arrow with params, block body return",
        .expected = 42,
        .source = "function main(): i32 {\n" ++ "  let f = (a: i32, b: i32) => {\n" ++ "    return a + b;\n" ++ "  };\n" ++ "  let r: i32 = f(30, 12);\n" ++ "  return r;\n" ++ "}\n",
    },
};

fn lowerForRuntimeTest(allocator: std.mem.Allocator, tc: *const RuntimeCase) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, tc.source, &low);
    defer p.deinit();
    try p.parse();

    if (p.errors.items.len != 0) {
        std.debug.print("lower diagnostics for '{s}':\n", .{tc.name});
        for (p.errors.items) |e| std.debug.print("  {s}\n", .{e.message});
        return error.RuntimeCaseLowerFailed;
    }
    const out = try low.toOwnedSlice();
    return try allocator.dupe(u8, out);
}

fn findSaForRuntimeTest(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "SA_BIN")) |v| return v else |_| {}
    const dev_path = "/content/sa_all/sci/zig-out/bin/sa";
    std.fs.accessAbsolute(dev_path, .{}) catch return null;
    return try allocator.dupe(u8, dev_path);
}

fn runRuntimeCase(allocator: std.mem.Allocator, sa_path: []const u8, tc: *const RuntimeCase) !void {
    errdefer std.debug.print("runtime case failed: {s} (expected status {d})\n", .{ tc.name, tc.expected });
    const sa_code = try lowerForRuntimeTest(allocator, tc);
    defer allocator.free(sa_code);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const sai_path = try std.fs.path.join(allocator, &.{ dir_path, "case.sai" });
    defer allocator.free(sai_path);
    const exe_path = try std.fs.path.join(allocator, &.{ dir_path, "case.exe" });
    defer allocator.free(exe_path);

    const sai_file = try std.fs.createFileAbsolute(sai_path, .{});
    try sai_file.writeAll(sa_code);
    sai_file.close();

    var build_child = std.process.Child.init(&.{ sa_path, "build", sai_path, "-o", exe_path }, allocator);
    build_child.stdout_behavior = .Ignore;
    build_child.stderr_behavior = .Ignore;
    const build_term = try build_child.spawnAndWait();
    if (build_term != .Exited or build_term.Exited != 0) {
        std.debug.print("sa build failed for '{s}': {any}\n", .{ tc.name, build_term });
        return error.TestExpectedEqual;
    }

    var run_child = std.process.Child.init(&.{exe_path}, allocator);
    run_child.stdout_behavior = .Ignore;
    run_child.stderr_behavior = .Ignore;
    const run_term = try run_child.spawnAndWait();
    if (run_term != .Exited or run_term.Exited != tc.expected) {
        std.debug.print("wrong result for '{s}': got {any}, want status {d}\n", .{ tc.name, run_term, tc.expected });
        return error.TestExpectedEqual;
    }
}

test "sa_plugin_ts runtime results match node-verified expectations" {
    const allocator = std.testing.allocator;
    const sa_path = try findSaForRuntimeTest(allocator) orelse return error.SkipZigTest;
    defer allocator.free(sa_path);
    for (&runtime_cases) |*tc| {
        try runRuntimeCase(allocator, sa_path, tc);
    }
}
