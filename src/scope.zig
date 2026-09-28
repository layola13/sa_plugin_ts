const std = @import("std");

/// Whether a definition in `def` dominates a release point in `at`.
///
/// Matrix layout: row `b` holds the dominator set of `b` (block `b` plus
/// every block above it on the idom chain), so "def dominates at" reads row
/// `at`, column `def`. When no matrix is supplied, or the snapshot does not
/// cover the blocks, fall back to "the entry block dominates everything, any
/// other block dominates only itself": a register defined in one arm of a
/// branch is not live at the merge point, so treating every block as
/// dominating itself would leak it.
inline fn dominatesWith(
    reaches: ?[]const bool,
    def: u32,
    at: u32,
) bool {
    if (reaches) |m| {
        // The matrix is a square n-by-n snapshot of the CFG at the time it was
        // computed. Emission continues afterwards, so a block can outgrow it;
        // fall back to the conservative rule rather than indexing past the end.
        var w: usize = 1;
        while (w * w < m.len) : (w += 1) {}
        if (w == 0 or w * w != m.len) return def == 0 or def == at;
        if (@as(usize, def) < w and @as(usize, at) < w) return m[@as(usize, at) * w + @as(usize, def)];
        return def == at;
    }
    return def == 0 or def == at;
}

pub const Variable = struct {
    name: []const u8,
    type_name: []const u8,
    reg: []const u8,
    is_heap_allocated: bool,
    is_consumed: bool,
    /// A `!` release has already been emitted for this register.
    ///
    /// Several paths can reach the same release point (e.g. every `case` of a
    /// switch returns), and emitting the release more than once is a
    /// use-after-move error. The release walk is therefore idempotent.
    is_released: bool = false,
    /// Basic block the register was defined in.
    ///
    /// A `!` release is only sound where the definition dominates it. The
    /// entry block (serial 0) dominates everything; any other block dominates
    /// only itself. Releasing a register defined in a sibling branch, at a
    /// merge point, fails with "register is not declared in the current scope".
    def_block: u32 = 0,
};

pub const Scope = struct {
    variables: std.ArrayList(Variable),
    
    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        for (self.variables.items) |v| {
            allocator.free(v.name);
            allocator.free(v.type_name);
            allocator.free(v.reg);
        }
        self.variables.deinit();
    }
};

