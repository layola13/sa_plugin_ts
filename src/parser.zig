const std = @import("std");
const lexer_mod = @import("lexer.zig");
const scope_mod = @import("scope.zig");
const lowerer_mod = @import("lowerer.zig");

pub const Field = struct {
    name: []const u8,
    offset: u32,
    type_name: []const u8,
};

/// A pending `break`/`continue` destination.
///
/// The scope depth is recorded with the label because a jump abandons every
/// scope opened after the enclosing construct, and those scopes pop before any
/// later release pass can observe them. Keeping the depth here is what lets
/// `break` release exactly the abandoned scopes and leave the enclosing ones
/// live for the function-exit walk.
const JumpTarget = struct {
    label: []const u8,
    scope_depth: usize,
};

pub const StructLayout = struct {
    name: []const u8,
    size: u32,
    fields: std.ArrayList(Field),

    pub fn deinit(self: *StructLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.fields.items) |f| {
            allocator.free(f.name);
            allocator.free(f.type_name);
        }
        self.fields.deinit();
    }
};

pub const LayoutTable = struct {
    allocator: std.mem.Allocator,
    layouts: std.ArrayList(StructLayout),

    pub fn init(allocator: std.mem.Allocator) LayoutTable {
        return .{
            .allocator = allocator,
            .layouts = std.ArrayList(StructLayout).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutTable) void {
        for (self.layouts.items) |*layout| {
            layout.deinit(self.allocator);
        }
        self.layouts.deinit();
    }

    pub fn register(self: *LayoutTable, name: []const u8, layout: StructLayout) !void {
        _ = name;
        try self.layouts.append(layout);
    }

    pub fn find(self: *LayoutTable, name: []const u8) ?*StructLayout {
        for (self.layouts.items) |*layout| {
            if (std.mem.eql(u8, layout.name, name)) {
                return layout;
            }
        }
        return null;
    }
};

pub const EnumDef = struct {
    name: []const u8,
    variants: std.ArrayList([]const u8),

    pub fn deinit(self: *EnumDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.variants.items) |v| {
            allocator.free(v);
        }
        self.variants.deinit();
    }
};

pub const ParseError = struct {
    line: u32,
    col: u32,
    message: []const u8,
};

