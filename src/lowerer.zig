const std = @import("std");

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Lowerer {
        return .{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.output.deinit();
    }

    pub fn emit(self: *Lowerer, comptime fmt: []const u8, args: anytype) !void {
        try self.output.writer().print(fmt, args);
    }

    pub fn toOwnedSlice(self: *Lowerer) ![]u8 {
        return self.output.toOwnedSlice();
    }
};
