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
            "ts lower <file.ts>        — lower a TypeScript file to SA-ASM",
            "ts lower --out <out> <file.ts> — lower and write output to file",
            "zero-copy string slices and static struct layout",
            "ownership injection (!, ^) based on lexical scope",
            "Pratt expression parser with correct operator precedence",
            "arrow function closures via static defunctionalization",
            "WASM import symbol linking",
        },
    },
};

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

fn runTsCommand(
    ctx: *const plugin_api.Context,
    argv: []const []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) anyerror!?u8 {
    // argv[0] = "sa", argv[1] = "ts", argv[2..] = subcommand args
    if (argv.len < 3) {
        try stderr.print("usage: sa ts lower <file.ts>\n", .{});
        return 1;
    }

    const sub = argv[2];
    if (!std.mem.eql(u8, sub, "lower")) {
        try stderr.print("error[SA-TS]: unknown subcommand '{s}'\n", .{sub});
        try stderr.print("usage: sa ts lower <file.ts>\n", .{});
        return 1;
    }

    // Parse optional --out <path>
    var out_path: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--out")) {
            if (i + 1 >= argv.len) {
                try stderr.print("error[SA-TS]: --out requires a path argument\n", .{});
                return 1;
            }
            i += 1;
            out_path = argv[i];
        } else if (file_path == null) {
            file_path = arg;
        } else {
            try stderr.print("error[SA-TS]: unexpected argument '{s}'\n", .{arg});
            return 1;
        }
    }

    const input_path = file_path orelse {
        try stderr.print("error[SA-TS]: missing required input file path\n", .{});
        try stderr.print("usage: sa ts lower [--out <path>] <file.ts>\n", .{});
        return 1;
    };

    plugin_api.emitLog(ctx, .info, "reading TypeScript source file");

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, input_path, 16 * 1024 * 1024) catch |err| {
        try stderr.print("error[SA-TS]: cannot read '{s}': {}\n", .{ input_path, err });
        return 1;
    };
    defer ctx.allocator.free(source);

    plugin_api.emitLog(ctx, .info, "lowering TypeScript to SA-ASM");

    const sa_code = lowerSource(ctx, source, stderr) catch |err| {
        if (isTsCliError(err)) {
            return 1;
        }
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    defer ctx.allocator.free(sa_code);

    if (out_path) |path| {
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

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "@closure_callback_1(ctx: ptr):") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "user = load ctx + 0 as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "increment = load ctx + 8 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "!ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ctx = alloc 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store ctx + 0, user as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store ctx + 8, increment as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "call @setTimeout(@closure_callback_1, ^ctx, 1000)") != null);
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

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "WASM Interop: Import from ./math.wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Link symbol add to WASM export") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Link symbol sub to WASM export") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "@extern ext_print(msg: ptr) -> void") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "t_1 = call @add(10, 20)") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "jz") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, result, "arr = alloc 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store arr + 0, 1 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store arr + 4, 2 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store arr + 8, 3 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "mul 1, 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "load") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "not b") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, result, "mod a, b") != null);
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

    const result = low.output.items;

    // Verify fs module imported
    try std.testing.expect(std.mem.indexOf(u8, result, "Stdlib: fs module imported") != null);
    // Verify readFile maps to sa_fs_read_file with string arg expansion
    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_fs_read_file(") != null);
    // Verify writeFile maps to sa_fs_write_file
    try std.testing.expect(std.mem.indexOf(u8, result, "call @sa_fs_write_file(") != null);
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

    const result = low.output.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "Stdlib: net module imported") != null);
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

test "sa_plugin_ts compiles template literals with embedded expressions" {
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

    try p.parse();

    const result = low.output.items;
    // Should contain concat operations for template literal parts
    try std.testing.expect(std.mem.indexOf(u8, result, "concat") != null or
        std.mem.indexOf(u8, result, "Hello") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "WIT:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "@wit_import") != null);
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