pub const ScopeManager = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),

    /// When true, `exitScope` no longer emits releases; the parser calls
    /// `releaseAllOwned` at each return site instead.
    defer_releases: bool = false,

    /// Computed dominance matrix for the block currently being emitted, or
    /// null while no analysis is available.
    reaches: ?[]const bool = null,

    pub fn init(allocator: std.mem.Allocator) ScopeManager {
        return .{
            .allocator = allocator,
            .scopes = std.ArrayList(Scope).init(allocator),
        };
    }

    pub fn deinit(self: *ScopeManager) void {
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit();
    }

    pub fn enterScope(self: *ScopeManager) !void {
        const scope = Scope{
            .variables = std.ArrayList(Variable).init(self.allocator),
        };
        try self.scopes.append(scope);
    }

    pub fn exitScope(self: *ScopeManager, lowerer: anytype) !void {
        if (self.scopes.items.len == 0) return;
        var scope_opt = self.scopes.pop();
        if (scope_opt) |*scope| {
            defer scope.deinit(self.allocator);

            // Physical releases are emitted by `releaseAllOwned`, not here.
            //
            // A scope can be left by a `return`, and a release written after
            // that `return` is unreachable code. Deferring all releases to the
            // return site (or to function exit) keeps them on every live path.
            if (!self.defer_releases) {
                var i = scope.variables.items.len;
                while (i > 0) {
                    i -= 1;
                    const v = scope.variables.items[i];
                    if (v.is_heap_allocated and !v.is_consumed) {
                        try lowerer.emit("    !{s}\n", .{v.reg});
                    }
                }
            }
        }
    }

    /// Release every live owned register across all open scopes, innermost
    /// first, so releases are emitted on the path actually taken.
    ///
    /// `except` names a register that must stay live because it is the value
    /// being returned; releasing it would be a use-after-move.
    pub fn releaseAllOwnedExcept(self: *ScopeManager, lowerer: anytype, except: ?[]const u8) !void {
        const current_block = lowerer.currentBlock();
        var s = self.scopes.items.len;
        while (s > 0) {
            s -= 1;
            const scope = &self.scopes.items[s];
            var i = scope.variables.items.len;
            while (i > 0) {
                i -= 1;
                const v = &scope.variables.items[i];
                if (except != null and std.mem.eql(u8, v.reg, except.?)) continue;
                if (v.is_heap_allocated and !v.is_consumed and !v.is_released and dominatesWith(self.reaches, v.def_block, current_block)) {
                    try lowerer.emit("    !{s}\n", .{v.reg});
                    v.is_released = true;
                }
            }
        }
    }

    pub fn releaseAllOwned(self: *ScopeManager, lowerer: anytype) !void {
        return self.releaseAllOwnedExcept(lowerer, null);
    }

    /// Number of currently open scopes.
    pub fn scopeDepth(self: *ScopeManager) usize {
        return self.scopes.items.len;
    }

    /// Release the owned values held by every scope opened after `depth`.
    ///
    /// A `break` or `continue` abandons the scopes it jumps out of: those
    /// scopes are popped as the enclosing blocks close, so the function-exit
    /// walk never sees the values they own and the verifier reports a leak.
    /// Releasing them at the jump is the only point where they are still
    /// visible.
    ///
    /// Scopes at or above `depth` belong to the enclosing function and stay
    /// live, which matters because the jump target is a merge point: freeing
    /// a register on one arm only and not the other is a state conflict.
    pub fn releaseScopesDeeperThan(self: *ScopeManager, lowerer: anytype, depth: usize) !void {
        if (self.scopes.items.len <= depth) return;
        const current_block = lowerer.currentBlock();
        var s = self.scopes.items.len;
        while (s > depth) {
            s -= 1;
            const scope = &self.scopes.items[s];
            var i = scope.variables.items.len;
            while (i > 0) {
                i -= 1;
                const v = &scope.variables.items[i];
                if (v.is_heap_allocated and !v.is_consumed and !v.is_released and dominatesWith(self.reaches, v.def_block, current_block)) {
                    try lowerer.emit("    !{s}\n", .{v.reg});
                    v.is_released = true;
                }
            }
        }
    }

    /// Scoped variant of `releaseAllOwnedExcept`: only scopes opened after
    /// `depth` are considered. Arrow callbacks parse inside their parent's
    /// scopes, so an unscoped walk would release the parent's registers from
    /// inside the callback.
    pub fn releaseScopesDeeperThanExcept(self: *ScopeManager, lowerer: anytype, depth: usize, except: ?[]const u8) !void {
        if (self.scopes.items.len <= depth) return;
        const current_block = lowerer.currentBlock();
        var s = self.scopes.items.len;
        while (s > depth) {
            s -= 1;
            const scope = &self.scopes.items[s];
            var i = scope.variables.items.len;
            while (i > 0) {
                i -= 1;
                const v = &scope.variables.items[i];
                if (except != null and std.mem.eql(u8, v.reg, except.?)) continue;
                if (v.is_heap_allocated and !v.is_consumed and !v.is_released and dominatesWith(self.reaches, v.def_block, current_block)) {
                    try lowerer.emit("    !{s}\n", .{v.reg});
                    v.is_released = true;
                }
            }
        }
    }

    pub fn declareVar(self: *ScopeManager, name: []const u8, type_name: []const u8, reg: []const u8, is_heap: bool) !void {
        if (self.scopes.items.len == 0) return error.NoActiveScope;
        const current = &self.scopes.items[self.scopes.items.len - 1];
        try current.variables.append(.{
            .name = try self.allocator.dupe(u8, name),
            .type_name = try self.allocator.dupe(u8, type_name),
            .reg = try self.allocator.dupe(u8, reg),
            .is_heap_allocated = is_heap,
            .is_consumed = false,
        });
    }

    pub fn lookup(self: *ScopeManager, name: []const u8) ?*Variable {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            for (scope.variables.items) |*v| {
                if (std.mem.eql(u8, v.name, name)) {
                    return v;
                }
            }
        }
        return null;
    }

    /// Whether `name` resolves outside the innermost scope.
    ///
    /// A function's parameters are declared in their own scope, separate from
    /// the body scope, so a name found only in an outer scope is a parameter
    /// rather than a local or a compiler temporary. That distinction decides
    /// whether a `let` binding may move its initialiser: TypeScript copies on
    /// assignment, so `let next: i32 = state` must leave the parameter `state`
    /// readable for a later `switch (state)`, whereas `for (let i = lo; ...)`
    /// initialises from a local and keeps the existing move behaviour that the
    /// loop lowering depends on.
    pub fn isOuterVariable(self: *ScopeManager, name: []const u8) bool {
        if (self.scopes.items.len < 2) return false;
        const body = &self.scopes.items[self.scopes.items.len - 1];
        for (body.variables.items) |v| {
            if (std.mem.eql(u8, v.name, name)) return false;
        }
        return self.lookup(name) != null;
    }

    /// Mark a variable as moved, so no `!` release is emitted for it.
    ///
    /// In SA-ASM a register consumed by an arithmetic or comparison instruction
    /// is moved, and releasing it afterwards is a use-after-move error. A
    /// variable that is only assigned to, or never used, stays live and must
    /// still be released.
    pub fn markConsumed(self: *ScopeManager, name: []const u8) void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            for (scope.variables.items) |*v| {
                if (std.mem.eql(u8, v.name, name)) {
                    v.is_consumed = true;
                    return;
                }
            }
        }
    }

    /// Record the basic block a register was defined in.
    pub fn markDefBlock(self: *ScopeManager, name: []const u8, block: u32) void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            for (scope.variables.items) |*v| {
                if (std.mem.eql(u8, v.name, name)) {
                    v.def_block = block;
                    return;
                }
            }
        }
    }

    /// Release the owned registers declared in the innermost scope only.
    ///
    /// Used at the end of a branch arm (an if arm or switch case): a heap value
    /// created there dies at the end of the arm, and its scope is popped right
    /// after, so a whole-function release walk at the merge point would no
    /// longer see it. Releasing only the current scope leaves outer locals and
    /// parameters for the function's own exit path.
    pub fn releaseCurrentScopeOwned(self: *ScopeManager, lowerer: anytype) !void {
        if (self.scopes.items.len == 0) return;
        const current_block = lowerer.currentBlock();
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        var i = scope.variables.items.len;
        while (i > 0) {
            i -= 1;
            const v = &scope.variables.items[i];
            if (v.is_heap_allocated and !v.is_consumed and !v.is_released and dominatesWith(self.reaches, v.def_block, current_block)) {
                try lowerer.emit("    !{s}\n", .{v.reg});
                v.is_released = true;
            }
        }
    }
};
