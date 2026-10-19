const std = @import("std");
const plugin_api = @import("plugin_api");

pub fn cArgvToSlice(argv: [*]const [*:0]const u8, argv_len: usize, allocator: std.mem.Allocator) ![]const []const u8 {
    const slice = argv[0..argv_len];
    var out = try allocator.alloc([]const u8, slice.len);
    errdefer allocator.free(out);
    for (slice, 0..) |arg, idx| {
        out[idx] = std.mem.span(arg);
    }
    return out;
}

pub const HostWriter = struct {
    writer: std.Io.Writer,
    stream: plugin_api.HostStream,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *HostWriter = @fieldParentPtr("writer", w);
        const write_all = self.stream.write_all orelse return error.WriteFailed;
        const ok = @intFromEnum(plugin_api.AbiStatus.ok);
        if (w.end > 0) {
            if (write_all(self.stream.ctx, w.buffer.ptr, w.end) != ok) return error.WriteFailed;
            w.end = 0;
        }
        for (data[0 .. data.len - 1]) |slice| {
            if (write_all(self.stream.ctx, slice.ptr, slice.len) != ok) return error.WriteFailed;
        }
        const last = data[data.len - 1];
        var r: usize = 0;
        while (r < splat) : (r += 1) {
            if (write_all(self.stream.ctx, last.ptr, last.len) != ok) return error.WriteFailed;
        }
        return std.Io.Writer.countSplat(data, splat);
    }

    fn init(stream: plugin_api.HostStream) HostWriter {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
            .stream = stream,
        };
    }
};

pub fn makeHostWriter(stream: plugin_api.HostStream, storage: *HostWriter) ?*std.Io.Writer {
    if (stream.write_all == null or stream.ctx == null) return null;
    storage.* = HostWriter.init(stream);
    return &storage.writer;
}
