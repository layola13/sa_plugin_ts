const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const lowerer = @import("lowerer.zig");

// Standard C-ABI Host Context and Stream structures
pub const Context = extern struct {
    allocator_opaque: ?*anyopaque = null,
    host_version: ?[*:0]const u8 = null,
    log: ?*const anyopaque = null,
    log_ctx: ?*anyopaque = null,
    json_mode: bool = false,
};

pub const HostStream = extern struct {
    ctx: ?*anyopaque,
    write_all: ?*const anyopaque,
};

// C-ABI Compatible Plugin Descriptor Struct
pub const PluginDescriptor = extern struct {
    abi_version: u32,
    descriptor_size: u32,
    name: [*:0]const u8,
    init: ?*const fn (ctx: *const Context) callconv(.c) u32 = null,
    prebuild: ?*const fn (ctx: *const Context, compile_options: ?*anyopaque) callconv(.c) u32 = null,
    postbuild: ?*const fn (ctx: *const Context) callconv(.c) u32 = null,
    handle_command: ?*const fn (ctx: *const Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: HostStream, stderr: HostStream, out_code: *u8) callconv(.c) u32 = null,
    skills_ptr: ?*anyopaque = null,
    skills_len: usize = 0,
};

const descriptor = PluginDescriptor{
    .abi_version = 1,
    .descriptor_size = @sizeOf(PluginDescriptor),
    .name = "sa_plugin_ts",
};

pub export const saasm_plugin_descriptor_v1 = descriptor;
pub export fn saasm_plugin_descriptor_v1_fn(out: *PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}

// Main entry point for TS lowering
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
    
    // Store length at the beginning natively using pointer casting
    @as(*u64, @ptrCast(@alignCast(raw.ptr))).* = sa_code.len;
    @memcpy(raw[@sizeOf(u64)..], sa_code);

    out_sa_ptr.* = raw[@sizeOf(u64)..].ptr;
    out_sa_len_ptr.* = sa_code.len;

    return 0;
}

pub export fn sa_plugin_ts_free_buffer(buf: [*]const u8) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;
    const raw_ptr = @constCast(buf) - @sizeOf(u64);
    
    // Read length natively using pointer casting
    const len = @as(*const u64, @ptrCast(@alignCast(raw_ptr))).*;
    const total_size = len + @sizeOf(u64);
    const slice = raw_ptr[0..total_size];
    allocator.free(slice);
    return 0;
}

// ==========================================
// TEST SUITE: TS-to-SA Compilation Verification
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

    // Verify correct layout and sizing (x: 4 bytes at offset 0, y: 4 bytes at offset 4. Total = 8 bytes)
    try std.testing.expect(std.mem.indexOf(u8, result, "p = alloc 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store p + 0, 10 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store p + 4, 20 as i32") != null);

    // Verify property assignment (p.x = 100) resolves to correct static offset (offset 0)
    try std.testing.expect(std.mem.indexOf(u8, result, "store p + 0, 100 as i32") != null);

    // Verify automatic physical release on function block closure (GC replacement)
    try std.testing.expect(std.mem.indexOf(u8, result, "!p") != null);
}

test "sa_plugin_ts supports scalar types, reassignments, and function mapping" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function add(a: i32, b: i32) {
        \\  let sum = a;
        \\  sum = b;
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    // Verify SA function signature and entry label
    try std.testing.expect(std.mem.indexOf(u8, result, "@add(a: i32, b: i32):") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_ENTRY:") != null);

    // Verify scalar assignment and reassignment
    try std.testing.expect(std.mem.indexOf(u8, result, "sum = a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sum = b") != null);

    // Scalar variables do not trigger '!sum' heap deallocations
    try std.testing.expect(std.mem.indexOf(u8, result, "!sum") == null);
}

test "sa_plugin_ts compiles control flows (if/else and while loops)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function check(x: i32) {
        \\  if (x) {
        \\    let a = 1;
        \\  } else {
        \\    let b = 2;
        \\  }
        \\  while (x) {
        \\    let c = 3;
        \\  }
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    // Verify if-else branching directives and labels
    try std.testing.expect(std.mem.indexOf(u8, result, "EXPAND ELIF x, L_IF_TRUE_1, L_IF_FALSE_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_IF_TRUE_1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_IF_FALSE_1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_IF_END_1:") != null);

    // Verify while loop loop directives and labels
    try std.testing.expect(std.mem.indexOf(u8, result, "L_LOOP_COND_2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "EXPAND WHILE_LET x, L_LOOP_BODY_2, L_LOOP_END_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_LOOP_BODY_2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "L_LOOP_END_2:") != null);
}

test "sa_plugin_ts compiles zero-copy dynamic string slices" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source =
        \\function parseHost(url: string) {
        \\  let host = url.slice(0, 15);
        \\}
    ;

    var low = lowerer.Lowerer.init(arena_allocator);
    defer low.deinit();

    var p = try parser.Parser.init(arena_allocator, source, &low);
    defer p.deinit();

    try p.parse();

    const result = low.output.items;

    // Verify dynamic string slice generation
    try std.testing.expect(std.mem.indexOf(u8, result, "orig_ptr = load url + 0 as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "new_ptr = ptr_add orig_ptr, 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "slice_len = sub 15, 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store slice_1 + 0, new_ptr as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store slice_1 + 8, slice_len as u32") != null);

    // Verify scope-based dynamic release of the string slice struct
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

    // Verify generated callback function header and loads
    try std.testing.expect(std.mem.indexOf(u8, result, "@closure_callback_1(ctx: ptr):") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "user = load ctx + 0 as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "increment = load ctx + 8 as i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "!ctx") != null);

    // Verify parent function scope allocates closure context and captures variables
    try std.testing.expect(std.mem.indexOf(u8, result, "ctx = alloc 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store ctx + 0, user as ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "store ctx + 8, increment as i32") != null);

    // Verify parent function calls setTimeout passing callback label and moved context
    try std.testing.expect(std.mem.indexOf(u8, result, "call @setTimeout(@closure_callback_1, ^ctx, 1000)") != null);
}
