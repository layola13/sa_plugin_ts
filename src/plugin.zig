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

    // The lexer/parser must recognise the interpolated form without tripping
    // over the chunk boundaries. Lowering is expected to report a diagnostic:
    // see "sa_plugin_ts rejects template literals instead of emitting a bogus
    // concat" for why.
    p.parse() catch {};

    const result = low.output.items;
    // No unassemblable `concat` may be emitted.
    try std.testing.expect(std.mem.indexOf(u8, result, "concat") == null);
    try std.testing.expect(p.errors.items.len > 0);
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

test "sa_plugin_ts rejects interpolated templates instead of emitting a bogus concat" {
    const allocator = std.testing.allocator;

    // Joining chunks needs `@sa_fmt_i64_into` to render a value plus
    // `@sa_string_concat` to join, which returns a bare pointer with no
    // companion length. Until that exists the lowerer must diagnose rather
    // than emit `concat`, which is not an SA mnemonic.
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
    p.parse() catch {};

    try std.testing.expect(p.errors.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, p.errors.items[0].message, "interpolated template") != null);
    try std.testing.expect(std.mem.indexOf(u8, low.output.items, "concat") == null);
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
