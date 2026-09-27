const std = @import("std");

/// Intersect the dominator sets of two predecessors while the sets are still
/// represented by their current dominator tree walk.
///
/// The classic iterative immediate-dominator algorithm walks each candidate up
/// its own idom chain to a common ancestor, which needs no explicit sets.
fn intersectDominators(
    allocator: std.mem.Allocator,
    dom: []const u32,
    a: u32,
    b: u32,
) !u32 {
    const unsnapped = std.math.maxInt(u32);
    var finger1 = a;
    var finger2 = b;
    while (finger1 != finger2) {
        while (finger1 != dom[finger1]) {
            finger1 = dom[finger1];
            if (finger1 == unsnapped) return unsnapped;
        }
        while (finger2 != dom[finger2]) {
            finger2 = dom[finger2];
            if (finger2 == unsnapped) return unsnapped;
        }
        if (finger1 == unsnapped) return unsnapped;
        if (finger2 == unsnapped) return unsnapped;
        // Advance the deeper finger one level toward the root.
        if (dom[finger1] < dom[finger2]) {
            finger2 = dom[finger2];
        } else {
            finger1 = dom[finger1];
        }
    }
    _ = allocator;
    return finger1;
}

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),

    /// File-scope declarations (SA `@const` data constants).
    ///
    /// SA-ASM requires these at module scope, but they are discovered while
    /// walking function bodies, so they are buffered here and prepended to the
    /// output by `toOwnedSlice`.
    header: std.ArrayList(u8),

    /// Already-emitted `@import` paths, so imports are deduplicated.
    imports: std.ArrayList([]const u8),

    /// When non-null, `emit` redirects into this buffer instead of `output`.
    ///
    /// Used to parse an expression fragment (e.g. the increment clause of a
    /// C-style `for`) into a deferred buffer, so it can be re-emitted later in
    /// the instruction stream without disturbing parse order. SA-ASM requires
    /// basic blocks to be emitted in execution order, so the `for` increment
    /// must physically follow the loop body, not the loop header.
    capture: ?*std.ArrayList(u8) = null,

    /// Label not yet written out. Deferred so a label whose block would end up
    /// empty can be dropped or given a body, which SA-ASM requires: every basic
    /// block must end with a terminator, and a block with no instructions has
    /// none.
    pending_label: ?[]const u8 = null,

    /// True when no instruction has been emitted since `pending_label` was set.
    block_empty: bool = true,

    /// True when the current block already ends in a terminator
    /// (`jmp`/`br`/`return`/`throw`), so emitting another instruction would
    /// produce unreachable code.
    block_terminated: bool = false,

    /// Branch-target reference counts, so unreferenced labels are never emitted.
    label_refs: std.StringHashMapUnmanaged(u32) = .{},

    /// Identifies the current basic block. Reset to 0 by `beginFunction`, so
    /// serial 0 is always the entry block, which dominates every other block.
    block_serial: u32 = 0,

    /// Control-flow edges of the block being built.
    ///
    /// `edges[from]` is the set of blocks `from` can transfer control to. Every
    /// block must list *all* of its successors: a `br` lists two, a `jmp` and
    /// `return` list none, and a block that simply falls through to the next
    /// label lists the following block. The set is what a dominator analysis
    /// needs to decide where a register is live, which a release depends on.
    edges: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .{},

    /// Successors of the block currently being emitted. Each entry is the index
    /// of a not-yet-written label, which resolves to serial `index + 1`.
    pending_edges: std.ArrayListUnmanaged(u32) = .{},

    /// Number of labels written so far; the next label gets serial this + 1.
    labels_written: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Lowerer {
        return .{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
            .header = std.ArrayList(u8).init(allocator),
            .imports = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.output.deinit();
        self.header.deinit();
        self.imports.deinit();
        self.label_refs.deinit(self.allocator);
    }

    /// Declare a file-scope UTF-8 data constant.
    pub fn emitConst(self: *Lowerer, name: []const u8, text: []const u8) !void {
        try self.header.writer().print("@const {s} = utf8:\"", .{name});
        for (text) |ch| {
            switch (ch) {
                '"' => try self.header.appendSlice("\\\""),
                '\\' => try self.header.appendSlice("\\\\"),
                '\n' => try self.header.appendSlice("\\n"),
                '\t' => try self.header.appendSlice("\\t"),
                '\r' => try self.header.appendSlice("\\r"),
                else => try self.header.append(ch),
            }
        }
        // Trailing NUL so the constant also works as a C string.
        try self.header.appendSlice("\\0\"\n");
    }

    /// Emit a file-scope `@import`, deduplicated.
    ///
    /// A `call` to a runtime primitive fails with "callee is not declared"
    /// unless the module that declares it is imported.
    pub fn emitImport(self: *Lowerer, path: []const u8) !void {
        for (self.imports.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }
        try self.imports.append(path);
        try self.header.writer().print("@import \"{s}\"\n", .{path});
    }

    /// Record that `name` is the target of a branch, so it must be emitted.
    pub fn useLabel(self: *Lowerer, name: []const u8) !void {
        const gop = try self.label_refs.getOrPut(self.allocator, name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    /// Mark `name` as needing emission before any branch to it is seen.
    ///
    /// Loop heads and merge points are referenced by jumps emitted *later* in
    /// the stream. Labels are written out lazily, so without reserving them up
    /// front the label would look unreferenced at write time and be dropped.
    pub fn reserveLabel(self: *Lowerer, name: []const u8) !void {
        const gop = try self.label_refs.getOrPut(self.allocator, name);
        if (!gop.found_existing) gop.value_ptr.* = 1;
    }

    fn labelUsed(self: *Lowerer, name: []const u8) bool {
        return (self.label_refs.get(name) orelse 0) > 0;
    }

    fn flushPending(self: *Lowerer) !void {
        if (self.pending_label) |label| {
            // Emit unconditionally: this is only reached when real
            // instructions are about to follow (or a new label supersedes
            // this one), and those instructions need a block to live in.
            // A label that ends a function with nothing after it is dropped by
            // `finishFunction` instead, which checks before flushing.
            try self.output.writer().print("{s}:\n", .{label});
            self.pending_label = null;
        }
    }

    /// Emit an ordinary (non-terminating) instruction.
    pub fn emit(self: *Lowerer, comptime fmt: []const u8, args: anytype) !void {
        if (self.capture) |buf| {
            try buf.writer().print(fmt, args);
            return;
        }
        try self.flushPending();
        try self.output.writer().print(fmt, args);
        self.block_empty = false;
        self.block_terminated = false;
    }

    /// Emit an instruction that terminates the current basic block.
    pub fn emitTerm(self: *Lowerer, comptime fmt: []const u8, args: anytype) !void {
        try self.emit(fmt, args);
        self.block_terminated = true;
    }

    /// Emit a two-way conditional branch and record both CFG edges.
    pub fn emitBranchTo(self: *Lowerer, cond: []const u8, true_label: []const u8, false_label: []const u8) !void {
        try self.useLabel(true_label);
        try self.useLabel(false_label);
        // Both targets are labels that will be emitted in order, so the block
        // they land in is one past the current serial. Resolve them precisely
        // against the recorded label serials when the label is written.
        try self.emitTerm("    br {s} -> {s}, {s}\n", .{ cond, true_label, false_label });
        try self.pending_edges.append(self.allocator, self.labels_written);
    }

    /// Emit an unconditional jump and record the CFG edge.
    pub fn emitJumpTo(self: *Lowerer, label: []const u8) !void {
        try self.useLabel(label);
        try self.emitTerm("    jmp {s}\n", .{label});
        try self.pending_edges.append(self.allocator, self.labels_written);
    }

    /// Begin a new basic block at `name`.
    ///
    /// If a label is already pending, its block is closed first. When that
    /// pending block has no instructions but is still branched to, an explicit
    /// jump to `name` is emitted so the block is well-formed.
    pub fn emitLabel(self: *Lowerer, name: []const u8) !void {
        if (self.capture) |buf| {
            try buf.writer().print("{s}:\n", .{name});
            return;
        }
        if (self.pending_label) |prev| {
            if (self.labelUsed(prev)) {
                try self.flushPending();
                if (self.block_empty) {
                    try self.output.writer().print("    jmp {s}\n", .{name});
                }
            }
        }
        try self.closeBlock();
        self.block_serial +%= 1;
        self.labels_written +%= 1;
        try self.edges.resize(self.allocator, self.block_serial + 1);
        self.pending_label = name;
        self.block_empty = true;
        self.block_terminated = false;
    }

    /// True when the current block already ends in a terminator, so a
    /// follow-up jump would be dead code.
    pub fn isTerminated(self: *Lowerer) bool {
        return self.block_terminated;
    }

    /// Close the function being emitted, guaranteeing a well-formed final block.
    ///
    /// `default_ret` is emitted when control can reach the end without a
    /// terminator, so every block satisfies the assembler's requirement.
    pub fn finishFunction(self: *Lowerer, default_ret: []const u8) !void {
        if (self.pending_label) |label| {
            if (!self.labelUsed(label)) {
                // Unreferenced and empty: drop it rather than emit a block with
                // no terminator.
                self.pending_label = null;
                return;
            }
            try self.flushPending();
        }
        if (!self.block_terminated) {
            try self.emitTerm("    {s}\n", .{default_ret});
        }
    }

    /// The current basic block's serial.
    pub fn currentBlock(self: *const Lowerer) u32 {
        return self.block_serial;
    }

    /// Record that control can flow from the current block to `target`.
    pub fn addEdge(self: *Lowerer, target: u32) !void {
        try self.pending_edges.append(self.allocator, target);
    }

    /// Close the current block, recording its outgoing edges.
    ///
    /// A branch to a label that has not been written yet is recorded as an index
    /// into `branch_targets`. Since `emitLabel` assigns serial `index + 1`,
    /// those resolve without waiting for the label.
    fn closeBlock(self: *Lowerer) !void {
        if (self.edges.items.len <= self.block_serial) {
            try self.edges.resize(self.allocator, self.block_serial + 1);
        }

        var succ = std.ArrayListUnmanaged(u32){};
        for (self.pending_edges.items) |e| {
            succ.append(self.allocator, @intCast(e + 1)) catch {};
        }
        self.pending_edges = .{};

        // A block with no explicit terminator falls through to the next one.
        if (!self.block_terminated and self.block_serial + 1 < self.edges.items.len) {
            succ.append(self.allocator, self.block_serial + 1) catch {};
        }
        self.edges.items[self.block_serial] = succ;
    }

    /// Immediate dominators for the current function, indexed by block serial.
    ///
    /// Entry is its own dominator. A block unreachable from entry keeps
    /// `maxInt(u32)`, which `dominates` treats as dominating nothing, so a
    /// release is never emitted into dead code. A register may only be released
    /// where its definition dominates the release point; treating every block as
    /// dominating itself is what previously leaked values created in a branch arm.
    pub fn computeDominators(self: *Lowerer) ![]bool {
        try self.closeBlock();
        const n: u32 = @intCast(self.edges.items.len);
        const unsnapped = std.math.maxInt(u32);
        if (n == 0) return self.allocator.alloc(bool, 0);

        const dom = try self.allocator.alloc(u32, n);
        for (dom, 0..) |*d, i| d.* = if (i == 0) 0 else unsnapped;

        var changed = true;
        while (changed) {
            changed = false;
            var b: u32 = 1;
            while (b < n) : (b += 1) {
                if (self.edges.items[b].items.len == 0) continue;
                var new_idom: u32 = unsnapped;
                for (self.edges.items[b].items) |succ| {
                    if (succ >= n) continue;
                    if (dom[succ] == unsnapped) continue;
                    if (new_idom == unsnapped) {
                        new_idom = dom[succ];
                    } else {
                        new_idom = try intersectDominators(self.allocator, dom, new_idom, dom[succ]);
                    }
                }
                if (new_idom != unsnapped and new_idom != dom[b]) {
                    dom[b] = new_idom;
                    changed = true;
                }
            }
        }

        // idom array -> dominance relation the release walk can query.
        const reaches = try self.allocator.alloc(bool, n * n);
        @memset(reaches, false);
        for (0..n) |i| {
            var cur: u32 = @intCast(i);
            while (true) {
                reaches[i * n + cur] = true;
                if (cur == 0 or dom[cur] == unsnapped) break;
                cur = dom[cur];
            }
        }
        return reaches;
    }

    /// Reset per-function block state.
    pub fn beginFunction(self: *Lowerer) void {
        self.edges.clearRetainingCapacity();
        self.pending_edges.clearRetainingCapacity();
        self.block_serial = 0;
        self.labels_written = 0;
        self.pending_label = null;
        self.block_empty = true;
        self.block_terminated = false;
        // Label reference counts are only meaningful within one function, and
        // leaving them to accumulate would grow the map for the life of the
        // process. Label names come from a monotonic counter, so clearing here
        // cannot orphan a forward reference.
        self.label_refs.clearRetainingCapacity();
    }

    /// Append already-rendered text to the main output at the current point.
    /// Used to splice a captured fragment back into the stream.
    pub fn emitRaw(self: *Lowerer, text: []const u8) !void {
        if (self.capture) |buf| {
            try buf.appendSlice(text);
            return;
        }
        try self.flushPending();
        try self.output.appendSlice(text);
        if (text.len > 0) {
            self.block_empty = false;
            self.block_terminated = false;
        }
    }

    pub fn toOwnedSlice(self: *Lowerer) ![]u8 {
        if (self.header.items.len == 0) return self.output.toOwnedSlice();
        var out = try self.allocator.alloc(u8, self.header.items.len + self.output.items.len);
        @memcpy(out[0..self.header.items.len], self.header.items);
        @memcpy(out[self.header.items.len..], self.output.items);
        return out;
    }
};