pub const Parser = struct {
    lexer: lexer_mod.Lexer,
    allocator: std.mem.Allocator,
    layout_table: LayoutTable,
    scope_manager: scope_mod.ScopeManager,
    lowerer: *lowerer_mod.Lowerer,
    current: lexer_mod.Token,
    peek: lexer_mod.Token,
    label_counter: u32 = 0,
    /// Nesting depth of loop bodies currently being parsed.
    ///
    /// A register bound inside a loop is re-assigned each iteration, so it must
    /// not be released inside the loop.
    loop_depth: u32 = 0,

    /// Cached CFG dominance matrix, refreshed at each branch boundary.
    dominators: ?[]bool = null,

    /// Nesting depth of conditional branch bodies (if arms, switch cases) whose
    /// arms reconverge at a merge point.
    ///
    /// A register-to-register assignment inside such a body would leave its
    /// source Consumed on one arm and Active on the other, which the verifier
    /// rejects as a state conflict at the join.
    branch_depth: u32 = 0,

    /// Loop/switch context stack used to lower `break` and `continue`.
    ///
    /// SA-ASM has no `break`/`continue` instructions: both are unconditional
    /// jumps, so the enclosing construct's label must be known at the point
    /// the statement is emitted.
    break_stack: std.ArrayList(JumpTarget) = undefined,
    continue_stack: std.ArrayList(JumpTarget) = undefined,

    /// Parameters of each enclosing function, so `return` can release them.
    ///
    /// SA-ASM requires every live register to be released before a function
    /// exits, and parameters are live registers. Releases must precede the
    /// `return` on each path, otherwise they become unreachable code.
    func_param_stack: std.ArrayList([][]const u8) = undefined,
    last_arrow_ctx: ?[]const u8 = null,
    errors: std.ArrayList(ParseError),
    has_fatal_error: bool = false,
    template_lexer_mode: bool = false,
    enums: std.ArrayList(EnumDef),
    stdlib: std.ArrayList(StdlibEntry),

    pub const StdlibEntry = struct {
        name: []const u8,
        sa_primitive: []const u8,
        string_args: []const u8, // "1" = first arg is string, "12" = first two are strings, etc.
        /// Extra trailing arguments the SA primitive requires, appended after
        /// the caller's own arguments. SA-ASM callees have fixed arity, so
        /// omitting these makes the call fail.
        extra_args: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8, low: *lowerer_mod.Lowerer) !Parser {
        var l = lexer_mod.Lexer{ .source = source };
        const current = l.next();
        const peek = l.next();

        var parser_inst = Parser{
            .lexer = l,
            .allocator = allocator,
            .layout_table = LayoutTable.init(allocator),
            .scope_manager = scope_mod.ScopeManager.init(allocator),
            .lowerer = low,
            .current = current,
            .peek = peek,
            .label_counter = 0,
            .break_stack = std.ArrayList(JumpTarget).init(allocator),
            .continue_stack = std.ArrayList(JumpTarget).init(allocator),
            .func_param_stack = std.ArrayList([][]const u8).init(allocator),
            .enums = std.ArrayList(EnumDef).init(allocator),
            .stdlib = std.ArrayList(StdlibEntry).init(allocator),
            .errors = std.ArrayList(ParseError).init(allocator),
        };

        // Pre-register built-in 'string' interface
        var string_fields = std.ArrayList(Field).init(allocator);
        try string_fields.append(.{ .name = try allocator.dupe(u8, "ptr"), .offset = 0, .type_name = try allocator.dupe(u8, "ptr") });
        try string_fields.append(.{ .name = try allocator.dupe(u8, "len"), .offset = 8, .type_name = try allocator.dupe(u8, "u32") });
        const string_layout = StructLayout{
            .name = try allocator.dupe(u8, "string"),
            .size = 16,
            .fields = string_fields,
        };
        try parser_inst.layout_table.register("string", string_layout);

        return parser_inst;
    }

    pub fn deinit(self: *Parser) void {
        self.layout_table.deinit();
        self.scope_manager.deinit();
        self.errors.deinit();
        self.stdlib.deinit();
        if (self.dominators) |d| self.allocator.free(d);
        self.break_stack.deinit();
        self.continue_stack.deinit();
        self.func_param_stack.deinit();
        for (self.enums.items) |*e| {
            e.deinit(self.allocator);
        }
        self.enums.deinit();
    }

    fn advance(self: *Parser) anyerror!void {
        self.current = self.peek;
        if (self.template_lexer_mode) {
            self.peek = self.lexer.nextTemplateChunk();
            // If we got template_end, exit template mode
            if (self.peek.tag == .template_end) {
                // After consuming template_end, switch back to normal mode
                // We stay in template mode until template_end is consumed
            }
        } else {
            self.peek = self.lexer.next();
        }
    }

    fn expect(self: *Parser, tag: lexer_mod.Token.Tag) anyerror!void {
        if (self.current.tag != tag) {
            const msg = try std.fmt.allocPrint(self.allocator, "expected {s}, got {s}", .{ @tagName(tag), @tagName(self.current.tag) });
            try self.errors.append(.{ .line = self.current.line, .col = self.current.col, .message = msg });
            // Skip to synchronization point
            self.skipToSync();
            return error.UnexpectedToken;
        }
        try self.advance();
    }

    fn skipToSync(self: *Parser) void {
        while (self.current.tag != .eof) {
            switch (self.current.tag) {
                .semicolon, .r_brace, .keyword_function, .keyword_let, .keyword_const, .keyword_if, .keyword_while, .keyword_for, .keyword_return => return,
                else => {
                    self.current = self.peek;
                    self.peek = self.lexer.next();
                },
            }
        }
    }

    fn accept(self: *Parser, tag: lexer_mod.Token.Tag) anyerror!bool {
        if (self.current.tag == tag) {
            try self.advance();
            return true;
        }
        return false;
    }

    fn tokenText(self: *const Parser, tok: lexer_mod.Token) []const u8 {
        return self.lexer.source[tok.start .. tok.start + tok.len];
    }

    fn currentText(self: *const Parser) []const u8 {
        return self.tokenText(self.current);
    }

    fn alignTo(offset: u32, alignment: u32) u32 {
        return (offset + alignment - 1) & ~(alignment - 1);
    }

    fn getTypeSizeAndAlign(type_name: []const u8, size: *u32, align_val: *u32) anyerror!void {
        if (std.mem.eql(u8, type_name, "i32") or std.mem.eql(u8, type_name, "u32")) {
            size.* = 4;
            align_val.* = 4;
        } else if (std.mem.eql(u8, type_name, "f64")) {
            size.* = 8;
            align_val.* = 8;
        } else if (std.mem.eql(u8, type_name, "ptr")) {
            size.* = 8;
            align_val.* = 8;
        } else {
            size.* = 8;
            align_val.* = 8;
        }
    }

    fn nextLabelId(self: *Parser) u32 {
        self.label_counter += 1;
        return self.label_counter;
    }

    /// Allocate a temporary register name and declare it as an owned value.
    ///
    /// In SA-ASM only a register-to-register assignment moves its source;
    /// arithmetic, `load`, `call` and `br` all leave their operands live, so
    /// they must be released. Tracking temporaries is therefore safe *provided*
    /// `markConsumed` is called on assignment, which is the one case that moves.
    /// A temporary created inside a loop body is additionally marked loop-local,
    /// since its name is re-assigned every iteration and releasing it there
    /// would be a use-after-move on the next pass.
    fn newTemp(self: *Parser) anyerror![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
        if (self.scope_manager.declareVar(name, "i32", name, true)) {
            self.scope_manager.markDefBlock(name, self.lowerer.currentBlock());
        } else |_| {}
        return name;
    }

    /// Pop the innermost scope, first releasing the values that scope owns.
    ///
    /// A loop body or a branch arm that allocates leaves its registers live at
    /// the merge point: the scope is popped, so the function-exit walk can no
    /// longer see them, and the verifier then either reports them as a leak or,
    /// at a loop back-edge, rejects the merge as a phi state conflict. Emitting
    /// the `!` here puts it on the path actually taken.
    ///
    /// Only the innermost scope is walked, so parameters and enclosing locals
    /// are left to the function's own exit. A body that already ended in
    /// `return`, `break` or `continue` is terminated, and a release written
    /// after it would be unreachable.
    fn exitScopeReleasingLocals(self: *Parser) anyerror!void {
        try self.refreshDominators();
        if (!self.lowerer.isTerminated()) {
            try self.scope_manager.releaseCurrentScopeOwned(self.lowerer);
        }
        try self.scope_manager.exitScope(self.lowerer);
    }


    /// Map a TypeScript type name onto one the SA assembler accepts.
    ///
    /// SA-ASM only knows its own scalar and pointer types. A TypeScript
    /// interface, type alias, generic, `string`, or array is a pointer;
    /// emitting the source-level name fails with "unsupported type annotation
    /// during flattening".
    fn saTypeOf(ts_type: []const u8) []const u8 {
        const scalars = [_][]const u8{
            "i32", "u32",  "i64", "u64", "f64", "f32",
            "i8",  "u8",   "i16", "u16", "bool", "void",
        };
        for (scalars) |s| {
            if (std.mem.eql(u8, ts_type, s)) return ts_type;
        }
        return "ptr";
    }

    /// Emit a fall-through-preserving conditional branch.
    ///
    /// SA-ASM has no `jz`; the conditional branch is
    /// `br <cond> -> <true_label>, <false_label>` and both targets are
    /// mandatory. To express "skip to `false_label` when `cond` is false"
    /// while keeping the true path falling through, emit the branch against a
    /// fresh label that immediately follows it.
    fn emitBranchIfFalse(self: *Parser, cond: []const u8, false_label: []const u8) anyerror![]const u8 {
        const fallthrough = try std.fmt.allocPrint(self.allocator, "L_then_{d}", .{self.nextLabelId()});
        try self.lowerer.emitBranchTo(cond, fallthrough, false_label);
        try self.lowerer.emitLabel(fallthrough);
        return fallthrough;
    }

    /// Emit `br <cond> -> <true_label>, <false_label>` with both targets given.
    fn emitBranch(self: *Parser, cond: []const u8, true_label: []const u8, false_label: []const u8) anyerror!void {
        try self.lowerer.emitBranchTo(cond, true_label, false_label);
    }

    fn pushLoopTargets(self: *Parser, break_label: []const u8, continue_label: []const u8) anyerror!void {
        const depth = self.scope_manager.scopeDepth();
        try self.break_stack.append(.{ .label = break_label, .scope_depth = depth });
        try self.continue_stack.append(.{ .label = continue_label, .scope_depth = depth });
    }

    fn popLoopTargets(self: *Parser) void {
        _ = self.break_stack.pop();
        _ = self.continue_stack.pop();
    }

    /// Register a `switch` break target. A switch has no continue target.
    fn pushSwitchTarget(self: *Parser, break_label: []const u8) anyerror!void {
        try self.break_stack.append(.{ .label = break_label, .scope_depth = self.scope_manager.scopeDepth() });
    }

    /// Push the parameter names of the function being parsed.
    fn pushFuncParams(self: *Parser, names: []const []const u8) anyerror!void {
        const copy = try self.allocator.dupe([]const u8, names);
        try self.func_param_stack.append(copy);
    }

    /// Release the enclosing function's parameters.
    ///
    /// Must run before the `return`/terminator on every exit path, otherwise
    /// the releases are unreachable and verification fails with "live
    /// registers remain at function exit".
    /// Release every live owned register in the open scopes.
    ///
    /// Emitted before a `return` or a synthesised function terminator so no
    /// release is left unreachable after a terminator. Registers already moved
    /// by an instruction are skipped, as are registers whose definition does not
    /// dominate the release point, using the computed CFG when one is available.
    fn releaseLiveRegisters(self: *Parser) anyerror!void {
        try self.releaseLiveRegistersExcept(null);
    }

    /// Refresh the cached dominance matrix for the block being emitted.
    ///
    /// Called before every release walk, where the CFG so far is complete
    /// enough to decide which definitions are live at the release point:
    /// every path to the current block consists of already-emitted blocks,
    /// and no future edge can add a new path into the past. A stale matrix
    /// (kept across a branch boundary) is what used to veto required
    /// releases, so each walk recomputes instead of reusing one.
    fn refreshDominators(self: *Parser) anyerror!void {
        if (self.dominators) |d| self.allocator.free(d);
        self.dominators = try self.lowerer.computeDominators();
        self.scope_manager.reaches = self.dominators;
    }

    /// Release live owned registers, keeping `keep` alive.
    ///
    /// The register holding a returned value must not be released before the
    /// `return`: the assembler reports that as a use-after-move.
    fn releaseLiveRegistersExcept(self: *Parser, keep: ?[]const u8) anyerror!void {
        try self.refreshDominators();
        try self.scope_manager.releaseAllOwnedExcept(self.lowerer, keep);
    }

    // ==========================================
    // Top-level parse
    // ==========================================

    pub fn parse(self: *Parser) anyerror!void {
        try self.scope_manager.enterScope();
        while (self.current.tag != .eof) {
            self.parseStatement() catch |err| {
                if (err == error.UnexpectedToken) {
                    // Already recorded in expect(), continue parsing
                    continue;
                }
                // For other errors, record and try to continue
                const msg = try std.fmt.allocPrint(self.allocator, "error: {}", .{err});
                try self.errors.append(.{ .line = self.current.line, .col = self.current.col, .message = msg });
                self.skipToSync();
            };
        }
        try self.scope_manager.exitScope(self.lowerer);
    }

    // ==========================================
    // Statement dispatch
    // ==========================================

    fn parseStatement(self: *Parser) anyerror!void {
        switch (self.current.tag) {
            .l_brace => {
                try self.expect(.l_brace);
                try self.scope_manager.enterScope();
            },
            .r_brace => {
                try self.expect(.r_brace);
                // A block closing inside a branch arm or a loop body releases
                // what it owns: the scope is popped right here, so the
                // function-exit walk can no longer see those values and the
                // verifier reports them as leaked. At function top level both
                // depths are back to zero, and that scope is the one the
                // function's own exit releases, so it must be left alone.
                if (self.branch_depth > 0 or self.loop_depth > 0) {
                    try self.exitScopeReleasingLocals();
                } else {
                    try self.scope_manager.exitScope(self.lowerer);
                }
            },
            .semicolon => {
                try self.advance();
            },
            .keyword_interface => try self.parseInterface(),
            .keyword_let => try self.parseLet(),
            .keyword_const => try self.parseLet(),
            .keyword_function => try self.parseFunction(),
            .keyword_if => try self.parseIf(),
            .keyword_while => try self.parseWhile(),
            .keyword_for => try self.parseFor(),
            .keyword_return => try self.parseReturn(),
            .keyword_switch => try self.parseSwitch(),
            .keyword_type => try self.parseTypeAlias(),
            .keyword_enum => try self.parseEnum(),
            .keyword_import => try self.parseImport(),
            .keyword_declare => try self.parseDeclare(),
            .keyword_try => try self.parseTryCatch(),
            .keyword_throw => try self.parseThrow(),
            .keyword_break => {
                try self.advance();
                _ = try self.accept(.semicolon);
                // SA-ASM has no `break`; lower it to a jump to the enclosing
                // loop/switch exit label.
                if (self.break_stack.items.len > 0) {
                    const target = self.break_stack.items[self.break_stack.items.len - 1];
                    // Release only the scopes this jump abandons. Releasing
                    // every open scope would free the enclosing function's
                    // locals here, leaving the merge point to see one arm with
                    // a consumed register and the other still holding it.
                    try self.refreshDominators();
                    try self.scope_manager.releaseScopesDeeperThan(self.lowerer, target.scope_depth);
                    try self.lowerer.useLabel(target.label);
                    try self.lowerer.emitJumpTo(target.label);
                } else {
                    const msg = try std.fmt.allocPrint(self.allocator, "error: break outside loop or switch", .{});
                    try self.errors.append(.{ .line = self.current.line, .col = self.current.col, .message = msg });
                }
            },
            .keyword_continue => {
                try self.advance();
                _ = try self.accept(.semicolon);
                // `continue` jumps to the enclosing loop's head, which re-runs
                // the loop test. A switch is not a continue target.
                // As with `break`, the jump abandons every scope up to the loop
                // head, so their values have to be released here rather than left
                // to a function-exit walk that will never see them.
                if (self.continue_stack.items.len > 0) {
                    const target = self.continue_stack.items[self.continue_stack.items.len - 1];
                    try self.refreshDominators();
                    try self.scope_manager.releaseScopesDeeperThan(self.lowerer, target.scope_depth);
                    try self.lowerer.useLabel(target.label);
                    try self.lowerer.emitJumpTo(target.label);
                } else {
                    const msg = try std.fmt.allocPrint(self.allocator, "error: continue outside loop", .{});
                    try self.errors.append(.{ .line = self.current.line, .col = self.current.col, .message = msg });
                }
            },
            .keyword_async => try self.parseAsyncFunction(),
            .identifier => {
                // Check for export keyword
                if (std.mem.eql(u8, self.currentText(), "export")) {
                    try self.advance(); // skip export
                    // Parse the exported declaration
                    if (self.current.tag == .keyword_function) {
                        try self.parseFunction();
                    } else if (self.current.tag == .keyword_let or self.current.tag == .keyword_const) {
                        try self.parseLet();
                    } else if (self.current.tag == .keyword_interface) {
                        try self.parseInterface();
                    } else {
                        try self.parseIdentifierStatement();
                    }
                } else {
                    try self.parseIdentifierStatement();
                }
            },
            else => {
                std.debug.print("warning:{d}:{d}: skipping unexpected token {s}\n", .{
                    self.current.line,
                    self.current.col,
                    @tagName(self.current.tag),
                });
                try self.advance();
            },
        }
    }

    // ==========================================
    // Interface
    // ==========================================


    /// Parse a type name that may include generic parameters like Array<i32>
    fn parseTypeName(self: *Parser) anyerror![]const u8 {
        const name_tok = self.current;
        try self.expect(.identifier);
        var type_name = self.tokenText(name_tok);

        // Check for generic parameters: Type<Param>
        if (self.current.tag == .less) {
            // Could be generic type or comparison - peek ahead
            // For now, treat as generic if followed by identifier
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            try self.advance(); // skip <
            const is_type = self.current.tag == .identifier;
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;

            if (is_type) {
                try self.advance(); // skip <
                const param_tok = self.current;
                try self.expect(.identifier);
                const param = self.tokenText(param_tok);
                // Handle multiple type params: Map<K, V>
                type_name = try std.fmt.allocPrint(self.allocator, "{s}<{s}", .{ type_name, param });
                while (try self.accept(.comma)) {
                    const next_param_tok = self.current;
                    try self.expect(.identifier);
                    const next_param = self.tokenText(next_param_tok);
                    type_name = try std.fmt.allocPrint(self.allocator, "{s},{s}", .{ type_name, next_param });
                }
                try self.expect(.greater);
                type_name = try std.fmt.allocPrint(self.allocator, "{s}>", .{type_name});
            }
        }

        // Array type suffix: `T[]`.
        //
        // This suffix must be consumed here. Otherwise a declaration such as
        // `let arr: i32[] = [1, 2, 3]` leaves `[` as the current token and the
        // following `expect(.equal)` fails, silently dropping the entire
        // statement while still exiting 0. Layout and element-size purposes
        // want the element type, so return the base name.
        if (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
            try self.advance(); // [
            try self.advance(); // ]
        }

        // Return base name (strip generics) for layout table compatibility
        if (std.mem.indexOf(u8, type_name, "<")) |angle_idx| {
            return type_name[0..angle_idx];
        }
        return type_name;
    }

    fn parseInterface(self: *Parser) anyerror!void {
        try self.expect(.keyword_interface);

        const name_tok = self.current;
        try self.expect(.identifier);
        const name = self.tokenText(name_tok);

        // Handle generic type parameters: Interface<T> or Interface<K, V>
        if (self.current.tag == .less) {
            try self.advance(); // skip <
            // Read type parameter names
            while (self.current.tag != .greater and self.current.tag != .eof) {
                try self.expect(.identifier); // type param name
                _ = try self.accept(.comma);
            }
            try self.expect(.greater);
            // Keep original name (without generics) for layout registration
        }

        try self.expect(.l_brace);

        var fields = std.ArrayList(Field).init(self.allocator);
        var offset: u32 = 0;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            const f_name_tok = self.current;
            try self.expect(.identifier);
            const f_name = self.tokenText(f_name_tok);

            try self.expect(.colon);

            const f_type = try self.parseTypeName();

            var f_size: u32 = 8;
            var f_align: u32 = 8;
            try getTypeSizeAndAlign(f_type, &f_size, &f_align);
            offset = alignTo(offset, f_align);

            try fields.append(.{
                .name = try self.allocator.dupe(u8, f_name),
                .offset = offset,
                .type_name = try self.allocator.dupe(u8, f_type),
            });
            offset += f_size;

            _ = try self.accept(.semicolon);
        }
        try self.expect(.r_brace);

        const layout = StructLayout{
            .name = try self.allocator.dupe(u8, name),
            .size = offset,
            .fields = fields,
        };
        try self.layout_table.register(name, layout);
    }

    // ==========================================
    // Type alias
    // ==========================================

    fn parseTypeAlias(self: *Parser) anyerror!void {
        try self.expect(.keyword_type);
        const name_tok = self.current;
        try self.expect(.identifier);
        const name = self.tokenText(name_tok);

        try self.expect(.equal);

        const target_tok = self.current;
        try self.expect(.identifier);
        const target = self.tokenText(target_tok);

        _ = try self.accept(.semicolon);

        // Register as an alias by duplicating the target layout if it exists
        if (self.layout_table.find(target)) |src_layout| {
            var alias_fields = std.ArrayList(Field).init(self.allocator);
            for (src_layout.fields.items) |f| {
                try alias_fields.append(.{
                    .name = try self.allocator.dupe(u8, f.name),
                    .offset = f.offset,
                    .type_name = try self.allocator.dupe(u8, f.type_name),
                });
            }
            const alias_layout = StructLayout{
                .name = try self.allocator.dupe(u8, name),
                .size = src_layout.size,
                .fields = alias_fields,
            };
            try self.layout_table.register(name, alias_layout);
        }
    }

    // ==========================================
    // Enum
    // ==========================================

    fn parseEnum(self: *Parser) anyerror!void {
        try self.expect(.keyword_enum);
        const name_tok = self.current;
        try self.expect(.identifier);
        const name = self.tokenText(name_tok);

        try self.expect(.l_brace);

        var variants = std.ArrayList([]const u8).init(self.allocator);
        var val: i64 = 0;
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            const v_tok = self.current;
            try self.expect(.identifier);
            const v_name = self.tokenText(v_tok);
            try variants.append(try self.allocator.dupe(u8, v_name));

            // Optional explicit value
            if (try self.accept(.equal)) {
                const num_tok = self.current;
                try self.expect(.number);
                const num_text = self.tokenText(num_tok);
                val = std.fmt.parseInt(i64, num_text, 10) catch 0;
            }

            // Emit as constant
            try self.lowerer.emit("    #def {s}.{s} = {d}\n", .{ name, v_name, val });
            val += 1;
            _ = try self.accept(.comma);
        }
        try self.expect(.r_brace);

        try self.enums.append(.{ .name = try self.allocator.dupe(u8, name), .variants = variants });
    }

    // ==========================================
    // Let / Const
    // ==========================================

    /// Parse `{ field: value, ... }` with the cursor on `{` as a value of the
    /// interface `type_name`: allocate a fresh register, store each field
    /// into it, and return the register.
    ///
    /// A nested `{ ... }` field value reuses the outer interface's field type
    /// as its layout, so arbitrarily nested literals lower without an
    /// annotation at every level. The fresh register is retagged from `i32`
    /// to the struct type so chained property access (`o.inner.a`) resolves
    /// the layout through it.
    fn parseNewStructLiteral(self: *Parser, type_name: []const u8) anyerror![]const u8 {
        const layout = self.layout_table.find(type_name) orelse {
            std.debug.print("error:{d}:{d}: struct literal of unknown interface '{s}'\n", .{
                self.current.line,
                self.current.col,
                type_name,
            });
            return error.UnknownInterface;
        };
        const dest = try self.newTemp();
        if (self.scope_manager.lookup(dest)) |tv| {
            self.allocator.free(tv.type_name);
            tv.type_name = try self.allocator.dupe(u8, type_name);
        }
        try self.lowerer.emit("    {s} = alloc {d}\n", .{ dest, layout.size });
        try self.expect(.l_brace);
        try self.parseStructLiteralFields(dest, layout);
        return dest;
    }

    /// Parse the `field: value, ... }` tail of a struct literal, storing each
    /// field into the already-allocated register `dest`.
    fn parseStructLiteralFields(self: *Parser, dest: []const u8, layout: *StructLayout) anyerror!void {
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            const f_name_tok = self.current;
            try self.expect(.identifier);
            const f_name = self.tokenText(f_name_tok);

            try self.expect(.colon);

            var found_field: ?Field = null;
            for (layout.fields.items) |f| {
                if (std.mem.eql(u8, f.name, f_name)) {
                    found_field = f;
                    break;
                }
            }
            const field = found_field orelse return error.UnknownField;

            const val: []const u8 = if (self.current.tag == .l_brace)
                try self.parseNewStructLiteral(field.type_name)
            else
                try self.parseExpression();

            try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ dest, field.offset, val, saTypeOf(field.type_name) });

            _ = try self.accept(.comma);
            _ = try self.accept(.semicolon);
        }
        try self.expect(.r_brace);
    }

    fn parseLet(self: *Parser) anyerror!void {
        const is_const = self.current.tag == .keyword_const;
        if (is_const) {
            try self.advance();
        } else {
            try self.expect(.keyword_let);
        }

        const var_name_tok = self.current;
        try self.expect(.identifier);
        const var_name = self.tokenText(var_name_tok);

        var type_name: ?[]const u8 = null;
        if (try self.accept(.colon)) {
            type_name = try self.parseTypeName();
        }

        try self.expect(.equal);

        if (try self.accept(.l_brace)) {
            // Object literal initialization
            const t_name = type_name orelse return error.TypeAnnotationRequiredForObjectLiteral;
            const layout = self.layout_table.find(t_name) orelse return error.UnknownInterface;

            try self.scope_manager.declareVar(var_name, t_name, var_name, true);

            try self.lowerer.emit("    {s} = alloc {d}\n", .{ var_name, layout.size });

            try self.parseStructLiteralFields(var_name, layout);
        } else if (try self.accept(.l_bracket)) {
            // Array literal initialization: let arr = [1, 2, 3]
            const elem_type = type_name orelse "i32";
            var elem_size: u32 = 4;
            var elem_align: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &elem_size, &elem_align);

            var values = std.ArrayList([]const u8).init(self.allocator);
            defer values.deinit();

            while (self.current.tag != .r_bracket and self.current.tag != .eof) {
                const val = try self.parseExpression();
                try values.append(val);
                _ = try self.accept(.comma);
            }
            try self.expect(.r_bracket);

            const elem_count = @as(u32, @intCast(values.items.len));

            // A TypeScript array is lowered to an SA slice: a 16-byte header
            // holding {ptr, len} with the elements in a separate buffer.
            //
            // Storing the elements inline in the header was wrong: `for (const
            // v of arr)` reads the length from +8 and the data pointer from +0,
            // so for `[1,2,3]` it read the third element as a length and the
            // first as a pointer, then dereferenced it. That verified but
            // segfaulted at run time. The slice layout is also what sa_std
            // primitives expect, so arrays can be passed to them.
            const arr_size = @max(elem_count * elem_size, 16);
            try self.scope_manager.declareVar(var_name, elem_type, var_name, true);

            try self.lowerer.emit("    {s} = alloc {d}\n", .{ var_name, arr_size });

            // Element storage; a zero-length array still needs a valid pointer.
            const data_reg = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc {d}\n", .{ data_reg, @max(elem_count * elem_size, 4) });

            for (values.items, 0..) |val, idx| {
                const off = @as(u32, @intCast(idx)) * elem_size;
                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ data_reg, off, val, saTypeOf(elem_type) });
            }
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ var_name, data_reg });
            try self.lowerer.emit("    store {s} + 8, {d} as u64\n", .{ var_name, elem_count });
        } else {
            const val = try self.parseExpression();
            const t_name = type_name orelse "i32";

            const is_heap = std.mem.startsWith(u8, val, "slice_") or std.mem.eql(u8, t_name, "string");

            // A register-to-register initialiser would otherwise move the source.
            // TypeScript has no move semantics for scalars: `let b: i32 = a` copies
            // and `a` stays usable. This is not only a branch concern -- reading a
            // moved value in a later `switch` is a use-after-move even when the
            // initialiser sits at function top level -- so the copy is unconditional
            // for i32 rather than gated on `branch_depth`.
            //
            const src_is_var = self.scope_manager.lookup(val) != null;
            // Inside a branch the binding is copied, as before: its scope is popped
            // at the end of the arm, so a move-owned value would be one the
            // function-exit walk can no longer see, and the verifier reports it as
            // a leak. Outside a branch the same is true when the initialiser is a
            // parameter, which the body may still read after this statement.
            const copy_scalar = src_is_var and std.mem.eql(u8, t_name, "i32") and
                (self.branch_depth > 0 or self.scope_manager.isOuterVariable(val));
            if (copy_scalar) {
                try self.lowerer.emit("    {s} = add {s}, 0\n", .{ var_name, val });
                try self.scope_manager.declareVar(var_name, t_name, var_name, is_heap);
                return;
            }
            const is_move = src_is_var;
            if (is_move) {
                self.scope_manager.markConsumed(val);
            }

            // A move transfers ownership of the source, so the source is not
            // released again, and the destination inherits the obligation to be
            // released -- that is what `or is_move` records, and the SA verifier
            // rejects a function that leaves a declared register live at exit.
            try self.scope_manager.declareVar(var_name, t_name, var_name, is_heap or is_move);

            try self.lowerer.emit("    {s} = {s}\n", .{ var_name, val });
        }

        _ = try self.accept(.semicolon);
    }

    // ==========================================
    // Function
    // ==========================================

    fn parseFunction(self: *Parser) anyerror!void {
        try self.expect(.keyword_function);

        const func_name_tok = self.current;
        try self.expect(.identifier);
        const func_name = self.tokenText(func_name_tok);

        try self.expect(.l_paren);

        var params = std.ArrayList(struct { name: []const u8, type_name: []const u8 }).init(self.allocator);
        defer params.deinit();

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const p_name_tok = self.current;
            try self.expect(.identifier);
            const p_name = self.tokenText(p_name_tok);

            var p_type: []const u8 = "i32";
            if (try self.accept(.colon)) {
                p_type = try self.parseTypeName();
            }

            try params.append(.{ .name = p_name, .type_name = p_type });

            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);

        // Optional return type annotation: `function f(): i32 { ... }`
        //
        // SA-ASM needs this in the signature (`@f(...) -> i32:`) whenever the
        // function yields a value. Without it the backend rejects the `return`
        // with "Instruction has a name, but provides a void value".
        var return_type: ?[]const u8 = null;
        if (try self.accept(.colon)) {
            return_type = try self.parseTypeName();
        }

        try self.lowerer.emit("@{s}(", .{func_name});
        for (params.items, 0..) |p, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            // A struct-typed parameter is a pointer in SA-ASM. The TypeScript
            // interface name is not a type the assembler knows, so emitting it
            // verbatim fails with "unsupported type annotation".
            try self.lowerer.emit("{s}: {s}", .{ p.name, saTypeOf(p.type_name) });
        }
        if (return_type) |rt| {
            if (!std.mem.eql(u8, rt, "void")) {
                try self.lowerer.emit(") -> {s}:", .{saTypeOf(rt)});
            } else {
                try self.lowerer.emit("):", .{});
            }
        } else {
            try self.lowerer.emit("):", .{});
        }
        try self.lowerer.emit("\n", .{});
        self.lowerer.beginFunction();

        // Releases are emitted at return sites and at function exit, not when a
        // lexical scope closes, so they never land after a terminator.
        self.scope_manager.defer_releases = true;
        defer self.scope_manager.defer_releases = false;

        try self.scope_manager.enterScope();

        // Declare params as owned registers. SA-ASM requires every live
        // register to be released before the function exits, and a parameter
        // that is never consumed by an instruction is still live.
        for (params.items) |p| {
            try self.scope_manager.declareVar(p.name, p.type_name, p.name, true);
        }

        // Parse body
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            // Release while the body's scope is still open, otherwise its
            // locals are already popped and their `!` releases are lost.
            if (!self.lowerer.isTerminated()) {
                try self.releaseLiveRegisters();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance(); // consume }
        }

        try self.scope_manager.exitScope(self.lowerer);

        // Guarantee a well-formed final basic block. SA-ASM requires every
        // block to end in a terminator, and control can reach the end of a
        // function without an explicit `return` (e.g. an if/else where both
        // arms fall through to the merge point). Parameters must be released
        // before that terminator, since they are live registers.
        const default_ret: []const u8 = if (return_type) |rt|
            (if (std.mem.eql(u8, rt, "void")) "return" else "return 0")
        else
            "return";
        try self.lowerer.finishFunction(default_ret);
    }

    fn parseAsyncFunction(self: *Parser) anyerror!void {
        try self.expect(.keyword_async);
        // Reuse function parse with async prefix annotation
        try self.expect(.keyword_function);

        const func_name_tok = self.current;
        try self.expect(.identifier);
        const func_name = self.tokenText(func_name_tok);

        try self.expect(.l_paren);

        var params = std.ArrayList(struct { name: []const u8, type_name: []const u8 }).init(self.allocator);
        defer params.deinit();

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const p_name_tok = self.current;
            try self.expect(.identifier);
            const p_name = self.tokenText(p_name_tok);

            var p_type: []const u8 = "i32";
            if (try self.accept(.colon)) {
                p_type = try self.parseTypeName();
            }

            try params.append(.{ .name = p_name, .type_name = p_type });
            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);
        _ = try self.accept(.colon);

        try self.lowerer.emit("@async @{s}(", .{func_name});
        for (params.items, 0..) |p, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}: {s}", .{ p.name, p.type_name });
        }
        try self.lowerer.emit("):\n", .{});

        try self.scope_manager.enterScope();
        for (params.items) |p| {
            const is_ptr = !std.mem.eql(u8, p.type_name, "i32") and !std.mem.eql(u8, p.type_name, "u32") and !std.mem.eql(u8, p.type_name, "f64");
            try self.scope_manager.declareVar(p.name, p.type_name, p.name, is_ptr);
        }

        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance();
        }

        try self.scope_manager.exitScope(self.lowerer);
    }

    // ==========================================
    // If / While / For / Switch
    // ==========================================

    fn parseIf(self: *Parser) anyerror!void {
        try self.expect(.keyword_if);
        try self.expect(.l_paren);
        const cond = try self.parseExpression();
        try self.expect(.r_paren);

        const label_id = self.nextLabelId();
        const else_label = try std.fmt.allocPrint(self.allocator, "L_else_{d}", .{label_id});
        const end_label = try std.fmt.allocPrint(self.allocator, "L_endif_{d}", .{label_id});
        try self.lowerer.reserveLabel(else_label);

        _ = try self.emitBranchIfFalse(cond, else_label);

        // Then branch
        self.branch_depth += 1;
        defer self.branch_depth -= 1;
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.exitScopeReleasingLocals();
            try self.advance();
        } else {
            try self.parseStatement();
        }

        if (!self.lowerer.isTerminated()) {
            try self.lowerer.emitJumpTo(end_label);
        }
        try self.lowerer.emitLabel(else_label);

        if (self.current.tag == .keyword_else) {
            try self.advance();
            self.branch_depth += 1;
            defer self.branch_depth -= 1;
            if (self.current.tag == .keyword_if) {
                try self.parseIf();
            } else if (self.current.tag == .l_brace) {
                try self.advance();
                try self.scope_manager.enterScope();
                while (self.current.tag != .r_brace and self.current.tag != .eof) {
                    try self.parseStatement();
                }
                try self.exitScopeReleasingLocals();
                try self.advance();
            } else {
                try self.parseStatement();
            }
        }

        if (!self.lowerer.isTerminated()) {
            try self.lowerer.emitJumpTo(end_label);
        }
        try self.lowerer.emitLabel(end_label);
    }

    fn parseWhile(self: *Parser) anyerror!void {
        try self.expect(.keyword_while);
        try self.expect(.l_paren);

        const label_id = self.nextLabelId();
        const loop_label = try std.fmt.allocPrint(self.allocator, "L_while_{d}", .{label_id});
        const end_label = try std.fmt.allocPrint(self.allocator, "L_endwhile_{d}", .{label_id});
        try self.lowerer.reserveLabel(loop_label);
        try self.lowerer.reserveLabel(end_label);

        try self.lowerer.emitLabel(loop_label);
        const cond = try self.parseExpression();
        try self.expect(.r_paren);

        _ = try self.emitBranchIfFalse(cond, end_label);
        try self.pushLoopTargets(end_label, loop_label);

        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.exitScopeReleasingLocals();
            try self.advance();
        } else {
            try self.parseStatement();
        }

        try self.lowerer.useLabel(loop_label);
        try self.lowerer.emitJumpTo(loop_label);
        try self.lowerer.emitLabel(end_label);
        self.popLoopTargets();
    }

    /// Parse the increment clause of a C-style `for` header.
    ///
    /// An assignment (`i = i + 2`, `i = i - 1`) is a statement shape, not an
    /// expression: routing it through `parseExpression` parses just the `i`,
    /// leaves `= ...` unconsumed, and the following `expect(.r_paren)` fails.
    /// That error is recorded only in `Parser.errors`, which the CLI never
    /// prints, so the whole rest of the function was silently dropped while
    /// the CLI still reported success. `i++` / `i--` already parse as
    /// expressions and keep that path.
    /// Emit `!name` if `name` currently owns an unreleased moved value.
    ///
    /// SA-ASM is affine: moving a register into a name that already owns a
    /// moved value (`total = t_1` after `total = t_0`) fails with
    /// RegisterRedefinition, while rebinding a const-bound scalar rebinds
    /// freely. Anything heap-marked and unreleased must be freed first.
    /// `def_block` is deliberately left alone so the function-exit walk
    /// still sees the entry definition dominate and releases whichever
    /// value is live on each path.
    fn releaseOwnedIfLive(self: *Parser, name: []const u8) anyerror!void {
        const v = self.scope_manager.lookup(name) orelse return;
        if (v.is_heap_allocated and !v.is_consumed and !v.is_released) {
            try self.lowerer.emit("    !{s}\n", .{v.reg});
            v.is_released = true;
        }
    }

    /// Mark `name` as freshly bound: the new value is live and needs its own
    /// future release, even if the previous value was just released or the
    /// name was consumed before.
    fn markRebound(self: *Parser, name: []const u8) void {
        if (self.scope_manager.lookup(name)) |v| {
            v.is_released = false;
            v.is_consumed = false;
        }
    }

    /// Lower `name = val` with move semantics, releasing first if needed.
    ///
    /// The old value is released via `releaseOwnedIfLive`; the fresh value
    /// then needs its own future release, hence the flag reset.
    fn emitMove(self: *Parser, name: []const u8, val: []const u8) anyerror!void {
        if (!std.mem.eql(u8, name, val)) {
            try self.releaseOwnedIfLive(name);
            if (self.scope_manager.lookup(val) != null) {
                self.scope_manager.markConsumed(val);
            }
        }
        try self.lowerer.emit("    {s} = {s}\n", .{ name, val });
        self.markRebound(name);
    }

    fn parseForIncrement(self: *Parser) anyerror!void {
        if (self.current.tag == .identifier and self.peek.tag == .equal) {
            const name_tok = self.current;
            try self.advance();
            const name = self.tokenText(name_tok);
            try self.expect(.equal);
            const val = try self.parseExpression();
            // Same move semantics as a statement-level assignment, including
            // the release-before-rebind a move-bound induction variable needs.
            try self.emitMove(name, val);
            return;
        }
        _ = try self.parseExpression();
    }

    fn parseFor(self: *Parser) anyerror!void {
        try self.expect(.keyword_for);
        try self.expect(.l_paren);

        // Detect for-of pattern: for (const x of expr) or for (let x of expr)
        if ((self.current.tag == .keyword_let or self.current.tag == .keyword_const) and
            self.peek.tag == .identifier)
        {
            // Save state to check if 'of' follows the variable name
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;

            // Skip let/const and identifier to see if 'of' follows
            const is_const = self.current.tag == .keyword_const;
            try self.advance(); // skip let/const
            const var_name_tok = self.current;
            _ = var_name_tok;
            try self.advance(); // skip identifier

            const is_of = self.current.tag == .identifier and std.mem.eql(u8, self.currentText(), "of");

            // Restore state
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;

            if (is_of) {
                // Parse as for-of
                if (is_const) {
                    try self.advance(); // const
                } else {
                    try self.advance(); // let
                }
                const iter_name_tok = self.current;
                try self.expect(.identifier);
                const iter_name = self.tokenText(iter_name_tok);

                // Skip 'of'
                try self.advance(); // of (identifier)

                const iterable = try self.parseExpression();
                try self.expect(.r_paren);

                const label_id = self.nextLabelId();
                const loop_label = try std.fmt.allocPrint(self.allocator, "L_forof_{d}", .{label_id});
                const end_label = try std.fmt.allocPrint(self.allocator, "L_endforof_{d}", .{label_id});
                try self.lowerer.reserveLabel(loop_label);
                try self.lowerer.reserveLabel(end_label);

                // Emit for-of loop: iterate over iterable
                // Load length from iterable + 8 (string/slice layout)
                const len_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len_temp, iterable });

                const idx_var = try self.newTemp();
                try self.lowerer.emit("    {s} = 0\n", .{idx_var});

                try self.lowerer.emitLabel(loop_label);

                // Check idx < len
                const cmp_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ cmp_temp, idx_var, len_temp });
                _ = try self.emitBranchIfFalse(cmp_temp, end_label);
                try self.pushLoopTargets(end_label, loop_label);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;

                // Load element: iterable[idx]
                const ptr_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ptr_temp, iterable });
                const off_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = mul {s}, 4\n", .{ off_temp, idx_var });
                const addr_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, ptr_temp, off_temp });
                try self.lowerer.emit("    {s} = load {s} + 0 as i32\n", .{ iter_name, addr_temp });

                try self.scope_manager.enterScope();
                try self.scope_manager.declareVar(iter_name, "i32", iter_name, false);

                // Body
                if (self.current.tag == .l_brace) {
                    try self.advance();
                    try self.scope_manager.enterScope();
                    while (self.current.tag != .r_brace and self.current.tag != .eof) {
                        try self.parseStatement();
                    }
                    try self.exitScopeReleasingLocals();
                    try self.advance();
                } else {
                    try self.parseStatement();
                }

                try self.scope_manager.exitScope(self.lowerer);

                // Increment idx
                const inc_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inc_temp, idx_var });
                try self.lowerer.emit("    {s} = {s}\n", .{ idx_var, inc_temp });

                try self.lowerer.useLabel(loop_label);
                try self.lowerer.emitJumpTo(loop_label);
                try self.lowerer.emitLabel(end_label);
                self.popLoopTargets();
                return;
            }
        }

        // C-style for loop: for (init; cond; incr)
        if (self.current.tag == .keyword_let or self.current.tag == .keyword_const) {
            try self.parseLet();
        } else if (self.current.tag != .semicolon) {
            _ = try self.parseExpression();
            _ = try self.accept(.semicolon);
        } else {
            try self.advance(); // skip ;
        }

        const label_id = self.nextLabelId();
        const loop_label = try std.fmt.allocPrint(self.allocator, "L_for_{d}", .{label_id});
        const end_label = try std.fmt.allocPrint(self.allocator, "L_endfor_{d}", .{label_id});
        try self.lowerer.reserveLabel(loop_label);
        try self.lowerer.reserveLabel(end_label);

        try self.lowerer.emitLabel(loop_label);

        // Parse condition
        var cond: ?[]const u8 = null;
        if (self.current.tag != .semicolon) {
            cond = try self.parseExpression();
        }
        try self.expect(.semicolon);

        // Parse the increment clause into a deferred buffer.
        //
        // The increment must be emitted *after* the loop body, not here in the
        // header. SA-ASM emits basic blocks in execution order, and a `for`
        // loop runs body-then-increment. Emitting it here would place the
        // increment ahead of the loop test, running the body one extra time
        // with an already-incremented induction variable.
        var inc_buf: ?std.ArrayList(u8) = null;
        if (self.current.tag != .r_paren) {
            var buf = std.ArrayList(u8).init(self.allocator);
            self.lowerer.capture = &buf;
            const inc_result = self.parseForIncrement();
            self.lowerer.capture = null;
            // Surface parse errors, but keep the captured text.
            _ = try inc_result;
            inc_buf = buf;
        }
        try self.expect(.r_paren);

        if (cond) |c| {
            _ = try self.emitBranchIfFalse(c, end_label);
        }
        try self.pushLoopTargets(end_label, loop_label);

        // Body. Registers bound here are re-assigned every iteration.
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.exitScopeReleasingLocals();
            try self.advance();
        } else {
            try self.parseStatement();
        }

        // Increment, now in correct execution order.
        if (inc_buf) |buf| {
            try self.lowerer.emitRaw(buf.items);
        }

        try self.lowerer.useLabel(loop_label);
        try self.lowerer.emitJumpTo(loop_label);
        try self.lowerer.emitLabel(end_label);
        self.popLoopTargets();
    }

    fn parseSwitch(self: *Parser) anyerror!void {
        try self.expect(.keyword_switch);
        try self.expect(.l_paren);
        const scrutinee = try self.parseExpression();
        try self.expect(.r_paren);

        const label_id = self.nextLabelId();
        const end_label = try std.fmt.allocPrint(self.allocator, "L_endswitch_{d}", .{label_id});
        try self.lowerer.reserveLabel(end_label);

        try self.expect(.l_brace);
        try self.pushSwitchTarget(end_label);

        // Emit a chain of guarded case tests.
        //
        // Each case gets a "test" label and a "body" label. The test for case
        // i+1 is the fallthrough target of case i's comparison, so a value that
        // matches no case lands on the final test label, where the `default`
        // body (or the exit jump) lives. Testing this way keeps the dispatch
        // chain in one basic block per case and avoids jumping past the end
        // label, which previously let non-final cases fall through.
        var case_idx: u32 = 0;
        while (self.current.tag == .keyword_case) {
            try self.advance(); // case
            const case_val = try self.parseExpression();
            try self.expect(.colon);

            const test_label = try std.fmt.allocPrint(self.allocator, "L_case_{d}_t{d}", .{ label_id, case_idx });
            const body_label = try std.fmt.allocPrint(self.allocator, "L_case_{d}_b{d}", .{ label_id, case_idx });
            const next_test = try std.fmt.allocPrint(self.allocator, "L_case_{d}_t{d}", .{ label_id, case_idx + 1 });
            try self.lowerer.reserveLabel(test_label);
            try self.lowerer.reserveLabel(body_label);
            try self.lowerer.reserveLabel(next_test);

            try self.lowerer.emitLabel(test_label);
            const cmp_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = eq {s}, {s}\n", .{ cmp_temp, scrutinee, case_val });
            try self.emitBranch(cmp_temp, body_label, next_test);
            try self.lowerer.emitLabel(body_label);

            // Consume the case body up to the next `case`, `default`, or the
            // switch's closing brace.
            //
            // Brace depth must be tracked: a case body is commonly written as
            // a block (`case 1: { ... }`), and stopping at that block's `}`
            // would end the body early and leave the remaining cases to be
            // emitted as top-level code.
            var depth: u32 = 0;
            self.branch_depth += 1;
            defer self.branch_depth -= 1;
            while (self.current.tag != .eof) {
                if (depth == 0) {
                    if (self.current.tag == .keyword_case) break;
                    if (self.current.tag == .r_brace) break;
                    if (self.current.tag == .identifier and std.mem.eql(u8, self.currentText(), "default")) break;
                }
                if (self.current.tag == .l_brace) depth += 1;
                if (self.current.tag == .r_brace) depth -|= 1;
                try self.parseStatement();
            }

            if (!self.lowerer.isTerminated()) {
                try self.releaseLiveRegisters();
                try self.lowerer.emitJumpTo(end_label);
            }
            case_idx += 1;
        }

        // Fallthrough point for a scrutinee that matched no case: the `default`
        // body when present, otherwise an immediate exit.
        const default_test = try std.fmt.allocPrint(self.allocator, "L_case_{d}_t{d}", .{ label_id, case_idx });
        try self.lowerer.reserveLabel(default_test);
        try self.lowerer.emitLabel(default_test);

        // `default` is not a reserved word in this lexer, so it arrives as an
        // identifier.
        if (self.current.tag == .identifier and std.mem.eql(u8, self.currentText(), "default")) {
            try self.advance();
            try self.expect(.colon);
            // Depth-tracked, for the same reason as case bodies: a braced
            // `default: { ... }` must have its own closing brace consumed here.
            // Stopping at that brace would leave it for the `expect` below,
            // which would then eat the switch's closing brace and desync the
            // enclosing block.
            var default_depth: u32 = 0;
            while (self.current.tag != .eof) {
                if (default_depth == 0 and self.current.tag == .r_brace) break;
                if (self.current.tag == .l_brace) default_depth += 1;
                if (self.current.tag == .r_brace) default_depth -|= 1;
                try self.parseStatement();
            }
        } else {
            try self.lowerer.emitJumpTo(end_label);
        }

        try self.expect(.r_brace);
        try self.lowerer.emitLabel(end_label);
        _ = self.break_stack.pop();
    }

    // ==========================================
    // Return
    // ==========================================

    fn parseReturn(self: *Parser) anyerror!void {
        try self.expect(.keyword_return);
        if (self.current.tag != .semicolon and self.current.tag != .r_brace and self.current.tag != .eof) {
            // Evaluate first: the expression may read a local that is about to
            // be released, and releasing before the read is a use-after-move.
            const val = try self.parseExpression();
            try self.releaseLiveRegistersExcept(val);
            try self.lowerer.emitTerm("    return {s}\n", .{val});
        } else {
            try self.releaseLiveRegisters();
            try self.lowerer.emitTerm("    return\n", .{});
        }
        _ = try self.accept(.semicolon);
    }

    // ==========================================
    // Try / Catch / Throw
    // ==========================================

    fn parseTryCatch(self: *Parser) anyerror!void {
        try self.expect(.keyword_try);

        const label_id = self.nextLabelId();
        const catch_label = try std.fmt.allocPrint(self.allocator, "L_catch_{d}", .{label_id});
        const end_label = try std.fmt.allocPrint(self.allocator, "L_endtry_{d}", .{label_id});

        // Body
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance();
        }

        try self.lowerer.emitJumpTo(end_label);
        try self.lowerer.emitLabel(catch_label);

        if (self.current.tag == .keyword_catch) {
            try self.advance();
            var err_name: []const u8 = "err";
            if (self.current.tag == .l_paren) {
                try self.advance();
                if (self.current.tag == .identifier) {
                    err_name = self.currentText();
                    try self.advance();
                }
                try self.expect(.r_paren);
            }

            try self.scope_manager.enterScope();
            try self.scope_manager.declareVar(err_name, "i32", err_name, false);

            if (self.current.tag == .l_brace) {
                try self.advance();
                try self.scope_manager.enterScope();
                while (self.current.tag != .r_brace and self.current.tag != .eof) {
                    try self.parseStatement();
                }
                try self.scope_manager.exitScope(self.lowerer);
                try self.advance();
            }

            try self.scope_manager.exitScope(self.lowerer);
        }

        try self.lowerer.emitLabel(end_label);
    }

    fn parseThrow(self: *Parser) anyerror!void {
        try self.expect(.keyword_throw);
        const val = try self.parseExpression();
        _ = try self.accept(.semicolon);
        // SA-ASM has no `throw`: its closest terminator is `panic`, which
        // aborts. `try`/`catch` therefore cannot reproduce JS exception
        // semantics and lower to a jump-based approximation.
        try self.lowerer.emitTerm("    panic {s}\n", .{val});
    }

    // ==========================================
    // Import
    // ==========================================

    fn parseImport(self: *Parser) anyerror!void {
        try self.expect(.keyword_import);
        try self.expect(.l_brace);

        var symbols = std.ArrayList([]const u8).init(self.allocator);
        defer symbols.deinit();

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            const sym_tok = self.current;
            try self.expect(.identifier);
            try symbols.append(self.tokenText(sym_tok));
            _ = try self.accept(.comma);
        }
        try self.expect(.r_brace);

        try self.expect(.keyword_from);

        const path_tok = self.current;
        try self.expect(.string);
        var path = self.tokenText(path_tok);
        if (path.len >= 2 and (path[0] == '"' or path[0] == '\'')) {
            path = path[1 .. path.len - 1];
        }

        _ = try self.accept(.semicolon);

        if (std.mem.eql(u8, path, "fs")) {
            // Standard library: filesystem module
            for (symbols.items) |sym| {
                if (std.mem.eql(u8, sym, "readFile")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_read_file", .string_args = "1", .extra_args = "1048576" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "writeFile")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_write_file", .string_args = "12" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "open")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_open", .string_args = "1", .extra_args = "0" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "create")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_create", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "close")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_close", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "read")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_read", .string_args = "", .extra_args = "&buf, 4096" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "write")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_write", .string_args = "", .extra_args = "&buf, 0" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "remove")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_remove_file", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "mkdir")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_make_dir", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                }
            }
            try self.lowerer.emitImport("sa_std/fs.sai");
        } else if (std.mem.eql(u8, path, "net")) {
            // Standard library: network module
            for (symbols.items) |sym| {
                if (std.mem.eql(u8, sym, "tcpConnect")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_connect", .string_args = "1", .extra_args = "0" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpListen")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_listener_bind", .string_args = "1", .extra_args = "0" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpAccept")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_listener_accept", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpRead")) {
                    // `sa_net_tcp_stream_read(stream, &buf, cap)`: the buffer and
                    // its capacity are out-parameters, supplied as a scratch
                    // region by `emitStdlibCall` because SA-ASM has fixed callee
                    // arity and the TypeScript call site passes only the stream.
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_stream_read", .string_args = "", .extra_args = "&buf, 0" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpWrite")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_stream_write", .string_args = "", .extra_args = "&buf, 0" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpClose")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_stream_close", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                }
            }
            try self.lowerer.emitImport("sa_std/net.sai");
        } else if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".sa")) {
            // Local module import: emit @import directive
            try self.lowerer.emit("    @import {{ ", .{});
            for (symbols.items, 0..) |sym, idx| {
                if (idx > 0) try self.lowerer.emit(", ", .{});
                try self.lowerer.emit("{s}", .{sym});
            }
            try self.lowerer.emit(" }} from \"{s}\"\n", .{path});
            for (symbols.items) |sym| {
                try self.scope_manager.declareVar(sym, "extern", sym, false);
            }
        } else if (std.mem.endsWith(u8, path, ".wit")) {
            // WIT file import: emit WIT stub generation
            try self.lowerer.emit("    // WIT: Import from {s}\n", .{path});
            for (symbols.items) |sym| {
                try self.lowerer.emit("    @wit_import {s} from \"{s}\"\n", .{ sym, path });
                try self.scope_manager.declareVar(sym, "fn", sym, false);
            }
        } else if (std.mem.endsWith(u8, path, ".wasm")) {
            try self.lowerer.emit("    // WASM Interop: Import from {s}\n", .{path});
            for (symbols.items) |sym| {
                try self.scope_manager.declareVar(sym, "fn", sym, false);
                try self.lowerer.emit("    // Link symbol {s} to WASM export\n", .{sym});
            }
        }
    }

    // ==========================================
    // Declare (external function)
    // ==========================================

    fn parseDeclare(self: *Parser) anyerror!void {
        try self.expect(.keyword_declare);
        try self.expect(.keyword_function);

        const func_name_tok = self.current;
        try self.expect(.identifier);
        const func_name = self.tokenText(func_name_tok);

        try self.expect(.l_paren);

        var params = std.ArrayList(struct { name: []const u8, type_name: []const u8 }).init(self.allocator);
        defer params.deinit();

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const p_name_tok = self.current;
            try self.expect(.identifier);
            const p_name = self.tokenText(p_name_tok);

            try self.expect(.colon);

            const p_type_tok = self.current;
            try self.expect(.identifier);
            const p_type = self.tokenText(p_type_tok);

            try params.append(.{ .name = p_name, .type_name = p_type });
            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);

        var ret_type: []const u8 = "void";
        if (try self.accept(.colon)) {
            const ret_type_tok = self.current;
            if (self.current.tag == .keyword_void) {
                ret_type = "void";
                try self.advance();
            } else {
                try self.expect(.identifier);
                ret_type = self.tokenText(ret_type_tok);
            }
        }
        _ = try self.accept(.semicolon);

        try self.lowerer.emit("    @extern {s}(", .{func_name});
        for (params.items, 0..) |p, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}: ptr", .{p.name});
        }
        try self.lowerer.emit(") -> {s}\n", .{ret_type});

        try self.scope_manager.declareVar(func_name, "fn", func_name, false);
    }

    // ==========================================
    // Identifier statement (assignment, call, etc.)
    // ==========================================




    /// Lower a template literal to an SA-ASM string slice.
    ///
    /// An SA-ASM string is a `{ptr, len}` slice, not a literal: a string cannot
    /// be written as an operand. A literal is therefore materialised as a
    /// file-scope `@const NAME = utf8:"..."` data constant, then assembled into
    /// a slice with a 16-byte stack slot (this is what `SLICE_NEW` expands to).
    ///
    /// Templates with `${...}` interpolation additionally need the value
    /// rendered to text (`@sa_fmt_i64_into`) and the chunks joined
    /// (`@sa_string_concat`, which yields a bare pointer with no companion
    /// length). That path is not implemented yet and is reported as a
    /// diagnostic rather than emitting a `concat` instruction, which is not an
    /// SA mnemonic.
    fn parseTemplateLiteral(self: *Parser) anyerror![]const u8 {
        const raw = self.currentText();

        if (self.current.tag != .template_end) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "error: interpolated template literals are not yet lowerable to SA-ASM (needs @sa_fmt_i64_into to render values and @sa_string_concat to join chunks)",
                .{},
            );
            try self.errors.append(.{
                .line = self.current.line,
                .col = self.current.col,
                .message = msg,
            });
            // The CLI surfaces parser diagnostics on stderr via this channel;
            // `self.errors` is only consumed programmatically.
            std.debug.print("error:{d}:{d}: {s}\n", .{ self.current.line, self.current.col, msg });
            return error.UnsupportedTemplateLiteral;
        }

        // Strip the surrounding backticks; the lexer spans both.
        var text = raw;
        if (text.len >= 2 and text[0] == '`' and text[text.len - 1] == '`') {
            text = text[1 .. text.len - 1];
        }

        const const_id = self.nextLabelId();
        const const_name = try std.fmt.allocPrint(self.allocator, "SC_{d}", .{const_id});
        try self.lowerer.emitConst(const_name, text);

        // Leave template mode: the literal is fully consumed, so re-prime both
        // tokens from the normal lexer rather than promoting a stale
        // template-mode lookahead.
        self.template_lexer_mode = false;
        self.lexer.interp_expr_open = false;
        // `peek` was already primed by the `advance` that moved `current` onto
        // this literal, so consume that token instead of reading two fresh
        // ones. Re-lexing here skipped a token: a `}` closing an object
        // literal vanished, and the literal's enclosing scope was never closed.
        self.current = self.peek;
        self.peek = self.lexer.next();

        // 16-byte slice slot: {ptr at +0, len at +8}. This mirrors what
        // `SLICE_NEW` expands to, but uses `alloc` rather than `stack_alloc` so
        // the slice can be bound to a variable: a stack allocation cannot
        // escape its function ("StackEscape"), and callers routinely store the
        // result. Being heap-owned, it is released with `!` like any other
        // owned register.
        const slice_reg = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 16\n", .{slice_reg});
        try self.lowerer.emit("    store {s} + 0, &{s} as ptr\n", .{ slice_reg, const_name });
        try self.lowerer.emit("    store {s} + 8, {d} as u64\n", .{ slice_reg, text.len });

        return slice_reg;
    }

    /// Parse arrow function body and emit closure callback + context
    fn parseArrowBody(self: *Parser) anyerror![]const u8 {
        const cb_id = self.nextLabelId();
        const cb_name = try std.fmt.allocPrint(self.allocator, "@closure_callback_{d}", .{cb_id});

        // Scan body to find captured variables from outer scope
        var captures = std.ArrayList(scope_mod.Variable).init(self.allocator);
        defer captures.deinit();

        // Parse the body in a new scope to find references
        if (self.current.tag == .l_brace) {
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;

            // Scan tokens inside the braces
            var depth: u32 = 1;
            try self.advance(); // skip {
            while (depth > 0 and self.current.tag != .eof) {
                if (self.current.tag == .l_brace) depth += 1;
                if (self.current.tag == .r_brace) {
                    depth -= 1;
                    if (depth == 0) break;
                }
                if (self.current.tag == .identifier) {
                    const name = self.currentText();
                    if (self.scope_manager.lookup(name)) |v| {
                        var already = false;
                        for (captures.items) |c| {
                            if (std.mem.eql(u8, c.name, name)) {
                                already = true;
                                break;
                            }
                        }
                        if (!already) {
                            try captures.append(v.*);
                        }
                    }
                }
                try self.advance();
            }

            // Restore parser state
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
        }

        // Calculate context size
        var ctx_size: u32 = 0;
        for (captures.items) |cap| {
            var cap_size: u32 = 8;
            var cap_align: u32 = 8;
            try getTypeSizeAndAlign(cap.type_name, &cap_size, &cap_align);
            ctx_size = alignTo(ctx_size, cap_align);
            ctx_size += cap_size;
        }

        // Emit callback function
        try self.lowerer.emit("{s}(ctx: ptr):\n", .{cb_name});
        try self.scope_manager.enterScope();

        var offset: u32 = 0;
        for (captures.items) |cap| {
            var cap_size: u32 = 8;
            var cap_align: u32 = 8;
            try getTypeSizeAndAlign(cap.type_name, &cap_size, &cap_align);
            offset = alignTo(offset, cap_align);

            const sa_type = if (std.mem.eql(u8, cap.type_name, "i32") or std.mem.eql(u8, cap.type_name, "u32") or std.mem.eql(u8, cap.type_name, "f64"))
                cap.type_name
            else
                "ptr";

            try self.lowerer.emit("    {s} = load ctx + {d} as {s}\n", .{ cap.name, offset, sa_type });
            try self.scope_manager.declareVar(cap.name, cap.type_name, cap.name, false);
            offset += cap_size;
        }

        // Parse body statements
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance();
        }

        // Release context in callback
        try self.lowerer.emit("    !ctx\n", .{});
        try self.scope_manager.exitScope(self.lowerer);

        // Align final ctx size to max alignment (8 for ptr)
        if (ctx_size > 0 and captures.items.len > 0) {
            ctx_size = alignTo(ctx_size, 8);
        }

        // In the parent scope, allocate and populate context
        if (ctx_size > 0) {
            try self.lowerer.emit("    ctx = alloc {d}\n", .{ctx_size});

            offset = 0;
            for (captures.items) |cap| {
                var cap_size: u32 = 8;
                var cap_align: u32 = 8;
                try getTypeSizeAndAlign(cap.type_name, &cap_size, &cap_align);
                offset = alignTo(offset, cap_align);

                const store_type = if (std.mem.eql(u8, cap.type_name, "i32") or std.mem.eql(u8, cap.type_name, "u32") or std.mem.eql(u8, cap.type_name, "f64"))
                    cap.type_name
                else
                    "ptr";

                try self.lowerer.emit("    store ctx + {d}, {s} as {s}\n", .{ offset, cap.name, store_type });
                offset += cap_size;
            }
        }

        // Store context for caller to pick up as ^ctx
        self.last_arrow_ctx = "^ctx";

        return cb_name;
    }


    fn lookupStdlib(self: *Parser, name: []const u8) ?StdlibEntry {
        // First try dynamic stdlib entries (from parseImport)
        for (self.stdlib.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        // Fallback: static lookup for known stdlib functions
        const static_map = [_]struct { ts: []const u8, sa: []const u8, str_args: []const u8 }{
            .{ .ts = "readFile", .sa = "sa_fs_read_file", .str_args = "1" },
            .{ .ts = "writeFile", .sa = "sa_fs_write_file", .str_args = "1" },
            .{ .ts = "open", .sa = "sa_fs_file_open", .str_args = "1" },
            .{ .ts = "create", .sa = "sa_fs_file_create", .str_args = "1" },
            .{ .ts = "close", .sa = "sa_fs_file_close", .str_args = "" },
            .{ .ts = "remove", .sa = "sa_fs_remove_file", .str_args = "1" },
            .{ .ts = "mkdir", .sa = "sa_fs_make_dir", .str_args = "1" },
            .{ .ts = "tcpConnect", .sa = "sa_net_tcp_connect", .str_args = "1" },
            .{ .ts = "tcpListen", .sa = "sa_net_tcp_listener_bind", .str_args = "1" },
            .{ .ts = "tcpAccept", .sa = "sa_net_tcp_listener_accept", .str_args = "" },
            .{ .ts = "tcpRead", .sa = "sa_net_tcp_stream_read", .str_args = "" },
            .{ .ts = "tcpWrite", .sa = "sa_net_tcp_stream_write", .str_args = "" },
            .{ .ts = "tcpClose", .sa = "sa_net_tcp_stream_close", .str_args = "" },
        };
        inline for (static_map) |entry| {
            if (std.mem.eql(u8, name, entry.ts)) {
                return StdlibEntry{ .name = entry.ts, .sa_primitive = entry.sa, .string_args = entry.str_args };
            }
        }
        return null;
    }

    /// Whether `primitive` is declared `-> u64!` and therefore hands back a
    /// two-field value rather than a bare integer.
    ///
    /// Every consumer of a TCP handle -- `sa_net_tcp_listener_accept`,
    /// `sa_net_tcp_stream_read` and friends -- declares the handle as a plain
    /// `u64`, so the two-field result has to be reduced to field 0 before it is
    /// stored. `sa_fs_read_file` is deliberately absent: it is also `-> u64!`,
    /// but the buffer accessors take that value whole as a `ptr`, so unwrapping
    /// it would be wrong.
    fn isFallibleHandle(primitive: []const u8) bool {
        const fallible_handles = [_][]const u8{
            "sa_net_tcp_connect",
            "sa_net_tcp_listener_bind",
            "sa_net_tcp_listener_accept",
        };
        for (fallible_handles) |name| {
            if (std.mem.eql(u8, primitive, name)) return true;
        }
        return false;
    }

    /// Emit a stdlib call with string arg transformation.
    /// For string args, load ptr+len from the string struct.
    fn emitStdlibCall(
        self: *Parser,
        result_dest: ?[]const u8, // null = bare call, non-null = assign to temp
        entry: StdlibEntry,
        args: std.ArrayList([]const u8),
    ) anyerror!void {
        // Build transformed arg list
        var transformed = std.ArrayList([]const u8).init(self.allocator);
        defer transformed.deinit();

        for (args.items, 0..) |arg, idx| {
            // Check if this arg index is a string arg (1-based in string_args)
            var is_str = false;
            for (entry.string_args) |c| {
                if (c - '1' == idx) {
                    is_str = true;
                    break;
                }
            }

            if (is_str) {
                if (arg.len > 0 and arg[0] == '"') {
                    // String literal argument.
                    //
                    // An SA-ASM string is a {ptr, len} slice and a literal is
                    // not a valid operand, so the text becomes a file-scope
                    // `@const` data constant and the slice is built from it.
                    const str_temp = try self.newTemp();
                    const str_len = if (arg.len >= 2) arg.len - 2 else 0;
                    const lit_const = try std.fmt.allocPrint(self.allocator, "SA_STR_{d}", .{self.nextLabelId()});
                    try self.lowerer.emitConst(lit_const, arg[1 .. arg.len - 1]);
                    try self.lowerer.emit("    {s} = alloc 16\n", .{str_temp});
                    try self.lowerer.emit("    store {s} + 0, &{s} as ptr\n", .{ str_temp, lit_const });
                    try self.lowerer.emit("    store {s} + 8, {d} as u64\n", .{ str_temp, str_len });
                    const ptr_temp = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ptr_temp, str_temp });
                    const len_temp = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len_temp, str_temp });
                    // A primitive declared `&path: ptr` expects the pointer
                    // passed by reference, i.e. `&reg` at the call site.
                    try transformed.append(try std.fmt.allocPrint(self.allocator, "&{s}", .{ptr_temp}));
                    try transformed.append(len_temp);
                } else {
                    // Variable: expand string struct to (ptr, len) pair
                    const ptr_temp = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ptr_temp, arg });
                    const len_temp = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len_temp, arg });
                    try transformed.append(try std.fmt.allocPrint(self.allocator, "&{s}", .{ptr_temp}));
                    try transformed.append(len_temp);
                }
            } else {
                try transformed.append(arg);
            }
        }

        // `sa_net_tcp_listener_bind` is declared `-> u64!`, and a fallible return
        // is materialised by the backend as a two-field value. Every consumer of
        // that handle -- `sa_net_tcp_listener_accept` in particular -- takes a
        // plain `u64`, so handing it the struct is rejected as a parameter type
        // mismatch. The handle is field 0, so the call is made into a scratch
        // register and the field is extracted into the destination. This lives
        // here rather than at the call sites because the statement and the
        // expression paths both funnel through this function, and an earlier
        // attempt to special-case each path separately missed the fact that
        // `lookupStdlib` is consulted before either of them.
        // `&buf` in the stdlib table is a placeholder, not an SA operand: no
        // symbol named `buf` exists, so emitting it verbatim produced
        // `error: InvalidOperand`. A read/write out-parameter needs a real
        // address, so a scratch region is allocated here and its address is
        // passed instead. The allocation is emitted before the call is opened,
        // because the call text is already partially written by that point.
        var buf_ref: ?[]const u8 = null;
        if (std.mem.indexOf(u8, entry.extra_args, "&buf") != null) {
            const scratch = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc 4096\n", .{scratch});
            buf_ref = scratch;
        }

        const returns_handle_pair = isFallibleHandle(entry.sa_primitive);
        var pair_scratch: ?[]const u8 = null;
        if (returns_handle_pair and result_dest != null) {
            const scratch = try self.newTemp();
            pair_scratch = scratch;
            try self.lowerer.emit("    {s} = call @{s}(", .{ scratch, entry.sa_primitive });
        } else if (result_dest) |dest| {
            try self.lowerer.emit("    {s} = call @{s}(", .{ dest, entry.sa_primitive });
        } else {
            try self.lowerer.emit("    call @{s}(", .{entry.sa_primitive});
        }
        for (transformed.items, 0..) |arg, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}", .{arg});
        }
        // SA-ASM has fixed callee arity, so supply the parameters the primitive
        // declares beyond the caller's own arguments.
        if (entry.extra_args.len > 0) {
            if (transformed.items.len > 0) try self.lowerer.emit(", ", .{});
            if (buf_ref) |scratch| {
                const rest = std.mem.trim(u8, entry.extra_args["&buf".len..], " ,");
                if (rest.len > 0) {
                    try self.lowerer.emit("&{s}, {s}", .{ scratch, rest });
                } else {
                    try self.lowerer.emit("&{s}", .{scratch});
                }
            } else {
                try self.lowerer.emit("{s}", .{entry.extra_args});
            }
        }
        // Append arrow closure context if present
        if (self.last_arrow_ctx) |ctx_arg| {
            if (transformed.items.len > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}", .{ctx_arg});
            self.last_arrow_ctx = null;
        }
        try self.lowerer.emit(")\n", .{});

        if (pair_scratch) |scratch| {
            try self.lowerer.emit("    {s} = load {s} + 0 as i64\n", .{ result_dest.?, scratch });
        }
    }

    fn parseIdentifierStatement(self: *Parser) anyerror!void {
        const name_tok = self.current;
        try self.expect(.identifier);
        const name = self.tokenText(name_tok);

        if (self.current.tag == .l_paren) {
            // Bare function call
            try self.expect(.l_paren);
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                const arg = try self.parseExpression();
                try args.append(arg);
                _ = try self.accept(.comma);
            }
            try self.expect(.r_paren);
            _ = try self.accept(.semicolon);

            // Check if this is a stdlib function
            if (self.lookupStdlib(name)) |entry| {
                try self.emitStdlibCall(null, entry, args);
            } else {
                try self.lowerer.emit("    call @{s}(", .{name});
                for (args.items, 0..) |arg, idx| {
                    if (idx > 0) try self.lowerer.emit(", ", .{});
                    try self.lowerer.emit("{s}", .{arg});
                    if (idx == 0) {
                        if (self.last_arrow_ctx) |ctx_arg| {
                            try self.lowerer.emit(", {s}", .{ctx_arg});
                            self.last_arrow_ctx = null;
                        }
                    }
                }
                try self.lowerer.emit(")\n", .{});
            }
        } else if (self.current.tag == .dot) {
            // Assignment via property access: obj.field = val
            var left_name = name;
            while (self.current.tag == .dot) {
                try self.advance();
                const member_tok = self.current;
                try self.expect(.identifier);
                const member_name = self.tokenText(member_tok);

                const v = self.scope_manager.lookup(left_name) orelse return error.UndefinedVariable;
                const layout = self.layout_table.find(v.type_name) orelse return error.TypeIsNotAnInterface;

                var found_field: ?Field = null;
                for (layout.fields.items) |f| {
                    if (std.mem.eql(u8, f.name, member_name)) {
                        found_field = f;
                        break;
                    }
                }
                const field = found_field orelse return error.UnknownField;

                if (self.current.tag == .equal) {
                    // store obj.field = expr
                    try self.advance();
                    const val = try self.parseExpression();
                    _ = try self.accept(.semicolon);
                    try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ left_name, field.offset, val, saTypeOf(field.type_name) });
                    return;
                } else {
                    // Load intermediate. The temp is retagged from `i32` to
                    // the field type so a further `.x` resolves the layout
                    // through it (`o.inner.a`).
                    const temp_name = try self.newTemp();
                    if (self.scope_manager.lookup(temp_name)) |tv| {
                        self.allocator.free(tv.type_name);
                        tv.type_name = try self.allocator.dupe(u8, field.type_name);
                    }
                    const sa_type = if (std.mem.eql(u8, field.type_name, "i32") or std.mem.eql(u8, field.type_name, "u32") or std.mem.eql(u8, field.type_name, "f64"))
                        field.type_name
                    else
                        "ptr";
                    try self.lowerer.emit("    {s} = load {s} + {d} as {s}\n", .{ temp_name, left_name, field.offset, sa_type });
                    left_name = temp_name;
                }
            }
        } else if (self.current.tag == .l_bracket) {
            // Array indexing: arr[i] = val or arr[i]
            try self.advance();
            const index = try self.parseExpression();
            try self.expect(.r_bracket);

            if (self.current.tag == .equal) {
                try self.advance();
                const val = try self.parseExpression();
                _ = try self.accept(.semicolon);
                // `name` is a slice, so the element address comes from the
                // header's data pointer at +0, not from the header itself.
                const base_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ base_temp, name });
                // Compute offset: index * 4 (default i32)
                const off_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = mul {s}, 4\n", .{ off_temp, index });
                const addr_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, base_temp, off_temp });
                // `store` requires an explicit byte offset, like `load`.
                try self.lowerer.emit("    store {s} + 0, {s} as i32\n", .{ addr_temp, val });
            }
        } else if (self.current.tag == .equal) {
            // Simple assignment: x = expr, or x = { ... } for a struct.
            try self.advance();
            if (self.current.tag == .l_brace) {
                // Struct literal reassignment reuses the existing allocation;
                // the layout comes from the variable's declared type, so no
                // new annotation is needed at the assignment site.
                const v = self.scope_manager.lookup(name) orelse {
                    std.debug.print("error:{d}:{d}: assignment to undefined variable '{s}'\n", .{
                        name_tok.line,
                        name_tok.col,
                        name,
                    });
                    return error.UndefinedVariable;
                };
                const layout = self.layout_table.find(v.type_name) orelse {
                    std.debug.print("error:{d}:{d}: struct literal assigned to non-interface variable '{s}'\n", .{
                        self.current.line,
                        self.current.col,
                        name,
                    });
                    return error.TypeIsNotAnInterface;
                };
                try self.advance(); // consume {
                try self.parseStructLiteralFields(name, layout);
                _ = try self.accept(.semicolon);
                return;
            }
            const val = try self.parseExpression();
            _ = try self.accept(.semicolon);

            // A register-to-register assignment moves its source. Inside a
            // conditional that is unsound when the source is an outer
            // variable: it ends up Consumed on the taken arm and Active on
            // the other, and the verifier's merge at the join point reports
            // PhiStateConflict. This is the common "conditionally update an
            // accumulator" shape, so emit a non-moving copy there instead.
            // The copy goes through a fresh temp: computing directly into
            // `name` (`total = add t, 0`) redefines a live register.
            // Arithmetic temps are arm-local and symmetric on both arms, so
            // the plain move below stays for them.
            if (self.branch_depth > 0 and self.scope_manager.isOuterVariable(val)) {
                const tmp = try self.newTemp();
                try self.lowerer.emit("    {s} = add {s}, 0\n", .{ tmp, val });
                self.scope_manager.markConsumed(tmp);
                try self.emitMove(name, tmp);
                return;
            }

            // A register-to-register assignment moves the source: emitting
            // `!` for it afterwards is a use-after-move error. Compound right
            //-hand sides (arithmetic, calls) leave their operands live and are
            // released normally.
            try self.emitMove(name, val);
        } else if (self.current.tag == .plus_plus) {
            try self.advance();
            _ = try self.accept(.semicolon);
            const temp = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ temp, name });
            try self.releaseOwnedIfLive(name);
            try self.lowerer.emit("    {s} = {s}\n", .{ name, temp });
            self.scope_manager.markConsumed(temp);
            self.markRebound(name);
        } else if (self.current.tag == .minus_minus) {
            try self.advance();
            _ = try self.accept(.semicolon);
            const temp = try self.newTemp();
            try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ temp, name });
            try self.releaseOwnedIfLive(name);
            try self.lowerer.emit("    {s} = {s}\n", .{ name, temp });
            self.scope_manager.markConsumed(temp);
            self.markRebound(name);
        } else {
            std.debug.print("error:{d}:{d}: unexpected statement starting with identifier '{s}'\n", .{
                name_tok.line,
                name_tok.col,
                name,
            });
            return error.InvalidStatement;
        }
    }

    // ==========================================
    // Expression (Pratt parser)
    // ==========================================

    fn parseExpression(self: *Parser) anyerror![]const u8 {
        return self.parseExpressionWithPrecedence(.lowest);
    }

    fn parseExpressionWithPrecedence(self: *Parser, min_prec: Precedence) anyerror![]const u8 {
        var left = try self.parsePrefix();

        while (true) {
            const prec = getPrecedence(self.current.tag);
            if (@intFromEnum(prec) <= @intFromEnum(min_prec)) break;
            left = try self.parseInfix(left, prec);
        }

        return left;
    }

    fn parsePrefix(self: *Parser) anyerror![]const u8 {
        switch (self.current.tag) {
            .number => {
                const tok = self.current;
                try self.advance();
                return self.tokenText(tok);
            },
            .string => {
                const tok = self.current;
                try self.advance();
                return self.tokenText(tok);
            },
            .template_start => {
                return try self.parseTemplateLiteral();
            },
            // A template with no interpolation lexes straight to `template_end`,
            // because the closing backtick is found before any `${`.
            .template_end => {
                return try self.parseTemplateLiteral();
            },

            .identifier => {
                const tok = self.current;
                try self.advance();
                return self.tokenText(tok);
            },
            .keyword_true => {
                try self.advance();
                return "1";
            },
            .keyword_false => {
                try self.advance();
                return "0";
            },
            .keyword_null, .keyword_undefined => {
                try self.advance();
                return "null";
            },
            .l_paren => {
                try self.advance();
                // Detect arrow function: () => { ... } or (params) => { ... }
                if (self.current.tag == .r_paren and self.peek.tag == .arrow) {
                    // Empty params arrow function
                    try self.advance(); // )
                    try self.advance(); // =>
                    return try self.parseArrowBody();
                }
                // Check if it's (identifier, ...) => pattern
                if (self.current.tag == .identifier and self.peek.tag == .comma) {
                    // Could be arrow with multiple params - check for => after )
                    // For now, treat as grouping expression
                }
                const expr = try self.parseExpression();
                try self.expect(.r_paren);
                // Check for arrow: (expr) => 
                if (self.current.tag == .arrow) {
                    // (single_param) => { ... }
                    try self.advance(); // =>
                    return try self.parseArrowBody();
                }
                return expr;
            },
            .minus => {
                try self.advance();
                const operand = try self.parseExpressionWithPrecedence(.product);
                const temp_name = try self.newTemp();
                try self.lowerer.emit("    {s} = neg {s}\n", .{ temp_name, operand });
                return temp_name;
            },
            .bang => {
                try self.advance();
                const operand = try self.parseExpressionWithPrecedence(.product);
                const temp_name = try self.newTemp();
                // SA's `not` only accepts a parameter as its operand; on a
                // register bound by an ordinary assignment it is rejected with
                // InvalidOperand. `eq x, 0` is the same test and is accepted in
                // every position, so logical negation lowers to that instead.
                try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ temp_name, operand });
                return temp_name;
            },
            .ampersand => {
                // Address-of: &var
                try self.advance();
                const tok = self.current;
                try self.expect(.identifier);
                const name = self.tokenText(tok);
                const temp_name = try self.newTemp();
                try self.lowerer.emit("    {s} = &{s}\n", .{ temp_name, name });
                return temp_name;
            },
            .caret => {
                // Move: ^var
                try self.advance();
                const tok = self.current;
                try self.expect(.identifier);
                const name = self.tokenText(tok);
                const temp_name = try self.newTemp();
                try self.lowerer.emit("    {s} = ^{s}\n", .{ temp_name, name });
                return temp_name;
            },
            .l_bracket => {
                // Array literal in expression context
                try self.advance();
                var vals = std.ArrayList([]const u8).init(self.allocator);
                defer vals.deinit();
                while (self.current.tag != .r_bracket and self.current.tag != .eof) {
                    const val = try self.parseExpression();
                    try vals.append(val);
                    _ = try self.accept(.comma);
                }
                try self.expect(.r_bracket);
                const temp_name = try self.newTemp();
                const arr_size = @as(u32, @intCast(vals.items.len)) * 4;
                try self.lowerer.emit("    {s} = alloc {d}\n", .{ temp_name, arr_size });
                for (vals.items, 0..) |val, idx| {
                    const off = @as(u32, @intCast(idx)) * 4;
                    try self.lowerer.emit("    store {s} + {d}, {s} as i32\n", .{ temp_name, off, val });
                }
                return temp_name;
            },
            .keyword_await => {
                try self.advance();
                const operand = try self.parseExpression();
                const temp_name = try self.newTemp();
                try self.lowerer.emit("    {s} = await {s}\n", .{ temp_name, operand });
                return temp_name;
            },
            else => {
                std.debug.print("error:{d}:{d}: unexpected token in expression: {s}\n", .{
                    self.current.line,
                    self.current.col,
                    @tagName(self.current.tag),
                });
                return error.UnexpectedTokenInExpression;
            },
        }
    }

    fn parseInfix(self: *Parser, left: []const u8, precedence: Precedence) anyerror![]const u8 {
        const tag = self.current.tag;

        // Arithmetic: + - * / %
        if (tag == .plus or tag == .minus or tag == .star or tag == .slash or tag == .percent) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);

            const temp_name = try self.newTemp();

            const sa_op = switch (tag) {
                .plus => "add",
                .minus => "sub",
                .star => "mul",
                .slash => "div",
                // SA-ASM spells the signed comparison/remainder forms
                // `slt`/`sle`/`sgt`/`sge`/`srem`. Plain `lt`/`le`/`gt`/`ge`/
                // `mod` are not mnemonics, so the assembler rejected them.
                .percent => "srem",
                else => unreachable,
            };

            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Comparison: == != < > <= >=
        if (tag == .equal_equal or tag == .bang_equal or tag == .less or tag == .greater or tag == .less_equal or tag == .greater_equal) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);

            const temp_name = try self.newTemp();

            const sa_op = switch (tag) {
                .equal_equal => "eq",
                .bang_equal => "ne",
                .less => "slt",
                .greater => "sgt",
                .less_equal => "sle",
                .greater_equal => "sge",
                else => unreachable,
            };

            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Logical: && ||
        if (tag == .amp_amp or tag == .pipe_pipe) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);

            const temp_name = try self.newTemp();

            const sa_op: []const u8 = if (tag == .amp_amp) "and" else "or";
            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Member access: obj.field
        if (tag == .dot) {
            try self.advance();
            const member_tok = self.current;
            try self.expect(.identifier);
            const member_name = self.tokenText(member_tok);

            if (self.current.tag == .l_paren) {
                // Method call: obj.method(args)
                if (std.mem.eql(u8, member_name, "slice")) {
                    try self.expect(.l_paren);
                    const start_val = try self.parseExpression();
                    try self.expect(.comma);
                    const end_val = try self.parseExpression();
                    try self.expect(.r_paren);

                    const slice_id = self.nextLabelId();
                    const slice_var_name = try std.fmt.allocPrint(self.allocator, "slice_{d}", .{slice_id});

                    try self.lowerer.emit("    // Zero-copy String Slice: {s}.slice({s}, {s})\n", .{ left, start_val, end_val });
                    try self.lowerer.emit("    {s} = alloc 16\n", .{slice_var_name});
                    try self.lowerer.emit("    orig_ptr = load {s} + 0 as ptr\n", .{left});
                    try self.lowerer.emit("    new_ptr = ptr_add orig_ptr, {s}\n", .{start_val});
                    try self.lowerer.emit("    store {s} + 0, new_ptr as ptr\n", .{slice_var_name});
                    try self.lowerer.emit("    slice_len = sub {s}, {s}\n", .{ end_val, start_val });
                    try self.lowerer.emit("    store {s} + 8, slice_len as u32\n", .{slice_var_name});
                    return slice_var_name;
                } else if (std.mem.eql(u8, member_name, "length")) {
                    // string.length property
                    const temp_name = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 8 as u32\n", .{ temp_name, left });
                    return temp_name;
                } else {
                    return error.UnknownMethod;
                }
            } else {
                // Property access
                const v = self.scope_manager.lookup(left) orelse {
                    std.debug.print("error:{d}:{d}: property access on undefined variable '{s}'\n", .{
                        member_tok.line, member_tok.col, left,
                    });
                    return error.UndefinedVariable;
                };

                const layout = self.layout_table.find(v.type_name) orelse return error.TypeIsNotAnInterface;

                var found_field: ?Field = null;
                for (layout.fields.items) |f| {
                    if (std.mem.eql(u8, f.name, member_name)) {
                        found_field = f;
                        break;
                    }
                }
                const field = found_field orelse return error.UnknownField;

                // The temp is retagged from `i32` to the field type so a
                // further `.x` resolves the layout through it (`o.inner.a`).
                const temp_name = try self.newTemp();
                if (self.scope_manager.lookup(temp_name)) |tv| {
                    self.allocator.free(tv.type_name);
                    tv.type_name = try self.allocator.dupe(u8, field.type_name);
                }

                const sa_type = if (std.mem.eql(u8, field.type_name, "i32") or std.mem.eql(u8, field.type_name, "u32") or std.mem.eql(u8, field.type_name, "f64"))
                    field.type_name
                else
                    "ptr";

                try self.lowerer.emit("    {s} = load {s} + {d} as {s}\n", .{ temp_name, left, field.offset, sa_type });
                return temp_name;
            }
        }

        // Array indexing: arr[i]
        if (tag == .l_bracket) {
            try self.advance();
            const index = try self.parseExpression();
            try self.expect(.r_bracket);

            // `left` is a slice, so the element base is the data pointer stored
            // in the header at +0, not the header itself.
            const base_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ base_temp, left });

            const off_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, 4\n", .{ off_temp, index });

            const addr_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, base_temp, off_temp });

            const val_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as i32\n", .{ val_temp, addr_temp });
            return val_temp;
        }

        // Postfix increment/decrement: i++ / i--
        // Lowers to `t = add i, 1` + `i = t`: the temp is moved into the
        // target, so it must be marked consumed — otherwise the
        // function-exit walk emits `!t` on paths where this definition
        // never ran (UnknownRegister). Same release-before-rebind as the
        // statement-level `i++` below.
        if (tag == .plus_plus or tag == .minus_minus) {
            try self.advance();
            const temp_name = try self.newTemp();
            const sa_op: []const u8 = if (tag == .plus_plus) "add" else "sub";
            try self.lowerer.emit("    {s} = {s} {s}, 1\n", .{ temp_name, sa_op, left });
            try self.releaseOwnedIfLive(left);
            try self.lowerer.emit("    {s} = {s}\n", .{ left, temp_name });
            self.scope_manager.markConsumed(temp_name);
            self.markRebound(left);
            return temp_name;
        }

        // Function call: name(args)
        if (tag == .l_paren) {
            try self.advance();
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                const arg = try self.parseExpression();
                try args.append(arg);
                _ = try self.accept(.comma);
            }
            try self.expect(.r_paren);

            const temp_name = try self.newTemp();

            // Check if this is a stdlib function
            if (self.lookupStdlib(left)) |entry| {
                try self.emitStdlibCall(temp_name, entry, args);
            } else if (std.mem.eql(u8, left, "alloc") and args.items.len == 1) {
                // Heap allocation is a primitive instruction, not a function:
                // `alloc(N)` must emit `t = alloc N`, because there is no
                // `@alloc` symbol to call and the assembler rejects it with
                // "callee is not declared".
                try self.lowerer.emit("    {s} = alloc {s}\n", .{ temp_name, args.items[0] });
            } else {
                try self.lowerer.emit("    {s} = call @{s}(", .{ temp_name, left });
                for (args.items, 0..) |arg, idx| {
                    if (idx > 0) try self.lowerer.emit(", ", .{});
                    try self.lowerer.emit("{s}", .{arg});
                }
                if (self.last_arrow_ctx) |ctx_arg| {
                    if (args.items.len > 0) try self.lowerer.emit(", ", .{});
                    try self.lowerer.emit("{s}", .{ctx_arg});
                    self.last_arrow_ctx = null;
                }
                try self.lowerer.emit(")\n", .{});
            }
            return temp_name;
        }

        return error.UnexpectedInfixToken;
    }
};

pub const Precedence = enum(u8) {
    lowest = 0,
    @"or" = 1,        // ||
    @"and" = 2,       // &&
    comparison = 3,   // == != < > <= >=
    sum = 4,          // + -
    product = 5,      // * / %
    prefix = 6,       // - !
    call = 7,         // . [] ()
};

fn getPrecedence(tag: lexer_mod.Token.Tag) Precedence {
    return switch (tag) {
        .pipe_pipe => .@"or",
        .amp_amp => .@"and",
        .equal_equal, .bang_equal, .less, .greater, .less_equal, .greater_equal => .comparison,
        .plus, .minus => .sum,
        .star, .slash, .percent => .product,
        .plus_plus, .minus_minus => .call,
        .dot, .l_paren, .l_bracket => .call,
        else => .lowest,
    };
}
