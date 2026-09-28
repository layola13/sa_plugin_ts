const std = @import("std");

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

    /// Control-flow edges of the function being built, by successor NAME.
    ///
    /// `succ_names[from]` is every label `from` can transfer control to: a
    /// `br` lists two, a `jmp` lists one, `return` lists none, and a block
    /// that falls through to the next label lists that label (recorded by
    /// `emitLabel`, which is the only place the next label's name is known).
    /// Names are used instead of serials because a forward target's serial
    /// is unknowable at branch-emit time — resolving it as "next serial"
    /// misroutes every else/merge target into the fallthrough block.
    /// Resolution against `written_serials` happens per
    /// `computeDominators` call, so later calls see more labels and the
    /// result only grows more complete; nothing here is ever speculative.
    succ_names: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{},

    /// Serial of each label actually written to the output, for resolving
    /// `succ_names`. A pending label that is dropped (unreferenced and
    /// empty) never appears here, and neither does a label still sitting in
    /// `pending_label`.
    written_serials: std.StringHashMapUnmanaged(u32) = .{},

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
        for (self.succ_names.items) |*l| l.deinit(self.allocator);
        self.succ_names.deinit(self.allocator);
        self.written_serials.deinit(self.allocator);
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
            // The single choke point where a label becomes a real block: all
            // CFG resolution reads this map, so a dropped label (never
            // flushed) can never misroute an edge.
            try self.written_serials.put(self.allocator, label, self.block_serial);
            self.pending_label = null;
        }
    }

    /// Ensure `succ_names` has a list for `serial`, initializing new slots
    /// (`resize` on an unmanaged list leaves them undefined).
    fn ensureBlock(self: *Lowerer, serial: u32) !void {
        if (self.succ_names.items.len <= serial) {
            const old_len = self.succ_names.items.len;
            try self.succ_names.resize(self.allocator, serial + 1);
            for (self.succ_names.items[old_len..]) |*l| l.* = .{};
        }
    }

    /// Grow `succ_names` for the next serial, initializing the new slot.
    fn growBlock(self: *Lowerer) !void {
        const old_len = self.succ_names.items.len;
        try self.succ_names.resize(self.allocator, self.block_serial + 1);
        for (self.succ_names.items[old_len..]) |*l| l.* = .{};
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
        try self.emitTerm("    br {s} -> {s}, {s}\n", .{ cond, true_label, false_label });
        try self.ensureBlock(self.block_serial);
        try self.succ_names.items[self.block_serial].append(self.allocator, true_label);
        try self.succ_names.items[self.block_serial].append(self.allocator, false_label);
    }

    /// Emit an unconditional jump and record the CFG edge.
    pub fn emitJumpTo(self: *Lowerer, label: []const u8) !void {
        try self.useLabel(label);
        try self.emitTerm("    jmp {s}\n", .{label});
        try self.ensureBlock(self.block_serial);
        try self.succ_names.items[self.block_serial].append(self.allocator, label);
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
                    try self.ensureBlock(self.block_serial);
                    try self.succ_names.items[self.block_serial].append(self.allocator, name);
                }
            }
        }
        // The block being closed falls through to `name` unless it already
        // ends in a terminator. This is the only place the next label's name
        // is known, so it is the only place the fallthrough edge can be
        // recorded — by name, like every other edge.
        if (!self.block_terminated) {
            try self.ensureBlock(self.block_serial);
            try self.succ_names.items[self.block_serial].append(self.allocator, name);
        }
        self.block_serial +%= 1;
        try self.growBlock();
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

    /// Immediate dominators for the current function, indexed by block serial.
    ///
    /// Entry is its own dominator. A block unreachable from entry keeps
    /// `maxInt(u32)`, which `dominates` treats as dominating nothing, so a
    /// release is never emitted into dead code. A register may only be released
    /// where its definition dominates the release point.
    ///
    /// Name resolution happens here, per call: a forward target skipped as
    /// "not yet written" today resolves once its label is emitted, so each
    /// call sees a strictly more complete CFG. This function mutates no
    /// persistent state and is safe to call before every release walk.
    pub fn computeDominators(self: *Lowerer) ![]bool {
        const n: usize = @max(self.succ_names.items.len, self.block_serial + 1);
        if (n == 0) return self.allocator.alloc(bool, 0);

        // Resolve successor names to serials; skip labels not yet written.
        var succs = try self.allocator.alloc(std.ArrayListUnmanaged(u32), n);
        defer {
            for (succs) |*l| l.deinit(self.allocator);
            self.allocator.free(succs);
        }
        for (succs) |*l| l.* = .{};
        for (self.succ_names.items, 0..) |*names, from| {
            if (from >= n) break;
            for (names.items) |tgt| {
                // The current block's own label is still sitting in
                // pending_label (flushed by the next emit, after this walk),
                // so it resolves to block_serial explicitly — otherwise the
                // block being released into looks unreachable and every
                // release is vetoed.
                if (self.pending_label) |pl| {
                    if (std.mem.eql(u8, tgt, pl)) {
                        if (self.block_serial < n) succs[from].append(self.allocator, self.block_serial) catch {};
                        continue;
                    }
                }
                if (self.written_serials.get(tgt)) |to| {
                    if (to < n) succs[from].append(self.allocator, to) catch {};
                }
            }
        }

        // Predecessor lists. idom[b] is the common dominator of dom[p] over
        // all predecessors p of b.
        var preds = try self.allocator.alloc(std.ArrayListUnmanaged(u32), n);
        defer {
            for (preds) |*l| l.deinit(self.allocator);
            self.allocator.free(preds);
        }
        for (preds) |*l| l.* = .{};
        for (succs, 0..) |*list, from| {
            for (list.items) |to| {
                preds[to].append(self.allocator, @intCast(from)) catch {};
            }
        }

        // Classic bitset dataflow: Dom(entry) = {entry},
        // Dom(b) = {b} ∪ (∩ Dom[p] over all predecessors p), iterated to a
        // fixpoint. No processing order or finger-walk subtleties: the sets
        // only shrink, so iteration converges, and an idom-free formulation
        // cannot mis-snap a loop head to entry the way the previous
        // immediate-dominator loop did (it seeded from idom values instead
        // of predecessor blocks, permanently dropping real dominators).
        const words: usize = (n + 63) / 64;
        var dom = try self.allocator.alloc(u64, n * words);
        defer self.allocator.free(dom);
        for (0..n) |b| {
            for (0..words) |w| dom[b * words + w] = std.math.maxInt(u64);
        }
        for (0..words) |w| dom[0 * words + w] = 0;
        dom[0] |= @as(u64, 1);

        var tmp = try self.allocator.alloc(u64, words);
        defer self.allocator.free(tmp);

        var changed = true;
        while (changed) {
            changed = false;
            var b: usize = 1;
            while (b < n) : (b += 1) {
                if (preds[b].items.len == 0) {
                    // Unreachable: dominates nothing but itself.
                    for (0..words) |w| {
                        const want: u64 = if (b / 64 == w) @as(u64, 1) << @intCast(b % 64) else 0;
                        if (dom[b * words + w] != want) {
                            dom[b * words + w] = want;
                            changed = true;
                        }
                    }
                    continue;
                }
                for (0..words) |w| tmp[w] = std.math.maxInt(u64);
                for (preds[b].items) |p| {
                    for (0..words) |w| tmp[w] &= dom[@as(usize, p) * words + w];
                }
                tmp[b / 64] |= @as(u64, 1) << @intCast(b % 64);
                for (0..words) |w| {
                    if (dom[b * words + w] != tmp[w]) {
                        dom[b * words + w] = tmp[w];
                        changed = true;
                    }
                }
            }
        }

        // Dom sets -> dominance relation the release walk can query: row `at`
        // holds every block dominating `at`.
        const reaches = try self.allocator.alloc(bool, n * n);
        @memset(reaches, false);
        for (0..n) |at| {
            for (0..n) |def| {
                if (dom[at * words + def / 64] & (@as(u64, 1) << @intCast(def % 64)) != 0) {
                    reaches[at * n + def] = true;
                }
            }
        }
        return reaches;
    }

    /// Reset per-function block state.
    pub fn beginFunction(self: *Lowerer) void {
        for (self.succ_names.items) |*l| l.clearRetainingCapacity();
        self.succ_names.clearRetainingCapacity();
        self.written_serials.clearRetainingCapacity();
        self.block_serial = 0;
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
