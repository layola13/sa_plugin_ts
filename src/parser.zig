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

pub const ArrowParam = struct {
    name: []const u8,
    type_name: []const u8,
    /// `?` marker or `= default` (same convention as MethodParam).
    optional: bool = false,
    /// Duplicated source slice of a `= default` initializer (see StoredParam).
    default_src: ?[]const u8 = null,
};

pub const MethodParam = struct {
    name: []const u8,
    type_name: []const u8,
    /// `constructor(public x: T)`: the parameter declares a field that the
    /// pre-scan registers in the layout and the ctor body stores.
    is_property: bool = false,
    /// `?` marker or `= default`: missing args pad with `0` at `new`.
    optional: bool = false,
    /// Duplicated source slice of a `= default` initializer (see StoredParam).
    default_src: ?[]const u8 = null,
};

/// Stored constructor/method parameter for call padding and `extends`
/// forwarder emission.
pub const StoredParam = struct {
    name: []const u8,
    type_name: []const u8,
    optional: bool = false,
    /// Duplicated source slice of a `= default` initializer, replayed in the
    /// callee prologue when the call site pads the argument with `0`
    /// (`traverse(this.rootNode)` replays `[]`; `new MinHeap()` replays the
    /// default comparator arrow). Null when no default was declared.
    default_src: ?[]const u8 = null,
};

/// Trait-downgrade method signature: emit name is `Class_method`, and void
/// methods must lower to a bare `call` (assigning a void result is rejected).
/// `ret` carries the declared return type (`MapEntry[]`, `void`, ...) so
/// call results retag from the default `i32` (without it `entry.key` on a
/// `Method[]` result fails and silently aborts the whole caller).
pub const MethodSig = struct {
    is_void: bool = false,
    ret: ?[]const u8 = null,
    /// Positional parameter types for forwarder emission and `new` arity
    /// padding (`new TreeNode(data)` vs a 3-param ctor with 2 optional).
    params: ?[]StoredParam = null,
    /// Duplicated `{ ... }` body source for `extends` copy-down: a child
    /// re-parses each inherited body with itself as `current_class`, so
    /// virtual calls (`this.initMap()`) resolve to the child's override.
    /// Null for abstract/no-body signatures.
    body_src: ?[]const u8 = null,
};

pub const ArrowAlias = struct {
    cb: []const u8,
    ctx: []const u8,
    /// Declared arity for short-call padding (`traverse(this.rootNode)`
    /// pads the defaulted `array` with `0`; the callee prologue replays the
    /// default). Calls passing fewer than `required` args are loud errors.
    arity: u8 = 0,
    required: u8 = 0,
    /// Top-level capture-free arrows lower as plain named SA functions
    /// (`@f`, no trailing `ctx` param). Calls to a plain alias must not
    /// append a context register.
    plain: bool = false,
    /// Self-recursive reference (`const traverse = ...` pre-registered while
    /// its body parses): calls pass the callback's own `ctx` and skip the
    /// trailing borrow release (the shared exit sequence releases it).
    self_call: bool = false,
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
    /// Class currently being parsed (method bodies bind `this` to it).
    current_class: ?[]const u8 = null,
    /// Layout-collection pass: register class/interface field layouts without
    /// emitting any method bodies (resolves forward references like
    /// `HashMap` using `MapEntry` before its declaration).
    collect_only: bool = false,
    /// `Class.method` -> `@C_method` signatures (trait downgrade: static dispatch).
    class_methods: std.StringHashMap(MethodSig) = undefined,
    /// `Class` -> `Trait` conformance (`implements` clause).
    class_traits: std.StringHashMap(void) = undefined,
    /// `Child` -> `Parent` (`extends` clause, trait downgrade: copy-down).
    class_parent: std.StringHashMap([]const u8) = undefined,
    /// `Child.method` -> defining class for copy-down aliases (the shared
    /// body emits once as `@Parent_method`; dispatch must use that name).
    method_emit_owner: std.StringHashMap([]const u8) = undefined,
    /// `Class.field` -> duplicated initializer source (`= <src>`). Field
    /// initializers cannot emit at class scope (no `this`, and straight-line
    /// emission there glues into the previous function); they replay at the
    /// start of explicit ctors, or in a synthesized default ctor when the
    /// class declares none. Filed during the member loop (single recorder).
    field_inits: std.StringHashMap([]const u8) = undefined,
    /// Expected element type for a dynamic `new Array(n)` / `Array(n)` whose
    /// length is a runtime value: set from the assignment target's declared
    /// element type while lowering the right-hand side (`this.queue = ...`
    /// with `queue: T[]` allocates 8-byte slots, `size: number[]` 4-byte).
    array_elem_hint: ?[]const u8 = null,
    /// `const name = <arrow>` being lowered: the next `parseArrowBody` reached
    /// pre-registers `name` so the body can call itself recursively
    /// (`const traverse = (...) => { ...; traverse(...); ... }`). Consumed by
    /// that arrow, cleared by `parseLet` when no arrow follows.
    pending_arrow_bind: ?[]const u8 = null,
    /// Captures of the most recently lowered arrow (for the captureless-only
    /// `fn`-slot rule: only captureless callbacks may flow into `fn`-typed
    /// fields/params, whose indirect calls pass a fresh empty context).
    last_arrow_captures: u32 = 0,
    /// Arity of the most recently lowered arrow (short-call padding).
    last_arrow_arity: u8 = 0,
    last_arrow_required: u8 = 0,
    /// Names (`@closure_callback_N`) of captureless callbacks, callable
    /// through a bare function pointer with an empty context.
    captureless_cb: std.StringHashMap(void) = undefined,
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
    /// Nesting depth inside arrow closure callbacks. A value-return inside an
    /// arrow body is diagnosed loudly: void callbacks cannot carry a value and
    /// value callbacks declare `-> i32`.
    arrow_depth: u32 = 0,
    /// Names of enclosing arrow-callback parameters currently in scope.
    /// An unannotated param defaults to `i32`, which hides an array element
    /// (`row` in `mat.map((row) => row.map(...))`); the dot-dispatch chain
    /// consults this set so array methods on such params still reach
    /// `lowerArrayMethodCall` (scalar-element assumption, documented).
    arrow_param_names: std.ArrayList([]const u8) = undefined,
    /// Declared return type (TS spelling) per function name, recorded when
    /// a `function` or top-level arrow signature is lowered. Expression-
    /// level call sites retag the result temp from it, so `const c = f()`
    /// on an array-returning function indexes correctly instead of
    /// defaulting to `i32` (wild pointers on `c[0][0]`).
    fn_ret: std.StringHashMap([]const u8) = undefined,
    /// Element type stashed by the `Array<T>` generic-call prefix (see
    /// `parseInfix`); consumed once by the `Array(n)` branch below.
    array_call_elem: ?[]const u8 = null,
    /// Whether the innermost arrow callback declares `-> i32`. Saved and
    /// restored around each arrow body so nested arrows do not clobber it.
    arrow_value_cb: bool = false,
    /// Scope depth at the innermost arrow callback's entry (before its own
    /// scope is opened). Release walks inside the callback stop here so they
    /// never free the parent function's registers from inside the out-of-line
    /// callback body.
    arrow_base_depth: usize = 0,
    /// `let f = (x) => ...` aliases: `f` is not a register but the callback
    /// name plus its context move. Direct calls to `f` lower to the callback;
    /// passing `f` as an argument expands to `cb, ctx`.
    arrow_aliases: std.StringHashMap(ArrowAlias) = undefined,
    /// Symbols imported from `.wasm` modules. Calls to them get an
    /// arity-matched `@extern` in the header at the first call site, so the
    /// verifier accepts the callee (linking still needs the real `.wasm`).
    /// An explicit `declare function` for the same name wins and suppresses
    /// the synthetic declaration.
    wasm_syms: std.StringHashMap(void) = undefined,
    /// Symbols imported from `.wit` files. `@wit_import` is not valid SA-ASM
    /// (the assembler rejects it with ForbiddenSyntax even at top level), so
    /// both the import and any call are refused loudly with a diagnostic.
    wit_syms: std.StringHashMap(void) = undefined,
    /// Names with an explicit `declare function` signature on file.
    declared_externs: std.StringHashMap(void) = undefined,
    /// Directory of the entry file: relative TS imports (`./x`, `../y`)
    /// resolve against it, SLA whole-program style. Set by the host from
    /// the input path; tests leave the default (cwd).
    base_dir: []const u8 = ".",
    /// Scope depth that counts as "top level" for arrow lowering: `0` for
    /// the entry file (so `scopeDepth() == 1` is top-level), reset around
    /// each relatively-imported file (which enters its own scope first).
    /// Without this an imported file's top-level arrows lower as closures
    /// (context-carrying callbacks) instead of plain named functions, and
    /// callers pass a context the callee never declares.
    import_base_depth: usize = 0,
    /// Resolved import paths already parsed (cycle/diamond guard).
    imported_files: std.StringHashMap(void) = undefined,
    /// Depth inside `async function` bodies, with the innermost Tokio-style
    /// ready-future value type. An `async function f(): T` returns a
    /// `future<T>` handle (a 16-byte `{state, value}` heap struct mirroring
    /// SLA's ReadyFuture); `await` unwraps and consumes it, and inside an
    /// `async function` a pending handle propagates to the caller (SLA's
    /// `ready_pending_state_return_if_async`). Created futures are always
    /// ready; the pending path covers consumed handles and executor-driven
    /// ones. `async function main` is driven by a synthesized sync `@main`.
    async_depth: u32 = 0,
    async_inner: ?[]const u8 = null,
    /// Async function names (duped) to their inner value type (duped).
    async_fns: std.StringHashMap([]const u8) = undefined,
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
            .async_fns = std.StringHashMap([]const u8).init(allocator),
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
        parser_inst.arrow_aliases = std.StringHashMap(ArrowAlias).init(allocator);
        parser_inst.wasm_syms = std.StringHashMap(void).init(allocator);
        parser_inst.wit_syms = std.StringHashMap(void).init(allocator);
        parser_inst.declared_externs = std.StringHashMap(void).init(allocator);
        parser_inst.class_methods = std.StringHashMap(MethodSig).init(allocator);
        parser_inst.class_traits = std.StringHashMap(void).init(allocator);
        parser_inst.class_parent = std.StringHashMap([]const u8).init(allocator);
        parser_inst.method_emit_owner = std.StringHashMap([]const u8).init(allocator);
        parser_inst.field_inits = std.StringHashMap([]const u8).init(allocator);        parser_inst.captureless_cb = std.StringHashMap(void).init(allocator);
        parser_inst.imported_files = std.StringHashMap(void).init(allocator);
        parser_inst.arrow_param_names = std.ArrayList([]const u8).init(allocator);
        parser_inst.fn_ret = std.StringHashMap([]const u8).init(allocator);

        // Pre-register `async function` signatures (name -> inner value
        // type) so forward calls still tag future-typed results: demos put
        // `main` first and callees later, and the single-pass body walk
        // would otherwise see an untagged call temp, making `await` pass
        // the raw handle through as a value. Only the map is pre-filled;
        // bodies still parse in order.
        {
            var scan = lexer_mod.Lexer{ .source = source };
            var tok = scan.next();
            while (tok.tag != .eof) {
                if (tok.tag == .keyword_async) {
                    const t_fn = scan.next();
                    const t_name = scan.next();
                    if (t_fn.tag == .keyword_function and t_name.tag == .identifier) {
                        const name = source[t_name.start .. t_name.start + t_name.len];
                        var t = scan.next();
                        if (t.tag == .l_paren) {
                            var depth: u32 = 1;
                            while (depth > 0) {
                                t = scan.next();
                                if (t.tag == .eof) break;
                                if (t.tag == .l_paren) depth += 1;
                                if (t.tag == .r_paren) depth -= 1;
                            }
                            t = scan.next();
                            var inner: []const u8 = "i32";
                            if (t.tag == .colon) {
                                t = scan.next();
                                if (t.tag == .identifier) {
                                    const type_start = t.start;
                                    var type_end = t.start + t.len;
                                    var t2 = scan.next();
                                    if (t2.tag == .less) {
                                        var gdepth: u32 = 1;
                                        while (gdepth > 0) {
                                            t2 = scan.next();
                                            if (t2.tag == .eof) break;
                                            if (t2.tag == .less) gdepth += 1;
                                            if (t2.tag == .greater) gdepth -= 1;
                                        }
                                        type_end = t2.start + t2.len;
                                    }
                                    const raw = source[type_start..type_end];
                                    if (!std.mem.eql(u8, raw, "void")) inner = raw;
                                }
                            }
                            const key: []const u8 = if (std.mem.eql(u8, name, "main")) "async_main" else name;
                            if (!parser_inst.async_fns.contains(key)) {
                                try parser_inst.async_fns.put(try allocator.dupe(u8, key), try allocator.dupe(u8, inner));
                            }
                            tok = scan.next();
                            continue;
                        }
                    }
                }
                tok = scan.next();
            }
        }

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
        var ait = self.async_fns.iterator();
        while (ait.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.async_fns.deinit();
        var alit = self.arrow_aliases.iterator();
        while (alit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }
        self.arrow_aliases.deinit();
        var wsit = self.wasm_syms.iterator();
        while (wsit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }
        self.wasm_syms.deinit();
        var witit = self.wit_syms.iterator();
        while (witit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }
        self.wit_syms.deinit();
        var imit = self.imported_files.iterator();
        while (imit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }
        self.imported_files.deinit();
        var deit = self.declared_externs.iterator();
        while (deit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }
        self.declared_externs.deinit();
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
                .semicolon, .r_brace, .keyword_function, .keyword_let, .keyword_const, .keyword_var, .keyword_if, .keyword_while, .keyword_for, .keyword_return => return,
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

    fn isArrayType(t: []const u8) bool {
        return t.len >= 2 and t[t.len - 2] == '[' and t[t.len - 1] == ']';
    }

    /// Strip one `[]` pair: `MapEntry[][]` -> `MapEntry[]`.
    /// Returns null when the type is not an array.
    fn stripOneArray(t: []const u8) ?[]const u8 {
        if (!isArrayType(t)) return null;
        return t[0 .. t.len - 2];
    }

    /// Element type of a slice: one level stripped, or `i32` for non-arrays
    /// (keeps the old 4-byte scalar behavior as fallback).
    fn elementTypeOf(arr_type: []const u8) []const u8 {
        return stripOneArray(arr_type) orelse "i32";
    }

    fn getTypeSizeAndAlign(type_name: []const u8, size: *u32, align_val: *u32) anyerror!void {
        // Any `T[]...` is a slice handle (ptr-sized), regardless of element type.
        if (type_name.len >= 2 and type_name[type_name.len - 2] == '[' and type_name[type_name.len - 1] == ']') {
            size.* = 8;
            align_val.* = 8;
        } else if (std.mem.eql(u8, type_name, "i32") or std.mem.eql(u8, type_name, "u32")) {
            size.* = 4;
            align_val.* = 4;
        } else if (std.mem.eql(u8, type_name, "number") or std.mem.eql(u8, type_name, "boolean")) {
            // TypeScript `number`/`boolean` are the subset's 32-bit integers:
            // every arithmetic, comparison and indexing instruction already
            // assumes 4-byte stride (`mul i, 4`, `as i32`). Leaving them at
            // the 8-byte fallback made `number[]` literals store 8-byte
            // elements that indexed loads read back shifted (observed as
            // `[0,0,0,3,5,8]` after an in-place insertion sort).
            size.* = 4;
            align_val.* = 4;
        } else if (std.mem.eql(u8, type_name, "f64")) {
            size.* = 8;
            align_val.* = 8;
        } else if (std.mem.eql(u8, type_name, "ptr")) {
            size.* = 8;
            align_val.* = 8;
        } else if (std.mem.eql(u8, type_name, "u8") or std.mem.eql(u8, type_name, "i8")) {
            // `for (const ch of str)` binds bytes: 1-byte stride keeps
            // string iteration packed (the 8-byte fallback read 8 chars
            // per step and skipped most of the input).
            size.* = 1;
            align_val.* = 1;
        } else if (std.mem.eql(u8, type_name, "u16") or std.mem.eql(u8, type_name, "i16")) {
            size.* = 2;
            align_val.* = 2;
        } else if (std.mem.eql(u8, type_name, "i64") or std.mem.eql(u8, type_name, "u64")) {
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
            if (self.scope_manager.lookup(name)) |tv| tv.is_temp = true;
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
        // `number`/`boolean` lower as `i32` (see getTypeSizeAndAlign): the
        // backend has no TS-number width, and emitting `ptr` for them
        // miscompiled every `number[]` literal/index pair.
        if (std.mem.eql(u8, ts_type, "number") or std.mem.eql(u8, ts_type, "boolean")) return "i32";
        return "ptr";
    }

    /// Whether a tracked type is a ready-future handle (`future<T>`).
    fn isFutureType(t: []const u8) bool {
        return std.mem.startsWith(u8, t, "future<") and std.mem.endsWith(u8, t, ">");
    }

    /// The value type inside `future<T>`.
    fn futureInner(t: []const u8) []const u8 {
        return t["future<".len .. t.len - 1];
    }

    fn futureTypeName(allocator: std.mem.Allocator, inner: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "future<{s}>", .{inner});
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
        try self.lowerer.emitBranchTo(try self.condReg(cond), fallthrough, false_label);
        try self.lowerer.emitLabel(fallthrough);
        return fallthrough;
    }

    /// Branch conditions must be registers: constant-folded guards (`typeof`
    /// checks, `Number.isInteger` on i32, string-literal `===`) produce bare
    /// `"1"`/`"0"` text, and `br 0 -> ...` is rejected with UnknownRegister.
    /// Materialise such literals into a register (`add c, 0`); registers pass
    /// through untouched.
    fn condReg(self: *Parser, cond: []const u8) anyerror![]const u8 {
        if (std.mem.eql(u8, cond, "0") or std.mem.eql(u8, cond, "1")) {
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ t, cond });
            return t;
        }
        return cond;
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

    /// Release live owned registers owned by the innermost arrow callback
    /// only (scopes deeper than `arrow_base_depth`). The callback body is
    /// parsed inside the parent's scopes, so the unscoped walk would free
    /// the parent's registers from inside the out-of-line callback.
    fn releaseArrowLiveExcept(self: *Parser, keep: ?[]const u8) anyerror!void {
        try self.refreshDominators();
        try self.scope_manager.releaseScopesDeeperThanExcept(self.lowerer, self.arrow_base_depth, keep);
    }

    fn releaseArrowLive(self: *Parser) anyerror!void {
        try self.releaseArrowLiveExcept(null);
    }

    /// Emit cleanups for an `await` pending-propagation return (`return fut`
    /// on the `L_await_pend` branch), mirroring sa_plugin_sla's
    /// `emitAwaitPendingCleanups`: every live owned register except the
    /// returned handle is released on that path only.
    ///
    /// Unlike `releaseLiveRegistersExcept`, the `is_released` flags are
    /// snapshotted and restored: the pending `!`s execute only if the branch
    /// is taken, while the ready path (and the function-exit walk) still
    /// owns those registers. Marking them released here would leak them on
    /// the ready path.
    fn emitPendingReturnCleanups(self: *Parser, keep: []const u8) anyerror!void {
        var saved = std.ArrayList(bool).init(self.allocator);
        defer saved.deinit();
        for (self.scope_manager.scopes.items) |*scope| {
            for (scope.variables.items) |*v| {
                try saved.append(v.is_released);
            }
        }
        try self.refreshDominators();
        try self.scope_manager.releaseAllOwnedExcept(self.lowerer, keep);
        var idx: usize = 0;
        for (self.scope_manager.scopes.items) |*scope| {
            for (scope.variables.items) |*v| {
                v.is_released = saved.items[idx];
                idx += 1;
            }
        }
    }

    // ==========================================
    // Top-level parse
    // ==========================================

    pub fn parse(self: *Parser) anyerror!void {
        // Forward-reference collection pass: register every top-level
        // class/interface field layout before lowering any method body,
        // so `new LaterClass` / `x: LaterClass` inside earlier classes
        // resolves (Talgo defines `MapEntry` after `HashMap`).
        {
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            const saved_tpl = self.template_lexer_mode;
            self.collect_only = true;
            while (self.current.tag != .eof) {
                if (self.current.tag == .keyword_class) {
                    self.parseClass() catch {
                        self.skipToSync();
                    };
                } else if (self.current.tag == .keyword_interface) {
                    self.parseInterface() catch {
                        self.skipToSync();
                    };
                } else if (self.current.tag == .identifier and std.mem.eql(u8, self.currentText(), "export")) {
                    try self.advance();
                    // `export abstract class`: the modifier sits between.
                    while (self.current.tag == .keyword_abstract) try self.advance();
                    if (self.current.tag == .keyword_class) {
                        self.parseClass() catch {
                            self.skipToSync();
                        };
                    } else if (self.current.tag == .keyword_interface) {
                        self.parseInterface() catch {
                            self.skipToSync();
                        };
                    }
                } else {
                    try self.advance();
                }
            }
            self.collect_only = false;
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
            self.template_lexer_mode = saved_tpl;
        }
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

    /// Array destructuring assignment: `[a, b] = [x, y]` (swap idiom).
    /// Declaration form (`const [a, b] = ...`) stays with parseLet; here
    /// every LHS name must already exist. RHS expressions all evaluate
    /// into fresh temps first, so self-swaps read the old values.
    /// Array destructuring assignment: `[a, b] = [x, y]` (swap idiom),
    /// also with member/indexed targets (`[this.h[i], k] = [...]`).
    /// Declaration form (`const [a, b] = ...`) stays with parseLet; plain
    /// identifier targets must already exist. Addresses evaluate before
    /// the RHS freezes, stores happen after (swap-safe).
    fn parseArrayDestructure(self: *Parser) anyerror!void {
        const Target = union(enum) {
            ident: []const u8,
            member: struct { base: []const u8, off: u32, sa_ty: []const u8 },
            indexed: struct { header: []const u8, sa_elem: []const u8, esz: u32, index: []const u8 },
        };
        try self.expect(.l_bracket);
        var targets = std.ArrayList(Target).init(self.allocator);
        defer targets.deinit();
        while (true) {
            // Base: identifier or `this`.
            var base: []const u8 = undefined;
            if (self.current.tag == .keyword_this) {
                base = "this";
                try self.advance();
            } else {
                const ntok = self.current;
                try self.expect(.identifier);
                base = self.tokenText(ntok);
            }
            // Optional `.field` segments (one level: `this.heap`).
            var seg: ?[]const u8 = null;
            var fld_off: u32 = 0;
            var fld_ty: []const u8 = "i32";
            while (self.current.tag == .dot) {
                try self.advance();
                const stok = self.current;
                try self.expect(.identifier);
                if (seg != null) {
                    _ = try self.refuseAt(
                        "error: destructuring target nesting too deep",
                        .{},
                        error.DestructuringTooDeep,
                    );
                    return error.DestructuringTooDeep;
                }
                seg = self.tokenText(stok);
                const lv = self.scope_manager.lookup(base) orelse {
                    std.debug.print("error:{d}:{d}: property access on undefined variable '{s}'\n", .{ stok.line, stok.col, base });
                    return error.UndefinedVariable;
                };
                const layout = self.layout_table.find(lv.type_name) orelse return error.TypeIsNotAnInterface;
                var found = false;
                for (layout.fields.items) |fld| {
                    if (std.mem.eql(u8, fld.name, seg.?)) {
                        fld_off = fld.offset;
                        fld_ty = fld.type_name;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnknownField;
                base = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ base, seg.? });
            }
            if (self.current.tag == .l_bracket) {
                // Indexed target: `arr[i]` or `this.heap[i]`.
                try self.advance();
                const index = try self.parseExpression();
                try self.expect(.r_bracket);
                // Resolve the slice header register and element stride.
                var header: []const u8 = undefined;
                var elem: []const u8 = "i32";
                if (seg) |_| {
                    // Member base: load the header through the object.
                    const dot = std.mem.indexOf(u8, base, ".") orelse return error.UndefinedVariable;
                    const obj = base[0..dot];
                    if (self.scope_manager.lookup(obj) == null) return error.UndefinedVariable;
                    header = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + {d} as ptr\n", .{ header, obj, fld_off });
                    elem = elementTypeOf(fld_ty);
                } else {
                    if (self.scope_manager.lookup(base)) |bv| elem = elementTypeOf(bv.type_name);
                    header = base;
                }
                var esz: u32 = 4;
                var eal: u32 = 4;
                try getTypeSizeAndAlign(elem, &esz, &eal);
                try targets.append(.{ .indexed = .{ .header = header, .sa_elem = saTypeOf(elem), .esz = esz, .index = index } });
            } else if (seg) |_| {
                // Plain member target: `this.x`.
                const dot = std.mem.indexOf(u8, base, ".") orelse return error.UndefinedVariable;
                const obj = base[0..dot];
                try targets.append(.{ .member = .{ .base = obj, .off = fld_off, .sa_ty = saTypeOf(fld_ty) } });
            } else {
                try targets.append(.{ .ident = base });
            }
            if (!(try self.accept(.comma))) break;
            if (self.current.tag == .r_bracket) break;
        }
        try self.expect(.r_bracket);
        try self.expect(.equal);
        try self.expect(.l_bracket);
        var tmps = std.ArrayList([]const u8).init(self.allocator);
        defer tmps.deinit();
        while (true) {
            const e = try self.parseExpression();
            // Freeze each RHS value with a pure move (`t = e`): the later
            // stores must not move a register an earlier element still
            // needs (`[a, b] = [b, a]`). Moves consume: mark the source so
            // the exit walk does not release it again (UseAfterMove). A
            // copy (`t = add e, 0`) would instead leave an arithmetic temp
            // whose bare move trips the exit walk, so pure moves it is.
            // EXCEPTION: inside a loop body a loop-carried scalar source
            // (`while (b) { [a, b] = [b, a % b]; }`) must stay live for the
            // back-edge merge, so snapshot it with a copy instead (same
            // rule as emitMove's loop-carried scalars). Non-scalars keep
            // the move path.
            const t = try self.newTemp();
            var copied = false;
            if (self.loop_depth > 0) {
                if (self.scope_manager.lookup(e)) |sv| {
                    const tn = sv.type_name;
                    const scalar = std.mem.eql(u8, tn, "i32") or std.mem.eql(u8, tn, "u32") or
                        std.mem.eql(u8, tn, "number") or std.mem.eql(u8, tn, "boolean") or
                        std.mem.eql(u8, tn, "i64") or std.mem.eql(u8, tn, "u64");
                    if (scalar) {
                        try self.lowerer.emit("    {s} = add {s}, 0\n", .{ t, e });
                        copied = true;
                    }
                }
            }
            if (!copied) {
                try self.lowerer.emit("    {s} = {s}\n", .{ t, e });
                if (self.scope_manager.lookup(e)) |_| self.scope_manager.markConsumed(e);
            }
            try tmps.append(t);
            if (!(try self.accept(.comma))) break;
            if (self.current.tag == .r_bracket) break;
        }
        try self.expect(.r_bracket);
        _ = try self.accept(.semicolon);
        if (targets.items.len != tmps.items.len) {
            std.debug.print("error:{d}:{d}: destructuring arity mismatch: {d} targets but {d} values\n", .{
                self.current.line, self.current.col, targets.items.len, tmps.items.len,
            });
            return error.DestructuringArityMismatch;
        }
        for (targets.items, tmps.items) |tg, t| {
            switch (tg) {
                .ident => |n| {
                    if (self.scope_manager.lookup(n) == null) {
                        std.debug.print("error:{d}:{d}: assignment to undefined variable '{s}'\n", .{
                            self.current.line, self.current.col, n,
                        });
                        return error.UndefinedVariable;
                    }
                    try self.emitMove(n, t);
                },
                .member => |m| {
                    try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ m.base, m.off, t, m.sa_ty });
                },
                .indexed => |ix| {
                    const data = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, ix.header });
                    const off = try self.newTemp();
                    try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off, ix.index, ix.esz });
                    const addr = try self.newTemp();
                    try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, off });
                    try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ addr, t, ix.sa_elem });
                },
            }
        }
    }

    fn parseStatement(self: *Parser) anyerror!void {
        switch (self.current.tag) {
            .l_bracket => try self.parseArrayDestructure(),
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
            .keyword_class => try self.parseClass(),
            .keyword_let => try self.parseLet(),
            .keyword_const => try self.parseLet(),
            .keyword_var => try self.parseLet(),
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
            .keyword_this => try self.parseIdentifierStatement(),
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
            .keyword_super => {
                // `super(args);` / `super.m(args);` as a statement: value
                // discarded (the primary path emits the parent call).
                _ = try self.parseExpression();
                _ = try self.accept(.semicolon);
            },
            .identifier => {
                // Check for export keyword
                if (std.mem.eql(u8, self.currentText(), "export")) {
                    try self.advance(); // skip export
                    // `export abstract class`: the modifier sits between.
                    while (self.current.tag == .keyword_abstract) try self.advance();
                    // Parse the exported declaration
                    if (self.current.tag == .keyword_function) {
                        try self.parseFunction();
                    } else if (self.current.tag == .keyword_let or self.current.tag == .keyword_const or self.current.tag == .keyword_var) {
                        try self.parseLet();
                    } else if (self.current.tag == .keyword_interface) {
                        try self.parseInterface();
                    } else if (self.current.tag == .keyword_class) {
                        try self.parseClass();
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
        // Accept keyword type atoms (`void`/`null`/`undefined`) as well as
        // identifiers (`number`, `string`, `K`, ...).
        var type_name: []const u8 = "i32";
        // Parenthesized type (`(T | U)[]`, `(T)`): when the paren holds a
        // plain type (no `name:` parameter marker), parse it as a grouped
        // type and let the shared suffix logic below handle `[]`/unions.
        // Otherwise it is a function type (`(a: T) => R`; see below).
        if (self.current.tag == .l_paren) {
            const s_lex = self.lexer;
            const s_cur = self.current;
            const s_peek = self.peek;
            try self.advance(); // (
            const head_is_type = self.current.tag == .identifier or
                self.current.tag == .keyword_void or self.current.tag == .keyword_null or
                self.current.tag == .keyword_undefined;
            const next_is_type_cont = self.peek.tag == .pipe or self.peek.tag == .pipe_pipe or
                self.peek.tag == .ampersand or self.peek.tag == .amp_amp or
                self.peek.tag == .r_paren or self.peek.tag == .l_bracket or
                self.peek.tag == .greater;
            self.lexer = s_lex;
            self.current = s_cur;
            self.peek = s_peek;
            if (head_is_type and next_is_type_cont) {
                try self.advance(); // (
                type_name = try self.parseTypeName();
                try self.expect(.r_paren);
                // Fall through to the generic/`[]`/union suffix logic below
                // with the grouped base. A jump is unavailable; duplicate
                // the small tail by continuing inline: generics cannot start
                // here (a `<` after `)` would be a comparison), so only the
                // array/union tails apply.
                var array_depth: usize = 0;
                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                    try self.advance();
                    try self.advance();
                    array_depth += 1;
                }
                var kept = type_name;
                var first_is_nullish = std.mem.eql(u8, kept, "null") or std.mem.eql(u8, kept, "undefined");
                while (self.current.tag == .pipe or self.current.tag == .pipe_pipe or
                    self.current.tag == .ampersand or self.current.tag == .amp_amp)
                {
                    try self.advance();
                    var arm: []const u8 = "i32";
                    switch (self.current.tag) {
                        .identifier => {
                            const a_tok = self.current;
                            try self.expect(.identifier);
                            arm = self.tokenText(a_tok);
                        },
                        .keyword_void => {
                            try self.advance();
                            arm = "void";
                        },
                        .keyword_null => {
                            try self.advance();
                            arm = "null";
                        },
                        .keyword_undefined => {
                            try self.advance();
                            arm = "undefined";
                        },
                        else => break,
                    }
                    if (self.current.tag == .less) {
                        try self.advance();
                        var depth: usize = 1;
                        while (depth > 0 and self.current.tag != .eof) {
                            if (self.current.tag == .less) depth += 1;
                            if (self.current.tag == .greater) depth -= 1;
                            try self.advance();
                        }
                    }
                    while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                        try self.advance();
                        try self.advance();
                    }
                    const arm_nullish = std.mem.eql(u8, arm, "null") or std.mem.eql(u8, arm, "undefined");
                    if (first_is_nullish and !arm_nullish) {
                        kept = arm;
                        first_is_nullish = false;
                    }
                }
                type_name = kept;
                if (std.mem.indexOf(u8, type_name, "<")) |angle_idx| {
                    const base = type_name[0..angle_idx];
                    if (array_depth == 0) return base;
                    var out = base;
                    var i: usize = 0;
                    while (i < array_depth) : (i += 1) {
                        out = try std.fmt.allocPrint(self.allocator, "{s}[]", .{out});
                    }
                    return out;
                }
                if (array_depth == 0) return type_name;
                {
                    var out2 = type_name;
                    var j: usize = 0;
                    while (j < array_depth) : (j += 1) {
                        out2 = try std.fmt.allocPrint(self.allocator, "{s}[]", .{out2});
                    }
                    return out2;
                }
            }
        }
        // Function type (`(a: T, b: T) => boolean`, incl. parenthesized
        // callback params): parameters lower as their own registers, so only
        // the marker survives (ptr-sized slot, like an arrow alias).
        if (self.current.tag == .l_paren) {
            try self.advance();
            var fdepth: usize = 1;
            while (fdepth > 0 and self.current.tag != .eof) {
                switch (self.current.tag) {
                    .l_paren, .l_bracket, .l_brace => fdepth += 1,
                    .r_paren, .r_bracket, .r_brace => fdepth -= 1,
                    else => {},
                }
                try self.advance();
            }
            _ = try self.accept(.arrow);
            if (self.current.tag == .l_paren) {
                _ = try self.parseTypeName();
            } else if (self.current.tag == .identifier or self.current.tag == .keyword_void) {
                try self.advance();
            }
            return "fn";
        }
        // `add(word: string): this`: the receiver's own class.
        if (self.current.tag == .keyword_this) {
            try self.advance();
            if (self.current_class) |cc| return cc;
            return "ptr";
        }
        switch (self.current.tag) {
            .identifier => {
                const name_tok = self.current;
                try self.expect(.identifier);
                type_name = self.tokenText(name_tok);
            },
            .keyword_void => {
                try self.advance();
                type_name = "void";
            },
            .keyword_null => {
                try self.advance();
                type_name = "null";
            },
            .keyword_undefined => {
                try self.advance();
                type_name = "undefined";
            },
            else => {
                const name_tok2 = self.current;
                try self.expect(.identifier);
                type_name = self.tokenText(name_tok2);
            },
        }

        // Check for generic parameters: Type<Param>
        if (self.current.tag == .less) {
            // Could be generic type or comparison - peek ahead
            // For now, treat as generic if followed by identifier
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            try self.advance(); // skip <
            const is_type = self.current.tag == .identifier or
                self.current.tag == .keyword_void or
                self.current.tag == .keyword_null or
                self.current.tag == .keyword_undefined;
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;

            if (is_type) {
                try self.advance(); // skip <
                // Generic params may themselves carry `[]` / unions; consume
                // them structurally but keep only the base name for layout.
                var first_param: []const u8 = "";
                if (self.current.tag == .identifier) {
                    const param_tok = self.current;
                    try self.expect(.identifier);
                    first_param = self.tokenText(param_tok);
                } else {
                    const kw = self.current.tag;
                    try self.advance();
                    first_param = @tagName(kw);
                }
                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                    try self.advance();
                    try self.advance();
                }
                if (self.current.tag == .pipe or self.current.tag == .pipe_pipe or
                    self.current.tag == .ampersand or self.current.tag == .amp_amp)
                {
                    try self.advance();
                    if (self.current.tag == .identifier) {
                        try self.advance();
                    } else {
                        try self.advance();
                    }
                    while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                        try self.advance();
                        try self.advance();
                    }
                }
                // Handle multiple type params: Map<K, V>
                type_name = try std.fmt.allocPrint(self.allocator, "{s}<{s}", .{ type_name, first_param });
                while (try self.accept(.comma)) {
                    var next_param: []const u8 = "";
                    if (self.current.tag == .identifier) {
                        const next_param_tok = self.current;
                        try self.expect(.identifier);
                        next_param = self.tokenText(next_param_tok);
                    } else {
                        const kw2 = self.current.tag;
                        try self.advance();
                        next_param = @tagName(kw2);
                    }
                    while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                        try self.advance();
                        try self.advance();
                    }
                    type_name = try std.fmt.allocPrint(self.allocator, "{s},{s}", .{ type_name, next_param });
                }
                try self.expect(.greater);
                type_name = try std.fmt.allocPrint(self.allocator, "{s}>", .{type_name});
            }
        }

        // Array type suffixes: `T[]`, `T[][]`, ...
        //
        // Every pair must be consumed here. Otherwise a declaration such as
        // `let arr: i32[] = [1, 2, 3]` (or `buckets: T[][]` with two pairs)
        // leaves `[` as the current token and the following `expect(.equal)`
        // fails, silently dropping the entire statement while still exiting
        // 0. In the class member loop a leftover `[` desyncs the whole class:
        // `expect(.identifier)` throws, the class is abandoned, and every
        // later method lowers as top-level (`skipping unexpected token
        // colon`, `property access on undefined variable 'this'`).
        var array_depth: usize = 0;
        while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
            try self.advance(); // [
            try self.advance(); // ]
            array_depth += 1;
        }

        // Union / intersection tails: `V | null`, `string | undefined`, `A & B`.
        // Keep the first (non-null) arm for layout; `null`/`undefined` arms
        // only mark optionality in TS and lower as the same SA slot.
        var kept = type_name;
        var first_is_nullish = std.mem.eql(u8, kept, "null") or std.mem.eql(u8, kept, "undefined");
        while (self.current.tag == .pipe or self.current.tag == .pipe_pipe or
            self.current.tag == .ampersand or self.current.tag == .amp_amp)
        {
            try self.advance(); // | or &
            var arm: []const u8 = "i32";
            switch (self.current.tag) {
                .identifier => {
                    const a_tok = self.current;
                    try self.expect(.identifier);
                    arm = self.tokenText(a_tok);
                },
                .keyword_void => {
                    try self.advance();
                    arm = "void";
                },
                .keyword_null => {
                    try self.advance();
                    arm = "null";
                },
                .keyword_undefined => {
                    try self.advance();
                    arm = "undefined";
                },
                else => break,
            }
            // Skip generic args on the arm: `Array<string> | null`.
            if (self.current.tag == .less) {
                try self.advance();
                var depth: usize = 1;
                while (depth > 0 and self.current.tag != .eof) {
                    if (self.current.tag == .less) depth += 1;
                    if (self.current.tag == .greater) depth -= 1;
                    try self.advance();
                }
            }
            while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                try self.advance();
                try self.advance();
                // Only the kept arm owns `[]` pairs; a discarded arm's
                // brackets must not inflate the kept depth (`number[][] |
                // number[]` kept `number` + 2, not 2 + 1).
            }
            const arm_nullish = std.mem.eql(u8, arm, "null") or std.mem.eql(u8, arm, "undefined");
            if (first_is_nullish and !arm_nullish) {
                kept = arm;
                first_is_nullish = false;
            }
        }
        type_name = kept;

        // Return base name (strip generics) for layout table compatibility,
        // re-attaching any `[]` pairs so slices stay ptr-sized.
        if (std.mem.indexOf(u8, type_name, "<")) |angle_idx| {
            const base = type_name[0..angle_idx];
            if (array_depth == 0) return base;
            var out = base;
            var i: usize = 0;
            while (i < array_depth) : (i += 1) {
                out = try std.fmt.allocPrint(self.allocator, "{s}[]", .{out});
            }
            return out;
        }
        if (array_depth == 0) return type_name;
        {
            var out2 = type_name;
            var j: usize = 0;
            while (j < array_depth) : (j += 1) {
                out2 = try std.fmt.allocPrint(self.allocator, "{s}[]", .{out2});
            }
            return out2;
        }
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

            if (self.current.tag == .l_paren) {
                // Method signature (`name(params): Ret`): no layout field.
                // Skip the parameter list with nesting, then an optional
                // return annotation (`: void`, `: T | undefined`).
                try self.advance();
                var pd: usize = 1;
                while (pd > 0 and self.current.tag != .eof) {
                    switch (self.current.tag) {
                        .l_paren, .l_bracket, .l_brace => pd += 1,
                        .r_paren, .r_bracket, .r_brace => pd -= 1,
                        else => {},
                    }
                    try self.advance();
                }
                if (try self.accept(.colon)) {
                    if (self.current.tag == .keyword_void) {
                        try self.advance();
                    } else {
                        _ = try self.parseTypeName();
                    }
                }
                _ = try self.accept(.semicolon);
                _ = try self.accept(.comma);
                continue;
            }

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

    /// Skip TS member modifiers (`private/public/protected/readonly/static/override/abstract`).
    /// Returns true when at least one modifier was consumed: in a
    /// constructor parameter list that marks a parameter property
    /// (`constructor(public x: T)`), which declares a real layout field.
    fn skipModifiers(self: *Parser) anyerror!bool {
        var seen = false;
        while (true) {
            switch (self.current.tag) {
                .keyword_private, .keyword_public, .keyword_protected, .keyword_readonly, .keyword_static, .keyword_override, .keyword_abstract => {
                    try self.advance();
                    seen = true;
                },
                else => return seen,
            }
        }
    }

    /// Emit key for the class method table (`Class.method`).
    fn methodKey(self: *Parser, class_name: []const u8, method: []const u8) anyerror![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, method });
    }

    /// Parse one method/constructor parameter list into (name, type) pairs,
    /// skipping modifiers and `?` optional markers. Assumes cursor is on `(`.
    fn parseMethodParams(self: *Parser) anyerror!std.ArrayList(MethodParam) {
        var params = std.ArrayList(MethodParam).init(self.allocator);
        try self.expect(.l_paren);
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const had_mod = try self.skipModifiers();
            const p_tok = self.current;
            try self.expect(.identifier);
            const p_name = self.tokenText(p_tok);
            var p_optional = try self.accept(.question);
            var p_type: []const u8 = "i32";
            if (try self.accept(.colon)) {
                if (self.current.tag == .keyword_void) {
                    try self.advance();
                    p_type = "void";
                } else {
                    p_type = try self.parseTypeName();
                }
            }
            var p_default: ?[]const u8 = null;
            if (try self.accept(.equal)) {
                p_optional = true;
                // Save, don't evaluate: the default replays in the callee
                // prologue (per short call), where `this`/params are in scope.
                // Eager evaluation here would emit into the enclosing scope
                // (file scope for methods) and discard the value.
                p_default = try self.saveBalancedDefault();
            }
            try params.append(.{ .name = p_name, .type_name = p_type, .is_property = had_mod, .optional = p_optional, .default_src = p_default });
            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);
        return params;
    }

    /// Skip `<...>` generic args at a type position (arrow/callback params,
    /// `as` casts, return annotations). Call only where `<` unambiguously
    /// opens generics (right after a type name), never in value position
    /// where `<` could be a comparison.
    fn skipGenericArgs(self: *Parser) anyerror!void {
        if (self.current.tag != .less) return;
        try self.advance();
        var depth: usize = 1;
        while (depth > 0 and self.current.tag != .eof) {
            if (self.current.tag == .less) depth += 1;
            if (self.current.tag == .greater) depth -= 1;
            try self.advance();
        }
    }

    /// Save a parameter default value's source slice without emitting code.
    /// Returns a duplicated slice (`src[start..end]`) replayed later in the
    /// callee prologue when a call site pads the argument with `0`. Stops at
    /// a depth-zero `,`, `)`/`]`/`}` (never consumed), mirroring
    /// `skipBalancedDefault`.
    fn saveBalancedDefault(self: *Parser) anyerror!?[]const u8 {
        if (self.current.tag == .eof) return null;
        const src = self.lexer.source;
        const start: usize = @as(usize, self.current.start);
        var end: usize = start;
        var depth: usize = 0;
        scan: while (self.current.tag != .eof) {
            const t = self.current;
            switch (t.tag) {
                .l_paren, .l_bracket, .l_brace => {
                    depth += 1;
                    end = @as(usize, t.start) + @as(usize, t.len);
                    try self.advance();
                },
                .r_paren, .r_bracket, .r_brace => {
                    if (depth == 0) break :scan;
                    depth -= 1;
                    end = @as(usize, t.start) + @as(usize, t.len);
                    try self.advance();
                },
                .comma => {
                    if (depth == 0) break :scan;
                    end = @as(usize, t.start) + @as(usize, t.len);
                    try self.advance();
                },
                else => {
                    end = @as(usize, t.start) + @as(usize, t.len);
                    try self.advance();
                },
            }
        }
        if (end <= start or start >= src.len) return null;
        const clamped = @min(end, src.len);
        if (clamped <= start) return null;
        return try self.allocator.dupe(u8, src[start..clamped]);
    }

    /// Materialize a captureless callback as an `fn` value: a file-scope
    /// single-slot vtable plus a register holding the loaded code pointer.
    /// Callers pass/store the register and invoke via `call_indirect`
    /// with a fresh empty context. Capturing callbacks are loud errors
    /// (their context box cannot travel in a bare code pointer).
    fn fnPtrForCb(self: *Parser, cb_name: []const u8) anyerror![]const u8 {
        if (!self.captureless_cb.contains(cb_name)) {
            _ = try self.refuseAt(
                "error: capturing arrow as `fn` value: only captureless arrows lower as `fn` values",
                .{},
                error.CapturingArrowAsFnValue,
            );
            return error.CapturingArrowAsFnValue;
        }
        const vt_name = try std.fmt.allocPrint(self.allocator, "VT_{s}", .{cb_name[1..]});
        try self.lowerer.emitVTableFn(vt_name, cb_name);
        // Address-take the table, then load the slot: a bare
        // `load VT+0` verifies but the LLVM backend rejects it, and calling
        // the table address itself segfaults (probed end-to-end).
        const vt_reg = try self.newTemp();
        try self.lowerer.emit("    {s} = &{s}\n", .{ vt_reg, vt_name });
        const fpreg = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ fpreg, vt_reg });
        return fpreg;
    }

    /// Replay saved `= default` slices in the callee prologue: a parameter
    /// holding `0` (padded by a short call) is reassigned the default value.
    /// Runs after `this`/params are declared, so defaults may reference them
    /// (`index = this.size() - 1`) or construct values (`array = []`, including
    /// captureless default arrows). `0` standing in for a real argument is an
    /// accepted approximation (JS `undefined` has no SA spelling).
    fn emitDefaultPrologue(self: *Parser, params: anytype) anyerror!void {
        for (params) |prm| {
            const src = prm.default_src orelse continue;
            const miss = try self.newTemp();
            try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ miss, prm.name });
            const lid = self.nextLabelId();
            const l_def = try std.fmt.allocPrint(self.allocator, "L_def_{d}", .{lid});
            const l_have = try std.fmt.allocPrint(self.allocator, "L_have_{d}", .{lid});
            try self.lowerer.reserveLabel(l_def);
            try self.lowerer.reserveLabel(l_have);
            try self.lowerer.emitBranchTo(miss, l_def, l_have);
            try self.lowerer.emitLabel(l_def);
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            const saved_tpl = self.template_lexer_mode;
            const saved_ctx = self.last_arrow_ctx;
            self.last_arrow_ctx = null;
            self.lexer = lexer_mod.Lexer{ .source = src };
            self.current = self.lexer.next();
            self.peek = self.lexer.next();
            self.template_lexer_mode = false;
            const dv = try self.parseExpression();
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
            self.template_lexer_mode = saved_tpl;
            // A replayed arrow is an `fn` value (bare `@cb` is not a valid
            // operand): materialize the code pointer first, then move it
            // into the parameter. The parent-side context box is released
            // below; captureless-only, since indirect `fn` calls pass a
            // fresh empty context.
            var dv_val: []const u8 = dv;
            var dv_fpreg: ?[]const u8 = null;
            if (std.mem.startsWith(u8, dv, "@closure_callback_")) {
                dv_fpreg = try self.fnPtrForCb(dv);
                dv_val = dv_fpreg.?;
            }
            // Move semantics: the parameter is a live owned register on
            // entry, so a raw rebind is RegisterRedefinition.
            try self.emitMove(prm.name, dv_val);
            if (dv_fpreg != null) {
                if (self.last_arrow_ctx) |actx| {
                    const borrow = if (actx.len > 0 and actx[0] == '^') actx[1..] else actx;
                    try self.lowerer.emit("    !{s}\n", .{borrow});
                }
            }
            self.last_arrow_ctx = saved_ctx;
            try self.lowerer.emitJumpTo(l_have);
            try self.lowerer.emitLabel(l_have);
        }
    }

    /// Skip a parameter default value structurally without emitting code.
    /// The class pre-scan runs before any function body exists, so a real
    /// `parseExpression` there would emit stray top-level instructions
    /// (and arrow defaults would register callbacks twice).
    fn skipBalancedDefault(self: *Parser) anyerror!void {
        var depth: usize = 0;
        while (self.current.tag != .eof) {
            switch (self.current.tag) {
                .l_paren, .l_bracket, .l_brace => {
                    depth += 1;
                    try self.advance();
                },
                .r_paren, .r_bracket, .r_brace => {
                    if (depth == 0) return;
                    depth -= 1;
                    try self.advance();
                },
                .comma => {
                    if (depth == 0) return;
                    try self.advance();
                },
                else => try self.advance(),
            }
        }
    }

    /// Emit a class method or constructor body as `@C_name(this: ptr, ...)` /
    /// `@C_ctor(this: ptr, ...)`. Trait downgrade: `interface` = trait decl,
    /// `class` = struct layout + impl; methods are statically dispatched by
    /// the receiver's concrete type (vtable/dynamic dispatch is Phase 2).
    fn emitClassMethod(self: *Parser, class_name: []const u8, method_name: []const u8, is_ctor: bool) anyerror!void {
        var params = try self.parseMethodParams();
        defer params.deinit();
        var ret: ?[]const u8 = null;
        if (!is_ctor and try self.accept(.colon)) {
            if (self.current.tag == .keyword_void) {
                try self.advance();
                ret = "void";
            } else {
                ret = try self.parseTypeName();
            }
        }
        // Abstract / overload signature without a body: register, emit nothing.
        if (self.current.tag != .l_brace) {
            _ = try self.accept(.semicolon);
            return;
        }
        const emit_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, method_name });
        const key = try self.methodKey(class_name, method_name);
        const is_void = is_ctor or (ret != null and std.mem.eql(u8, ret.?, "void"));
        const ret_owned: ?[]const u8 = if (ret) |rt| try self.allocator.dupe(u8, rt) else null;
        var stored: ?[]StoredParam = null;
        if (params.items.len > 0) {
            const arr = try self.allocator.alloc(StoredParam, params.items.len);
            for (params.items, 0..) |p, idx| {
                arr[idx] = .{
                    .name = try self.allocator.dupe(u8, p.name),
                    .type_name = try self.allocator.dupe(u8, p.type_name),
                    .optional = p.optional,
                    .default_src = if (p.default_src) |ds| try self.allocator.dupe(u8, ds) else null,
                };
            }
            stored = arr;
        }
        // Body slice for `extends` copy-down (saved before the cursor moves
        // past `{`; abstract signatures without a body keep null).
        var body_src: ?[]const u8 = null;
        if (self.current.tag == .l_brace) {
            const bstart: usize = @as(usize, self.current.start);
            var bdepth: usize = 0;
            var bend: usize = bstart;
            const bsrc = self.lexer.source;
            var bpos: usize = bstart;
            // Byte-scan the balanced body (strings/comments may hold braces;
            // none of the Talgo bodies do, and a mismatch only costs a loud
            // re-parse error, never a silent miscompile).
            while (bpos < bsrc.len) {
                const c = bsrc[bpos];
                if (c == '{') bdepth += 1;
                if (c == '}') {
                    if (bdepth == 0) break;
                    bdepth -= 1;
                    if (bdepth == 0) {
                        bend = bpos + 1;
                        break;
                    }
                }
                bpos += 1;
            }
            if (bend > bstart) body_src = try self.allocator.dupe(u8, bsrc[bstart..bend]);
        }
        try self.class_methods.put(key, .{ .is_void = is_void, .ret = ret_owned, .params = stored, .body_src = body_src });
        try self.lowerer.emit("@{s}(this: ptr", .{emit_name});
        for (params.items) |p| {
            try self.lowerer.emit(", {s}: {s}", .{ p.name, saTypeOf(p.type_name) });
        }
        if (is_ctor) {
            try self.lowerer.emit("):\n", .{});
        } else if (ret) |rt| {
            if (!std.mem.eql(u8, rt, "void")) {
                try self.lowerer.emit(") -> {s}:\n", .{saTypeOf(rt)});
            } else {
                try self.lowerer.emit("):\n", .{});
            }
        } else {
            try self.lowerer.emit("):\n", .{});
        }
        self.lowerer.beginFunction();
        self.scope_manager.defer_releases = true;
        defer self.scope_manager.defer_releases = false;
        const saved_class = self.current_class;
        self.current_class = class_name;
        defer self.current_class = saved_class;
        try self.scope_manager.enterScope();
        try self.scope_manager.declareVar("this", class_name, "this", true);
        for (params.items) |p| {
            try self.scope_manager.declareVar(p.name, p.type_name, p.name, true);
        }
        try self.advance(); // {
        try self.scope_manager.enterScope();
        // Short-call defaults replay here (after the property stores, so a
        // padded `0` becomes the default while a passed value is kept).
        try self.emitDefaultPrologue(params.items);
        if (is_ctor) {
            // Constructor parameter properties (`constructor(public x: T)`):
            // the layout already holds the fields (pre-scan); bind them here
            // so `new C(v)` stores `v` instead of leaving zeroes.
            for (params.items) |p| {
                if (!p.is_property) continue;
                if (self.layout_table.find(class_name)) |layout| {
                    for (layout.fields.items) |f| {
                        if (std.mem.eql(u8, f.name, p.name)) {
                            try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ "this", f.offset, p.name, saTypeOf(f.type_name) });
                            break;
                        }
                    }
                }
            }
            // Field initializers replay before the body (body stores win).
            try self.replayFieldInits(class_name);
        }
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            try self.parseStatement();
        }
        if (!self.lowerer.isTerminated()) {
            try self.releaseLiveRegisters();
        }
        try self.scope_manager.exitScope(self.lowerer);
        try self.advance(); // }
        try self.scope_manager.exitScope(self.lowerer);
        const default_ret: []const u8 = if (is_ctor) "return" else if (ret) |rt| (if (std.mem.eql(u8, rt, "void")) "return" else "return 0") else "return";
        try self.lowerer.finishFunction(default_ret);
    }

    /// Parse `class C [extends B] [implements I, ...] { ... }`.
    /// Trait downgrade Phase 1: fields register a struct layout (like
    /// interfaces); methods lower to `@C_m(this: ptr, ...)` with static
    /// dispatch. Intra-file `extends` lowers via copy-down (parent layout
    /// prefixes, inherited methods alias, `super()`/`super.m()` static);
    /// body-less (abstract) own methods emit `panic(1)` stubs.
    fn parseClass(self: *Parser) anyerror!void {
        try self.expect(.keyword_class);
        const name_tok = self.current;
        try self.expect(.identifier);
        const class_name = self.tokenText(name_tok);
        if (self.current.tag == .less) {
            try self.advance();
            var depth: usize = 1;
            while (depth > 0 and self.current.tag != .eof) {
                if (self.current.tag == .less) depth += 1;
                if (self.current.tag == .greater) depth -= 1;
                try self.advance();
            }
        }
        if (self.current.tag == .keyword_extends) {
            // Intra-file `extends`: trait downgrade via copy-down. The
            // parent layout prefixes the child layout (same field offsets),
            // non-overridden parent methods alias under the child key (one
            // shared function body), `super(args)` calls the parent ctor and
            // `super.m(args)` the parent method statically. The parent must
            // be defined earlier in the file; cross-file parents stay loud.
            try self.advance();
            const parent_tok = self.current;
            try self.expect(.identifier);
            const parent_name = self.tokenText(parent_tok);
            if (self.current.tag == .less) {
                try self.advance();
                var depth: usize = 1;
                while (depth > 0 and self.current.tag != .eof) {
                    if (self.current.tag == .less) depth += 1;
                    if (self.current.tag == .greater) depth -= 1;
                    try self.advance();
                }
            }
            if (self.layout_table.find(parent_name) == null) {
                // Collection pass skips imports, so a cross-file parent is
                // legitimately unknown here: record blindly and let the real
                // pass (imports loaded) validate. Same for a same-file
                // parent declared later (also refused in the real pass).
                if (!self.collect_only) {
                    _ = try self.refuseAt(
                        "error: extends of unknown class '{s}': the parent must be defined earlier in the file",
                        .{parent_name},
                        error.UnknownParentClass,
                    );
                    return error.UnknownParentClass;
                }
            }
            try self.class_parent.put(
                try self.allocator.dupe(u8, class_name),
                try self.allocator.dupe(u8, parent_name),
            );
        }
        if (self.current.tag == .keyword_implements) {
            try self.advance();
            while (true) {
                const t_tok = self.current;
                try self.expect(.identifier);
                const trait_name = self.tokenText(t_tok);
                const tkey = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ class_name, trait_name });
                try self.class_traits.put(tkey, {});
                if (self.current.tag == .less) {
                    try self.advance();
                    var depth: usize = 1;
                    while (depth > 0 and self.current.tag != .eof) {
                        if (self.current.tag == .less) depth += 1;
                        if (self.current.tag == .greater) depth -= 1;
                        try self.advance();
                    }
                }
                if (!try self.accept(.comma)) break;
            }
        }
        try self.expect(.l_brace);
        // Copy-down dispatch, registered UP FRONT (not at class end): the
        // child's own method bodies resolve inherited calls (`this.size()`)
        // while parsing. Non-overridden parent methods alias under the
        // child key (shared body — layouts prefix). Overrides (emitted
        // later) overwrite these entries; pre-scan stubs skip existing keys.
        if (self.class_parent.get(class_name)) |parent_name| {
            var to_alias = std.ArrayList([]const u8).init(self.allocator);
            defer to_alias.deinit();
            var kit = self.class_methods.keyIterator();
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{parent_name});
            while (kit.next()) |k| {
                if (std.mem.startsWith(u8, k.*, prefix)) {
                    try to_alias.append(k.*);
                }
            }
            for (to_alias.items) |pkey| {
                const mname = pkey[prefix.len..];
                const ckey = try self.methodKey(class_name, mname);
                if (!self.class_methods.contains(ckey)) {
                    if (self.class_methods.get(pkey)) |entry| {
                        try self.class_methods.put(ckey, entry);
                        const owner = self.method_emit_owner.get(pkey) orelse parent_name;
                        try self.method_emit_owner.put(
                            try self.allocator.dupe(u8, ckey),
                            try self.allocator.dupe(u8, owner),
                        );
                    }
                }
            }
        }
        // Two-phase lowering: method bodies reference `this` (field layout)
        // and sibling-class types, so the layout must exist before any body
        // is parsed. Pre-scan fields first and register the layout up front;
        // the member loop below then only emits methods (fields are consumed
        // again but not re-registered).
        {
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            const saved_tpl = self.template_lexer_mode;
            var pre_fields = std.ArrayList(Field).init(self.allocator);
            var pre_offset: u32 = 0;
            // Copy-down: parent fields prefix the child layout, so every
            // parent offset is valid on child instances and parent method
            // bodies (parsed once, against the parent layout) stay correct.
            if (self.class_parent.get(class_name)) |parent_name| {
                if (self.layout_table.find(parent_name)) |playout| {
                    for (playout.fields.items) |pf| {
                        try pre_fields.append(.{
                            .name = try self.allocator.dupe(u8, pf.name),
                            .offset = pf.offset,
                            .type_name = try self.allocator.dupe(u8, pf.type_name),
                        });
                    }
                    pre_offset = playout.size;
                }
            }
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                _ = try self.skipModifiers();
                if (self.current.tag == .keyword_constructor or
                    (self.current.tag == .identifier and self.peek.tag == .l_paren))
                {
                    // Forward-declare the method so bodies parsed later in
                    // this class (e.g. a ctor calling `this.clear()`) resolve
                    // static dispatch regardless of member order.
                    const is_ctor_pre = self.current.tag == .keyword_constructor;
                    const pre_name: []const u8 = if (is_ctor_pre) "ctor" else self.tokenText(self.current);
                    const pre_key = try self.methodKey(class_name, pre_name);
                    if (!self.class_methods.contains(pre_key)) {
                        try self.class_methods.put(pre_key, .{});
                    }
                    try self.advance();
                    if (self.current.tag == .less) {
                        try self.advance();
                        var depth: usize = 1;
                        while (depth > 0 and self.current.tag != .eof) {
                            if (self.current.tag == .less) depth += 1;
                            if (self.current.tag == .greater) depth -= 1;
                            try self.advance();
                        }
                    }
                    if (is_ctor_pre and self.current.tag == .l_paren) {
                        // Constructor parameter properties (`public x: T`) are
                        // real fields: collect them into the layout in member
                        // order so `this.x` resolves in every method body.
                        // Defaults skip structurally (no emission pre-body).
                        // Every param (property or plain) is also recorded
                        // for forward `new` short-arg padding.
                        try self.expect(.l_paren);
                        var pp_stored = std.ArrayList(StoredParam).init(self.allocator);
                        defer pp_stored.deinit();
                        while (self.current.tag != .r_paren and self.current.tag != .eof) {
                            const pp_had_mod = try self.skipModifiers();
                            const pp_tok = self.current;
                            try self.expect(.identifier);
                            const pp_name = self.tokenText(pp_tok);
                            var pp_optional = try self.accept(.question);
                            var pp_type: []const u8 = "i32";
                            if (try self.accept(.colon)) {
                                if (self.current.tag == .keyword_void) {
                                    try self.advance();
                                    pp_type = "void";
                                } else {
                                    pp_type = try self.parseTypeName();
                                }
                            }
                            var pp_default: ?[]const u8 = null;
                            if (try self.accept(.equal)) {
                                pp_optional = true;
                                pp_default = try self.saveBalancedDefault();
                                if (pp_default == null) try self.skipBalancedDefault();
                            }
                            if (pp_had_mod) {
                                var pp_size: u32 = 8;
                                var pp_align: u32 = 8;
                                try getTypeSizeAndAlign(pp_type, &pp_size, &pp_align);
                                pre_offset = alignTo(pre_offset, pp_align);
                                try pre_fields.append(.{
                                    .name = try self.allocator.dupe(u8, pp_name),
                                    .offset = pre_offset,
                                    .type_name = try self.allocator.dupe(u8, pp_type),
                                });
                                pre_offset += pp_size;
                            }
                            try pp_stored.append(.{
                                .name = try self.allocator.dupe(u8, pp_name),
                                .type_name = try self.allocator.dupe(u8, pp_type),
                                .optional = pp_optional,
                                .default_src = pp_default,
                            });
                            _ = try self.accept(.comma);
                        }
                        try self.expect(.r_paren);
                        // Merge params into the ctor stub (forward `new`
                        // short-arg padding reads it before the real entry
                        // lands). The member loop overwrites with the full
                        // entry later.
                        {
                            const prev = self.class_methods.get(pre_key);
                            const arr = try self.allocator.alloc(StoredParam, pp_stored.items.len);
                            for (pp_stored.items, 0..) |p, idx| arr[idx] = p;
                            try self.class_methods.put(pre_key, .{
                                .is_void = if (prev) |pe| pe.is_void else true,
                                .params = if (arr.len > 0) arr else null,
                            });
                        }
                        // Skip return annotation up to `{` or `;`, then the body.
                    } else if (self.current.tag == .l_paren) {
                        // Parse (not just skip) `(params)`: forward calls in
                        // earlier method bodies need arity/optional/default
                        // info for short-call padding before the real entry
                        // lands (`this.bubbleUp()` pads `index` from the
                        // pre-scan stub). Pure token slicing, no emission.
                        // Merge into the stub put above (it already exists),
                        // preserving its void mark.
                        var pre_params = try self.parseMethodParams();
                        defer pre_params.deinit();
                        var stored: ?[]StoredParam = null;
                        if (pre_params.items.len > 0) {
                            const arr = try self.allocator.alloc(StoredParam, pre_params.items.len);
                            for (pre_params.items, 0..) |p, idx| {
                                arr[idx] = .{
                                    .name = try self.allocator.dupe(u8, p.name),
                                    .type_name = try self.allocator.dupe(u8, p.type_name),
                                    .optional = p.optional,
                                    .default_src = if (p.default_src) |ds| try self.allocator.dupe(u8, ds) else null,
                                };
                            }
                            stored = arr;
                        }
                        const prev_stub = self.class_methods.get(pre_key);
                        try self.class_methods.put(pre_key, .{
                            .is_void = if (prev_stub) |ps| ps.is_void else false,
                            .params = stored,
                        });
                    }
                    // Skip return annotation up to `{` or `;`, then the body.
                    // A `: void` annotation marks the method void so callers
                    // emit a bare `call` instead of assigning its result.
                    if (self.current.tag == .colon) {
                        try self.advance();
                        if (self.current.tag == .keyword_void) {
                            const is_ctor = std.mem.eql(u8, pre_name, "ctor");
                            // Merge, don't overwrite: the params recorded
                            // above must survive the void mark.
                            const prev = self.class_methods.get(pre_key);
                            try self.class_methods.put(pre_key, .{
                                .is_void = !is_ctor,
                                .params = if (prev) |pe| pe.params else null,
                            });
                        } else if (self.current.tag == .identifier) {
                            // Record the declared return for abstract-stub
                            // emission (a body-less `initMap(): Map<..>`
                            // stubs as `-> ptr`, not `-> i32`).
                            const rt = try self.parseTypeName();
                            const prev = self.class_methods.get(pre_key);
                            try self.class_methods.put(pre_key, .{
                                .is_void = false,
                                .ret = try self.allocator.dupe(u8, rt),
                                .params = if (prev) |pe| pe.params else null,
                            });
                        }
                    }
                    while (self.current.tag != .l_brace and self.current.tag != .semicolon and self.current.tag != .eof) {
                        try self.advance();
                    }
                    if (self.current.tag == .l_brace) {
                        try self.advance();
                        var bd: usize = 1;
                        while (bd > 0 and self.current.tag != .eof) {
                            if (self.current.tag == .l_brace) bd += 1;
                            if (self.current.tag == .r_brace) bd -= 1;
                            try self.advance();
                        }
                    } else {
                        _ = try self.accept(.semicolon);
                    }
                    continue;
                }
                if (self.current.tag == .r_brace or self.current.tag == .eof) break;
                const f_tok = self.current;
                if (self.current.tag != .identifier) {
                    try self.advance();
                    continue;
                }
                try self.advance();
                const f_name = self.tokenText(f_tok);
                if (self.current.tag == .l_paren) {
                    // Method whose name looked like a modifier; skip like above.
                    const pre_key2 = try self.methodKey(class_name, f_name);
                    if (!self.class_methods.contains(pre_key2)) {
                        try self.class_methods.put(pre_key2, .{});
                    }
                    var pd: usize = 0;
                    while (self.current.tag != .eof) {
                        if (self.current.tag == .l_paren or self.current.tag == .l_bracket or self.current.tag == .l_brace) pd += 1;
                        if (self.current.tag == .r_paren or self.current.tag == .r_bracket or self.current.tag == .r_brace) {
                            if (pd == 0) break;
                            pd -= 1;
                            if (pd == 0 and self.current.tag == .r_paren) {
                                try self.advance();
                                break;
                            }
                        }
                        if (self.current.tag == .r_brace and pd == 0) break;
                        try self.advance();
                    }
                    while (self.current.tag != .l_brace and self.current.tag != .semicolon and self.current.tag != .eof) {
                        try self.advance();
                    }
                    if (self.current.tag == .l_brace) {
                        try self.advance();
                        var bd: usize = 1;
                        while (bd > 0 and self.current.tag != .eof) {
                            if (self.current.tag == .l_brace) bd += 1;
                            if (self.current.tag == .r_brace) bd -= 1;
                            try self.advance();
                        }
                    } else {
                        _ = try self.accept(.semicolon);
                    }
                    _ = self.tokenText(f_tok);
                    continue;
                }
                _ = try self.accept(.bang);
                _ = try self.accept(.question);
                var f_type: []const u8 = "i32";
                if (try self.accept(.colon)) {
                    f_type = try self.parseTypeName();
                }
                if (try self.accept(.equal)) {
                    // ASI-aware initializer skip: Talgo sources omit `;`, so
                    // scanning to `semicolon` swallows following members
                    // (`= 0.75` ate the ctor and every method). Consume one
                    // balanced group or literal instead and stop before the
                    // next member.
                    switch (self.current.tag) {
                        .l_bracket => {
                            try self.advance();
                            var bd: usize = 1;
                            while (bd > 0 and self.current.tag != .eof) {
                                if (self.current.tag == .l_bracket) bd += 1;
                                if (self.current.tag == .r_bracket) bd -= 1;
                                try self.advance();
                            }
                        },
                        .l_brace => {
                            try self.advance();
                            var bd2: usize = 1;
                            while (bd2 > 0 and self.current.tag != .eof) {
                                if (self.current.tag == .l_brace) bd2 += 1;
                                if (self.current.tag == .r_brace) bd2 -= 1;
                                try self.advance();
                            }
                        },
                        .l_paren => {
                            try self.advance();
                            var pd: usize = 1;
                            while (pd > 0 and self.current.tag != .eof) {
                                if (self.current.tag == .l_paren) pd += 1;
                                if (self.current.tag == .r_paren) pd -= 1;
                                try self.advance();
                            }
                        },
                        .minus, .plus, .bang => {
                            try self.advance();
                            if (self.current.tag != .eof and self.current.tag != .r_brace) {
                                switch (self.current.tag) {
                                    .l_bracket, .l_brace, .l_paren => {},
                                    else => try self.advance(),
                                }
                            }
                        },
                        else => {
                            if (self.current.tag != .eof and self.current.tag != .r_brace) {
                                try self.advance();
                            }
                        },
                    }
                }
                var f_size: u32 = 8;
                var f_align: u32 = 8;
                try getTypeSizeAndAlign(f_type, &f_size, &f_align);
                pre_offset = alignTo(pre_offset, f_align);
                try pre_fields.append(.{
                    .name = try self.allocator.dupe(u8, f_name),
                    .offset = pre_offset,
                    .type_name = try self.allocator.dupe(u8, f_type),
                });
                pre_offset += f_size;
                _ = try self.accept(.semicolon);
                _ = try self.accept(.comma);
            }
            if (self.layout_table.find(class_name)) |existing| {
                // Real pass rebuild: the collect pass may have registered
                // this layout before imports loaded (cross-file parent
                // fields missing). Overwrite with the fresh scan; the
                // collect pass itself keeps first-write-wins.
                if (!self.collect_only) {
                    existing.fields = pre_fields;
                    existing.size = pre_offset;
                }
            } else {
                try self.layout_table.register(class_name, .{
                    .name = try self.allocator.dupe(u8, class_name),
                    .size = pre_offset,
                    .fields = pre_fields,
                });
            }
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
            self.template_lexer_mode = saved_tpl;
        }
        // Collection pass: the field pre-scan above already registered the
        // layout; skip every member without emitting so later classes can
        // resolve this one as a forward reference.
        if (self.collect_only) {
            var depth: usize = 1;
            while (depth > 0 and self.current.tag != .eof) {
                if (self.current.tag == .l_brace) depth += 1;
                if (self.current.tag == .r_brace) depth -= 1;
                try self.advance();
            }
            return;
        }
        var fields = std.ArrayList(Field).init(self.allocator);
        var offset: u32 = 0;
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            _ = try self.skipModifiers();
            if (self.current.tag == .keyword_constructor) {
                try self.advance();
                try self.emitClassMethod(class_name, "ctor", true);
                continue;
            }
            if (self.current.tag == .identifier and self.peek.tag == .l_paren) {
                const m_tok = self.current;
                try self.advance();
                const m_name = self.tokenText(m_tok);
                if (self.current.tag == .less) {
                    try self.advance();
                    var depth: usize = 1;
                    while (depth > 0 and self.current.tag != .eof) {
                        if (self.current.tag == .less) depth += 1;
                        if (self.current.tag == .greater) depth -= 1;
                        try self.advance();
                    }
                }
                try self.emitClassMethod(class_name, m_name, false);
                continue;
            }
            const f_tok = self.current;
            try self.expect(.identifier);
            const f_name = self.tokenText(f_tok);
            if (self.current.tag == .l_paren) {
                // Method with a modifier-looking name already consumed above;
                // anything else shaped `name(...)` here is a method too.
                try self.emitClassMethod(class_name, f_name, false);
                continue;
            }
            _ = try self.accept(.bang);
            _ = try self.accept(.question);
            var f_type: []const u8 = "i32";
            if (try self.accept(.colon)) {
                f_type = try self.parseTypeName();
            }
            if (try self.accept(.equal)) {
                // Field initializers cannot emit here (class scope has no
                // `this`, and straight-line emission glues into the previous
                // function): suppress emission into a discard buffer, record
                // the source slice, and replay it in the ctor (explicit or
                // synthesized). Imports/consts still land in the header.
                const istart: usize = @as(usize, self.current.start);
                var discard = std.ArrayList(u8).init(self.allocator);
                defer discard.deinit();
                const saved_cap = self.lowerer.capture;
                self.lowerer.capture = &discard;
                // Quarantine scope: the suppressed parse declares temps in
                // the shared scope manager; without isolation they leak into
                // later functions' exit walks (`!t_2` for a temp that was
                // never defined there). Releases during the pop go to the
                // discard buffer too.
                try self.scope_manager.enterScope();
                const quarantine_depth = self.scope_manager.scopeDepth();
                errdefer {
                    while (self.scope_manager.scopeDepth() > quarantine_depth - 1) {
                        self.scope_manager.exitScope(self.lowerer) catch break;
                    }
                    self.lowerer.capture = saved_cap;
                }
                if (self.current.tag == .l_bracket) {
                    var depth: u32 = 0;
                    while (self.current.tag != .eof) {
                        if (self.current.tag == .l_bracket) depth += 1;
                        if (self.current.tag == .r_bracket) {
                            depth -= 1;
                            if (depth == 0) {
                                try self.advance();
                                break;
                            }
                        }
                        try self.advance();
                    }
                } else if (self.current.tag == .l_brace) {
                    // Object-literal field initializers (`children:
                    // Record<...> = {}`) cannot lower in field position (no
                    // `this` yet): skip structurally. Map/Record fields hold
                    // btree handles created fresh at every `new` site (see
                    // parseNew), so an empty `{}` needs no entry replay.
                    var bdepth: u32 = 0;
                    while (self.current.tag != .eof) {
                        if (self.current.tag == .l_brace) bdepth += 1;
                        if (self.current.tag == .r_brace) {
                            bdepth -= 1;
                            if (bdepth == 0) {
                                try self.advance();
                                break;
                            }
                        }
                        try self.advance();
                    }
                } else {
                    _ = try self.parseExpression();
                }
                try self.scope_manager.exitScope(self.lowerer);
                self.lowerer.capture = saved_cap;
                // A discarded arrow registers callbacks and leaves its
                // context/arity published; reset so later call sites never
                // pick up the stale names (would be loud UnknownRegisters).
                self.last_arrow_ctx = null;
                self.last_arrow_arity = 0;
                self.last_arrow_required = 0;
                const iend: usize = @as(usize, self.current.start);
                if (iend > istart) {
                    const fkey = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, f_name });
                    const fsrc = self.lexer.source[istart..@min(iend, self.lexer.source.len)];
                    try self.field_inits.put(fkey, try self.allocator.dupe(u8, fsrc));
                }
            }
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
            _ = try self.accept(.comma);
        }
        try self.expect(.r_brace);
        // Abstract stubs: own methods that never got a body (no `body_src`)
        // emit a `panic(1)` body with the declared signature. Calling an
        // abstract method is a dynamic error (JS throws on unimplemented
        // abstract dispatch); the stub keeps the callee declared so static
        // call sites verify. Aliased (inherited) entries are skipped — the
        // parent body already exists under its own name.
        {
            var stubs = std.ArrayList([]const u8).init(self.allocator);
            defer stubs.deinit();
            var sit = self.class_methods.keyIterator();
            const sprefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{class_name});
            while (sit.next()) |k| {
                if (std.mem.startsWith(u8, k.*, sprefix)) {
                    try stubs.append(k.*);
                }
            }
            for (stubs.items) |skey| {
                if (self.method_emit_owner.contains(skey)) continue;
                const sentry = self.class_methods.get(skey) orelse continue;
                if (sentry.body_src != null) continue;
                const smname = skey[sprefix.len..];
                try self.lowerer.emit("@{s}_{s}(this: ptr", .{ class_name, smname });
                if (sentry.params) |spp| {
                    for (spp) |sp| {
                        try self.lowerer.emit(", {s}: {s}", .{ sp.name, saTypeOf(sp.type_name) });
                    }
                }
                const is_v = sentry.is_void;
                const sret = sentry.ret;
                if (!is_v) {
                    if (sret) |rt| {
                        if (!std.mem.eql(u8, rt, "void")) {
                            try self.lowerer.emit(") -> {s}:\n", .{saTypeOf(rt)});
                        } else {
                            try self.lowerer.emit("):\n", .{});
                        }
                    } else {
                        try self.lowerer.emit("):\n", .{});
                    }
                } else {
                    try self.lowerer.emit("):\n", .{});
                }
                self.lowerer.beginFunction();
                if (sentry.params) |spp| {
                    var pi: usize = spp.len;
                    while (pi > 0) {
                        pi -= 1;
                        try self.lowerer.emit("    !{s}\n", .{spp[pi].name});
                    }
                }
                try self.lowerer.emit("    !this\n", .{});
                try self.lowerer.emit("    panic(1)\n", .{});
                try self.lowerer.finishFunction("return 0");
            }
        }
        // Layout was pre-registered by the field pre-scan so method bodies
        // could resolve `this`; only register here when absent.
        if (self.layout_table.find(class_name) == null) {
            const layout = StructLayout{
                .name = try self.allocator.dupe(u8, class_name),
                .size = offset,
                .fields = fields,
            };
            try self.layout_table.register(class_name, layout);
        }
        // Synthesized default ctor: no declared ctor (and no inherited one
        // via alias) but at least one replayable field init
        // (`root = new TrieNode()`). Runs the inits; trivial (`{}`, numeric,
        // boolean) inits stay zero-covered and never trigger this.
        {
            const ckey = try self.methodKey(class_name, "ctor");
            if (self.class_methods.get(ckey) == null) {
                if (self.layout_table.find(class_name)) |layout| {
                    var need_ctor = false;
                    for (layout.fields.items) |fld| {
                        const fkey = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, fld.name });
                        if (self.field_inits.get(fkey)) |src| {
                            const trimmed = std.mem.trim(u8, src, " \t\r\n");
                            if (trimmed.len == 0 or trimmed[0] == '{') continue;
                            if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false")) continue;
                            const numeric = (trimmed[0] >= '0' and trimmed[0] <= '9') or
                                ((trimmed[0] == '-' or trimmed[0] == '+') and trimmed.len > 1);
                            if (!numeric) {
                                need_ctor = true;
                                break;
                            }
                        }
                    }
                    if (need_ctor) {
                        try self.lowerer.emit("@{s}_ctor(this: ptr):\n", .{class_name});
                        self.lowerer.beginFunction();
                        const saved_defer = self.scope_manager.defer_releases;
                        self.scope_manager.defer_releases = true;
                        defer self.scope_manager.defer_releases = saved_defer;
                        try self.scope_manager.enterScope();
                        try self.scope_manager.declareVar("this", class_name, "this", true);
                        try self.replayFieldInits(class_name);
                        if (!self.lowerer.isTerminated()) {
                            try self.releaseLiveRegisters();
                        }
                        try self.scope_manager.exitScope(self.lowerer);
                        try self.lowerer.finishFunction("return");
                        try self.class_methods.put(ckey, .{ .is_void = true });
                    }
                }
            }
        }
    }

    // ==========================================
    // Type alias
    // ==========================================

    fn parseTypeAlias(self: *Parser) anyerror!void {
        try self.expect(.keyword_type);
        const name_tok = self.current;
        try self.expect(.identifier);
        const name = self.tokenText(name_tok);

        // Generic params on the alias (`type Node<T> = ...`): construction
        // is monomorphic here, so only the base name survives.
        if (self.current.tag == .less) {
            try self.advance();
            var gdepth: usize = 1;
            while (gdepth > 0 and self.current.tag != .eof) {
                if (self.current.tag == .less) gdepth += 1;
                if (self.current.tag == .greater) gdepth -= 1;
                try self.advance();
            }
        }

        try self.expect(.equal);

        // Object-shape aliases (`type Node<T> = { value: T; next?: ... }`)
        // register a struct layout exactly like interfaces, so `{...} as
        // Node<T>` can build inline.
        if (self.current.tag == .l_brace) {
            try self.advance();
            var alias_fields = std.ArrayList(Field).init(self.allocator);
            var alias_offset: u32 = 0;
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                const af_tok = self.current;
                try self.expect(.identifier);
                const af_name = self.tokenText(af_tok);
                _ = try self.accept(.question);
                _ = try self.accept(.bang);
                try self.expect(.colon);
                const af_type = try self.parseTypeName();
                var af_size: u32 = 8;
                var af_align: u32 = 8;
                try getTypeSizeAndAlign(af_type, &af_size, &af_align);
                alias_offset = alignTo(alias_offset, af_align);
                try alias_fields.append(.{
                    .name = try self.allocator.dupe(u8, af_name),
                    .offset = alias_offset,
                    .type_name = try self.allocator.dupe(u8, af_type),
                });
                alias_offset += af_size;
                _ = try self.accept(.semicolon);
                _ = try self.accept(.comma);
            }
            try self.expect(.r_brace);
            _ = try self.accept(.semicolon);
            if (self.layout_table.find(name) == null) {
                try self.layout_table.register(name, .{
                    .name = try self.allocator.dupe(u8, name),
                    .size = alias_offset,
                    .fields = alias_fields,
                });
            }
            return;
        }

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
        // `var` lowers exactly like `let`: the subset has function-level
        // lowering with lexical scopes, so hoisting differences do not apply.
        const tag = self.current.tag;
        const is_const = tag == .keyword_const;
        if (is_const or tag == .keyword_var) {
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

        // `let i: T, j: T2, k;` multi-declaration without initializers
        // (the `for (i...)` pre-declaration shape): declare each in turn.
        // Any `= init` inside a multi-declaration stays a loud refusal.
        if (self.current.tag == .comma) {
            const first_t: []const u8 = type_name orelse "i32";
            const first_heap = std.mem.eql(u8, first_t, "string") or isFutureType(first_t);
            try self.scope_manager.declareVar(var_name, first_t, var_name, first_heap);
            try self.lowerer.emit("    {s} = 0\n", .{var_name});
            while (try self.accept(.comma)) {
                const ntok = self.current;
                try self.expect(.identifier);
                const nname = self.tokenText(ntok);
                var nt: []const u8 = "i32";
                if (try self.accept(.colon)) {
                    nt = try self.parseTypeName();
                }
                if (self.current.tag == .equal) {
                    _ = try self.refuseAt(
                        "error: initializers in multi-declarations are not supported",
                        .{},
                        error.ConstructorsNotSupported,
                    );
                    return error.ConstructorsNotSupported;
                }
                const nheap = std.mem.eql(u8, nt, "string") or isFutureType(nt);
                try self.scope_manager.declareVar(nname, nt, nname, nheap);
                try self.lowerer.emit("    {s} = 0\n", .{nname});
            }
            _ = try self.accept(.semicolon);
            return;
        }

        // `let x: T;` declares without an initializer (`undefined` lowers
        // as null/0); previously `expect(.equal)` threw here and desynced
        // the rest of the class (`toArray(): T[]` misparsed as a result).
        if (!(try self.accept(.equal))) {
            const t_uninit: []const u8 = type_name orelse "i32";
            const uninit_heap = std.mem.eql(u8, t_uninit, "string") or isFutureType(t_uninit);
            try self.scope_manager.declareVar(var_name, t_uninit, var_name, uninit_heap);
            try self.lowerer.emit("    {s} = 0\n", .{var_name});
            _ = try self.accept(.semicolon);
            return;
        }

        // `{...}` initializers dispatch on the annotation: a known struct
        // layout builds inline, Map/Record constructs a btree, otherwise
        // (unannotated, e.g. `{ value: item } as Node<T>`) the generic
        // expression path below handles it. Peek only here; each path
        // consumes the brace itself.
        var obj_struct = false;
        var obj_map = false;
        if (self.current.tag == .l_brace) {
            if (type_name) |t_name| {
                if (std.mem.eql(u8, t_name, "Map") or std.mem.eql(u8, t_name, "Record")) {
                    obj_map = true;
                } else if (self.layout_table.find(t_name) != null) {
                    obj_struct = true;
                }
            }
        }
        if (obj_struct) {
            try self.advance(); // {
            // Object literal initialization
            const t_name = type_name.?;
            const layout = self.layout_table.find(t_name).?;

            try self.scope_manager.declareVar(var_name, t_name, var_name, true);

            try self.lowerer.emit("    {s} = alloc {d}\n", .{ var_name, layout.size });

            try self.parseStructLiteralFields(var_name, layout);
        } else if (obj_map) {
            try self.advance(); // {
            // Map/Record literal: fresh btree, then one insert per entry.
            // (`children = {}` is the empty case; entries work the same.)
            try self.lowerer.emitImport("sa_std/btree_map.sa");
            try self.scope_manager.declareVar(var_name, "Map", var_name, true);
            try self.lowerer.emit("    {s} = call @sa_btree_map_new()\n", .{var_name});
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                var ks: []const u8 = "";
                if (self.current.tag == .identifier and self.peek.tag == .colon) {
                    // Bare name keys (`{length: n}`) denote strings, not
                    // variables: materialize the text directly.
                    const ktok = self.current;
                    try self.advance();
                    ks = try self.materializeStringChunk(self.tokenText(ktok));
                } else {
                    const kexpr = try self.parseExpression();
                    ks = try self.mapKeySlice(kexpr);
                }
                try self.expect(.colon);
                const kval = try self.parseExpression();
                try self.lowerer.emit("    call @sa_btree_map_insert(&{s}, &{s}, {s})\n", .{ var_name, ks, kval });
                _ = try self.accept(.comma);
                _ = try self.accept(.semicolon);
            }
            try self.expect(.r_brace);
        } else if (try self.accept(.l_bracket)) {
            // Array literal initialization: let arr = [1, 2, 3]
            // `parseTypeName` keeps `[]` suffixes; the literal's element type
            // is exactly one level stripped (`number[][]` holds `number[]`
            // slice headers, 8 bytes each). Stripping all levels made nested
            // literals store truncated ptrs as i32.
            const arr_type: []const u8 = type_name orelse "i32[]";
            var elem_type: []const u8 = stripOneArray(arr_type) orelse "i32";
            if (std.mem.indexOf(u8, elem_type, "<")) |a_idx| {
                // Keep generic base for layout compat (`MapEntry<K,V>[]`
                // element `MapEntry<K,V>` -> `MapEntry`), re-attaching any
                // remaining `[]` so nested slices stay ptr-sized.
                const gbase = elem_type[0..a_idx];
                var depth: usize = 0;
                var k: usize = 0;
                while (k + 1 < elem_type.len) : (k += 1) {
                    if (elem_type[k] == '[' and elem_type[k + 1] == ']') depth += 1;
                }
                elem_type = gbase;
                var d: usize = 0;
                while (d < depth) : (d += 1) {
                    elem_type = try std.fmt.allocPrint(self.allocator, "{s}[]", .{elem_type});
                }
            }
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
            // Tag the variable with the full array type (`number[][]`), not
            // the element type: indexing/for-of derive the element by
            // stripping one level. Tagging `buckets` as `number` made
            // `buckets[i]` derive `i32` and broke every nested access.
            try self.scope_manager.declareVar(var_name, arr_type, var_name, true);

            try self.lowerer.emit("    {s} = alloc {d}\n", .{ var_name, arr_size });

            // Element storage; a zero-length array still needs a valid pointer.
            const data_reg = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc {d}\n", .{ data_reg, @max(elem_count * elem_size, 4) });

            for (values.items, 0..) |val, idx| {
                const off = @as(u32, @intCast(idx)) * elem_size;
                // A quoted element is a string literal, not an SA operand:
                // materialise the slice first (same rule as plain `let s`).
                // String elements store the header address (ptr-sized).
                if (val.len >= 2 and (val[0] == '"' or val[0] == '\'')) {
                    const chunk = try self.materializeStringChunk(val[1 .. val.len - 1]);
                    try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ data_reg, off, chunk, saTypeOf(elem_type) });
                    // No markConsumed: the array only stores the header
                    // address (a read, not a move), so the chunk stays live
                    // for the function-exit walk. (Plain `let s` moves the
                    // header into `s` instead, which does consume it.)
                } else {
                    try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ data_reg, off, val, saTypeOf(elem_type) });
                }
            }
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ var_name, data_reg });
            try self.lowerer.emit("    store {s} + 8, {d} as u64\n", .{ var_name, elem_count });
        } else {
            // Top-level `const f = (args) => body`: lower as a plain named
            // SA function, not a closure callback (whose parent-side context
            // allocation would land at file scope, outside any function).
            // In-function arrows keep the callback path below. Imported
            // files enter their own scope, so the baseline shifts (see
            // `import_base_depth`).
            if (self.scope_manager.scopeDepth() == self.import_base_depth + 1 and self.arrow_depth == 0 and try self.looksLikeTopArrow()) {
                try self.parseTopLevelArrowFn(var_name);
                _ = try self.accept(.semicolon);
                return;
            }
            // `const name = (...) => ...`: let the arrow pre-register `name`
            // so its body can call itself recursively. Gated on the arrow
            // shape so `const x = f(() => ...)` does not misbind `x`.
            const want_bind = try self.looksLikeTopArrow();
            if (want_bind) self.pending_arrow_bind = var_name;
            const val = try self.parseExpression();
            self.pending_arrow_bind = null;
            // A `"..."` literal is not an SA operand: materialise the slice
            // and bind the variable to it. Emitting `s = "bob"` verbatim is
            // rejected by the verifier (UnknownRegister). Only applies to
            // unannotated or `string`-annotated bindings; anything else falls
            // through to the generic path.
            if (val.len > 0 and (val[0] == '"' or val[0] == '\'')) {
                const ann_ok = if (type_name) |ann| std.mem.eql(u8, ann, "string") else true;
                if (ann_ok) {
                    const inner = if (val.len >= 2) val[1 .. val.len - 1] else "";
                    const chunk = try self.materializeStringChunk(inner);
                    try self.scope_manager.declareVar(var_name, "string", var_name, true);
                    try self.lowerer.emit("    {s} = {s}\n", .{ var_name, chunk });
                    self.scope_manager.markConsumed(chunk);
                    _ = try self.accept(.semicolon);
                    return;
                }
            }
            // `let f = (x) => ...`: `val` is the freshly emitted callback
            // name. A function name is not a register, so `f = @cb` would be
            // invalid SA-ASM and `call @f` would not resolve. Record an alias
            // instead and emit nothing: direct calls to `f` lower straight to
            // the callback with its captured context.
            if (std.mem.startsWith(u8, val, "@closure_callback_")) {
                const key = try self.allocator.dupe(u8, var_name);
                const ctx_move = self.last_arrow_ctx orelse "^ctx";
                // last_arrow_ctx strings are owned (allocPrint per arrow); the
                // alias takes over this one, so clear the slot without freeing.
                self.last_arrow_ctx = null;
                try self.arrow_aliases.put(key, .{ .cb = val, .ctx = ctx_move, .arity = self.last_arrow_arity, .required = self.last_arrow_required });
                try self.scope_manager.declareVar(var_name, "fn", var_name, false);
                _ = try self.accept(.semicolon);
                return;
            }
            // A future handle keeps its type when no annotation is given;
            // an explicit non-future annotation with a future value is a
            // loud error, not a silent pointer-as-integer.
            try self.bindLetValue(var_name, type_name, val);
        }

        // Trailing multi-declaration (`let a = 1, b = 2, c;`): each further
        // item takes an optional type and initializer. Arrows, object and
        // array literals stay loud here (rare in this position); string
        // literals materialise like the main path above.
        while (try self.accept(.comma)) {
            const ntok = self.current;
            try self.expect(.identifier);
            const nname = self.tokenText(ntok);
            var nt: ?[]const u8 = null;
            if (try self.accept(.colon)) {
                nt = try self.parseTypeName();
            }
            if (!(try self.accept(.equal))) {
                const t_uninit: []const u8 = nt orelse "i32";
                const uninit_heap = std.mem.eql(u8, t_uninit, "string") or isFutureType(t_uninit);
                try self.scope_manager.declareVar(nname, t_uninit, nname, uninit_heap);
                try self.lowerer.emit("    {s} = 0\n", .{nname});
                continue;
            }
            if (self.current.tag == .l_brace or self.current.tag == .l_bracket) {
                _ = try self.refuseAt(
                    "error: literal initializers in trailing multi-declarations are not supported",
                    .{},
                    error.ConstructorsNotSupported,
                );
                return error.ConstructorsNotSupported;
            }
            if (try self.looksLikeTopArrow()) {
                _ = try self.refuseAt(
                    "error: arrow initializers in trailing multi-declarations are not supported",
                    .{},
                    error.ConstructorsNotSupported,
                );
                return error.ConstructorsNotSupported;
            }
            const nval = try self.parseExpression();
            if (nval.len > 0 and (nval[0] == '"' or nval[0] == '\'')) {
                const ann_ok = if (nt) |ann| std.mem.eql(u8, ann, "string") else true;
                if (ann_ok) {
                    const inner = if (nval.len >= 2) nval[1 .. nval.len - 1] else "";
                    const chunk = try self.materializeStringChunk(inner);
                    try self.scope_manager.declareVar(nname, "string", nname, true);
                    try self.lowerer.emit("    {s} = {s}\n", .{ nname, chunk });
                    self.scope_manager.markConsumed(chunk);
                    continue;
                }
            }
            if (std.mem.startsWith(u8, nval, "@closure_callback_")) {
                _ = try self.refuseAt(
                    "error: arrow initializers in trailing multi-declarations are not supported",
                    .{},
                    error.ConstructorsNotSupported,
                );
                return error.ConstructorsNotSupported;
            }
            try self.bindLetValue(nname, nt, nval);
        }

        _ = try self.accept(.semicolon);
    }

    /// Bind an already-evaluated expression value to a `let` name: future
    /// check, type inference, scalar copy-vs-move, declaration and emission.
    /// Shared by `parseLet` and the multi-declaration loop below.
    fn bindLetValue(self: *Parser, var_name: []const u8, type_name: ?[]const u8, val: []const u8) anyerror!void {
        var t_name: []const u8 = "i32";
        if (type_name) |ann| {
            t_name = ann;
            if (!isFutureType(t_name)) {
                if (self.scope_manager.lookup(val)) |vv| {
                    if (isFutureType(vv.type_name)) {
                        std.debug.print("error:{d}:{d}: cannot assign future to '{s}': await it first\n", .{
                            self.current.line,
                            self.current.col,
                            t_name,
                        });
                        return error.FutureMustBeAwaited;
                    }
                }
            }
        } else if (self.scope_manager.lookup(val)) |vv| {
            t_name = vv.type_name;
        }

        const is_heap = std.mem.startsWith(u8, val, "slice_") or std.mem.eql(u8, t_name, "string") or isFutureType(t_name);

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
            const copy_scalar = src_is_var and
                (std.mem.eql(u8, t_name, "i32") or std.mem.eql(u8, t_name, "u32") or
                std.mem.eql(u8, t_name, "number") or std.mem.eql(u8, t_name, "boolean") or
                std.mem.eql(u8, t_name, "i64") or std.mem.eql(u8, t_name, "u64")) and
                (self.branch_depth > 0 or self.loop_depth > 0 or self.scope_manager.isOuterVariable(val));
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

    // ==========================================
    // Function
    // ==========================================

    /// Speculative check: does the upcoming initializer parse as an arrow
    /// definition (`x =>`, `(params) =>`, `(params): Ret =>`)?
    /// Restores all lexer state via defer; safe before the real parse.
    fn looksLikeTopArrow(self: *Parser) anyerror!bool {
        if (self.current.tag == .identifier and self.peek.tag == .arrow) return true;
        if (self.current.tag != .l_paren) return false;
        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_peek = self.peek;
        defer {
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
        }
        try self.advance(); // (
        if (self.current.tag == .r_paren) {
            try self.advance(); // )
        } else {
            while (true) {
                if (self.current.tag != .identifier) return false;
                try self.advance(); // param name
                _ = try self.accept(.question);
                if (try self.accept(.colon)) {
                    if (self.current.tag != .identifier) return false;
                    try self.advance(); // base type name
                    try self.skipGenericArgs();
                    while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                        try self.advance(); // [
                        try self.advance(); // ]
                    }
                }
                if (try self.accept(.equal)) {
                    try self.skipBalancedDefault();
                }
                if (try self.accept(.comma)) continue;
                break;
            }
            if (self.current.tag != .r_paren) return false;
            try self.advance(); // )
        }
        // Optional return annotation `: T` / `: T[]` / `: void`, plus a
        // union remainder (`: number | null`): skip `| U` arms.
        if (self.current.tag == .colon) {
            try self.advance(); // :
            if (self.current.tag != .identifier and self.current.tag != .keyword_void and self.current.tag != .keyword_null and self.current.tag != .keyword_undefined) return false;
            try self.advance(); // return type name
            try self.skipGenericArgs();
            while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                try self.advance(); // [
                try self.advance(); // ]
            }
            while (self.current.tag == .pipe) {
                try self.advance(); // |
                if (self.current.tag != .identifier and self.current.tag != .keyword_void and self.current.tag != .keyword_null and self.current.tag != .keyword_undefined) return false;
                try self.advance();
                try self.skipGenericArgs();
                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                    try self.advance();
                    try self.advance();
                }
            }
        }
        return self.current.tag == .arrow;
    }

    /// Lower a top-level `const name = (params) => body` as a plain named SA
    /// function `@name` (no context parameter), pre-registering the alias so
    /// self-recursion and mutual calls inside the body resolve. A nested
    /// arrow with captures still uses the closure-callback path; only the
    /// outermost file-scope binding takes this route (see the parseLet hook).
    fn parseTopLevelArrowFn(self: *Parser, name: []const u8) anyerror!void {
        const cb_name = try std.fmt.allocPrint(self.allocator, "@{s}", .{name});
        const key = try self.allocator.dupe(u8, name);
        try self.arrow_aliases.put(key, .{ .cb = cb_name, .ctx = "", .plain = true });
        try self.scope_manager.declareVar(name, "fn", name, false);

        var params = std.ArrayList(struct { name: []const u8, type_name: []const u8 }).init(self.allocator);
        defer params.deinit();
        if (self.current.tag == .identifier and self.peek.tag == .arrow) {
            // Single untyped param `x =>`.
            const pn_tok = self.current;
            try self.advance();
            try self.expect(.arrow);
            try params.append(.{ .name = self.tokenText(pn_tok), .type_name = "i32" });
        } else {
            try self.expect(.l_paren);
            if (self.current.tag != .r_paren) {
                while (true) {
                    const pn_tok = self.current;
                    try self.expect(.identifier);
                    const pn = self.tokenText(pn_tok);
                    var pt: []const u8 = "i32";
                    if (try self.accept(.colon)) {
                        const tt = self.current;
                        try self.expect(.identifier);
                        pt = self.tokenText(tt);
                        try self.skipGenericArgs();
                        var arr_pairs: u32 = 0;
                        while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                            try self.advance(); // [
                            try self.advance(); // ]
                            arr_pairs += 1;
                        }
                        if (arr_pairs > 0) {
                            const buf = try self.allocator.alloc(u8, pt.len + arr_pairs * 2);
                            @memcpy(buf[0..pt.len], pt);
                            for (0..arr_pairs) |k| {
                                buf[pt.len + k * 2] = '[';
                                buf[pt.len + k * 2 + 1] = ']';
                            }
                            pt = buf;
                        }
                    }
                    // Default values (`start: number = 0`, `end = array.length - 1`):
                    // the subset always passes explicitly (Talgo recursion does),
                    // so skip the initializer structurally without emitting.
                    if (try self.accept(.equal)) {
                        try self.skipBalancedDefault();
                    }
                    try params.append(.{ .name = pn, .type_name = pt });
                    if (try self.accept(.comma)) continue;
                    break;
                }
            }
            try self.expect(.r_paren);
        }
        // Optional return annotation; `: T[]` / `: string` mean `-> ptr`.
        var ret_ann: ?[]const u8 = null;
        var ret_is_slice = false;
        var ret_arr_pairs: u32 = 0;
        if (try self.accept(.colon)) {
            if (self.current.tag == .keyword_void) {
                try self.advance();
                ret_ann = "void";
            } else {
                const rt_tok = self.current;
                try self.expect(.identifier);
                ret_ann = self.tokenText(rt_tok);
                if (std.mem.eql(u8, ret_ann.?, "string")) ret_is_slice = true;
                try self.skipGenericArgs();
                ret_arr_pairs = 0;
                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                    try self.advance(); // [
                    try self.advance(); // ]
                    ret_is_slice = true;
                    ret_arr_pairs += 1;
                }
                // Union remainder (`number | null`, `T | undefined`): the
                // subset maps null/undefined to 0, so the first arm decides
                // the SA type; skip the rest structurally.
                while (self.current.tag == .pipe) {
                    try self.advance(); // |
                    if (self.current.tag == .identifier or self.current.tag == .keyword_void or self.current.tag == .keyword_null or self.current.tag == .keyword_undefined) {
                        try self.advance();
                    } else break;
                    try self.skipGenericArgs();
                    while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                        try self.advance();
                        try self.advance();
                    }
                }
            }
        }
        try self.expect(.arrow);

        const is_expr_body = self.current.tag != .l_brace;
        var value_fn = params.items.len > 0 or is_expr_body;
        var sa_ret: ?[]const u8 = null;
        if (ret_ann) |ra| {
            if (std.mem.eql(u8, ra, "void")) {
                value_fn = false;
            } else if (ret_is_slice) {
                sa_ret = "ptr";
            } else {
                sa_ret = saTypeOf(ra);
            }
        } else if (value_fn) {
            sa_ret = "i32";
        }

        // Record the declared return type (first union arm + `[]` pairs)
        // for call-site result retagging (see `fn_ret`).
        {
            const base = ret_ann orelse (if (value_fn) "i32" else "void");
            var full = base;
            if (ret_arr_pairs > 0) {
                const buf = try self.allocator.alloc(u8, base.len + ret_arr_pairs * 2);
                @memcpy(buf[0..base.len], base);
                for (0..ret_arr_pairs) |k| {
                    buf[base.len + k * 2] = '[';
                    buf[base.len + k * 2 + 1] = ']';
                }
                full = buf;
            }
            try self.fn_ret.put(try self.allocator.dupe(u8, name), full);
        }

        // Out-of-line emission with its own CFG state, spliced into the
        // file-scope callbacks buffer like closure callbacks are.
        const orig_low = self.lowerer;
        var tmp_low = lowerer_mod.Lowerer.init(self.allocator);
        defer tmp_low.deinit();
        self.lowerer = &tmp_low;
        defer self.lowerer = orig_low;

        const saved_defer = self.scope_manager.defer_releases;
        self.scope_manager.defer_releases = true;
        defer self.scope_manager.defer_releases = saved_defer;

        try self.lowerer.emit("@{s}(", .{name});
        for (params.items, 0..) |p, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}: {s}", .{ p.name, saTypeOf(p.type_name) });
        }
        if (sa_ret) |r| {
            try self.lowerer.emit(") -> {s}:\n", .{r});
        } else {
            try self.lowerer.emit("):\n", .{});
        }
        self.lowerer.beginFunction();

        try self.scope_manager.enterScope();
        for (params.items) |p| {
            try self.scope_manager.declareVar(p.name, p.type_name, p.name, true);
        }
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            if (!self.lowerer.isTerminated()) {
                try self.releaseLiveRegisters();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance(); // consume }
        } else {
            const val = try self.parseExpression();
            try self.releaseLiveRegistersExcept(val);
            try self.lowerer.emitTerm("    return {s}\n", .{val});
        }
        try self.scope_manager.exitScope(self.lowerer);
        const default_ret: []const u8 = if (sa_ret) |_| "return 0" else "return";
        try self.lowerer.finishFunction(default_ret);
        try orig_low.callbacks.appendSlice(tmp_low.output.items);
        // Nested arrow callbacks inside the body were spliced into
        // tmp_low.callbacks by parseArrowBody; without this they are
        // dropped and call sites dangle (`callee is not declared`).
        try orig_low.callbacks.appendSlice(tmp_low.callbacks.items);
        if (tmp_low.header.items.len > 0) try orig_low.header.appendSlice(tmp_low.header.items);
        for (tmp_low.imports.items) |imp| try orig_low.emitImport(imp);
    }

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
            // Parameter defaults (`f(a: i32 = 0)`): skipped structurally.
            if (try self.accept(.equal)) {
                try self.skipBalancedDefault();
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
        // Record for call-site result retagging (see `fn_ret`); unannotated
        // functions only lower `void` bodies, so callers must not use values.
        try self.fn_ret.put(
            try self.allocator.dupe(u8, func_name),
            return_type orelse "void",
        );

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
            // Parameter defaults: skipped structurally (see parseFunction).
            if (try self.accept(.equal)) {
                try self.skipBalancedDefault();
            }

            try params.append(.{ .name = p_name, .type_name = p_type });
            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);
        // An `async function f(): T` returns a ready-future handle: a 16-byte
        // `{state, value}` heap struct mirroring SLA's ReadyFuture layout
        // (state +0, value +8, 1 = READY). There is no executor and no
        // pending state in the subset, so the future is ready from birth and
        // `await` just loads the value. `@async` is not an
        // assembler-accepted function prefix, hence the plain `@f` emission.
        var return_type: ?[]const u8 = null;
        if (try self.accept(.colon)) {
            return_type = try self.parseTypeName();
        }
        var inner: []const u8 = "i32";
        if (return_type) |rt| {
            if (!std.mem.eql(u8, rt, "void")) inner = rt;
        }
        // Callers receive the ready-future handle (unwrapped by `await`,
        // which keys off `isFutureType`), so record the handle type.
        {
            const ft = try futureTypeName(self.allocator, inner);
            try self.fn_ret.put(try self.allocator.dupe(u8, func_name), ft);
        }
        // The SA entry point must be a synchronous `@main() -> i32` (its
        // result is the process exit status). An `async function main`
        // therefore keeps its body under `@async_main() -> ptr` and gets a
        // synthesized synchronous driver, the TS equivalent of SLA's
        // `sched_block_on_timeout` boundary driver (`sa_std/async.sla`):
        // call the async body, then unwrap the (ready) future. Pending
        // handles cannot be constructed yet, so no poll loop is needed;
        // a pending handle at this boundary would unwrap stale data, which
        // is documented in REQUIREMENTS rather than silently accepted.
        const is_entry = std.mem.eql(u8, func_name, "main");
        if (is_entry) {
            if (!std.mem.eql(u8, inner, "i32")) {
                std.debug.print("error:{d}:{d}: async 'main' must resolve to i32 (the exit status channel)\n", .{
                    func_name_tok.line,
                    func_name_tok.col,
                });
                return error.AsyncMainType;
            }
            if (params.items.len != 0) {
                std.debug.print("error:{d}:{d}: async 'main' takes no arguments\n", .{
                    func_name_tok.line,
                    func_name_tok.col,
                });
                return error.AsyncMainArgs;
            }
        }
        const emit_name: []const u8 = if (is_entry) "async_main" else func_name;
        const future_t = try futureTypeName(self.allocator, inner);
        defer self.allocator.free(future_t);
        try self.scope_manager.declareVar(emit_name, future_t, emit_name, false);
        if (!self.async_fns.contains(emit_name)) {
            try self.async_fns.put(try self.allocator.dupe(u8, emit_name), try self.allocator.dupe(u8, inner));
        }

        try self.lowerer.emit("@{s}(", .{emit_name});
        for (params.items, 0..) |p, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}: {s}", .{ p.name, saTypeOf(p.type_name) });
        }
        try self.lowerer.emit(") -> ptr:\n", .{});
        self.lowerer.beginFunction();

        self.scope_manager.defer_releases = true;
        defer self.scope_manager.defer_releases = false;

        self.async_depth += 1;
        const saved_inner = self.async_inner;
        self.async_inner = inner;
        defer {
            self.async_depth -= 1;
            self.async_inner = saved_inner;
        }

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
            if (!self.lowerer.isTerminated()) {
                try self.releaseLiveRegisters();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance();
        }

        try self.scope_manager.exitScope(self.lowerer);

        // Falling off the end yields a zero-valued future, like an implicit
        // `return 0` in a sync function.
        if (!self.lowerer.isTerminated()) {
            const fut = try self.buildReadyFuture(null, inner);
            try self.lowerer.emitTerm("    return {s}\n", .{fut});
        }
        try self.lowerer.finishFunction("return 0");
        if (is_entry) {
            try self.lowerer.emit("@main() -> i32:\n", .{});
            self.lowerer.beginFunction();
            self.scope_manager.defer_releases = true;
            try self.scope_manager.enterScope();
            const fut = try self.newTemp();
            try self.retagTemp(fut, "future<i32>");
            try self.lowerer.emit("    {s} = call @async_main()\n", .{fut});
            const out = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as i32\n", .{ out, fut });
            try self.lowerer.emit("    store {s} + 0, 0 as u64\n", .{fut});
            try self.lowerer.emit("    !{s}\n", .{fut});
            self.scope_manager.markConsumed(fut);
            try self.releaseLiveRegistersExcept(out);
            try self.lowerer.emitTerm("    return {s}\n", .{out});
            try self.scope_manager.exitScope(self.lowerer);
            self.scope_manager.defer_releases = false;
            try self.lowerer.finishFunction("return 0");
        }
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

        // Branch-arm flag isolation: releases on one arm (e.g. parameter
        // cleanup on an early return) must not change emission decisions on
        // sibling paths. The else arm always restarts from entry state; a
        // terminated arm's flags revert (it never joins).
        var entry_flags = try self.scope_manager.snapshotFlags(self.allocator);
        defer self.scope_manager.freeSnap(&entry_flags);
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
            // Single-statement arm without braces: wrap it in a scope like
            // the braced path, so arm-local temps are released on the arm
            // instead of leaking into the function-exit walk.
            try self.scope_manager.enterScope();
            try self.parseStatement();
            try self.exitScopeReleasingLocals();
        }
        if (self.lowerer.isTerminated()) {
            self.scope_manager.restoreFlags(entry_flags);
        }

        if (!self.lowerer.isTerminated()) {
            try self.lowerer.emitJumpTo(end_label);
        }
        try self.lowerer.emitLabel(else_label);

        if (self.current.tag == .keyword_else) {
            self.scope_manager.restoreFlags(entry_flags);
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
                try self.scope_manager.enterScope();
                try self.parseStatement();
                try self.exitScopeReleasingLocals();
            }
            if (self.lowerer.isTerminated()) {
                self.scope_manager.restoreFlags(entry_flags);
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

        // A literal condition is not a register (`br 1` is rejected with
        // UnknownRegister): `while (true)` falls straight into the body,
        // `while (false)` jumps to the end.
        if (std.mem.eql(u8, cond, "1") or std.mem.eql(u8, cond, "true")) {
            // Infinite loop: no branch emitted.
        } else if (std.mem.eql(u8, cond, "0") or std.mem.eql(u8, cond, "false")) {
            try self.lowerer.emitJumpTo(end_label);
        } else {
            _ = try self.emitBranchIfFalse(cond, end_label);
        }
        try self.pushLoopTargets(end_label, loop_label);

        // Loop-carried scalar tracking (emitMove copies instead of moving):
        // for-of/for set this around their bodies; while must too.
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
            // Single-statement body: same scope wrap as the braced path.
            try self.scope_manager.enterScope();
            try self.parseStatement();
            try self.exitScopeReleasingLocals();
        }

        try self.lowerer.useLabel(loop_label);
        // A body ending in `break`/`continue`/`return` already terminates:
        // a back-edge after it would be an unreachable fallthrough block.
        if (!self.lowerer.isTerminated()) {
            try self.lowerer.emitJumpTo(loop_label);
        }
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
        // Loop-carried scalars copy instead of move: a var consumed in the
        // body but live at entry trips the back-edge merge (PhiStateConflict
        // — `index = parentIndex` with no later rebind), while the source
        // is dead at TS level (reassigned each iteration before use).
        // Pointer/slice/struct values keep move semantics (a copy would
        // double-own the buffer). Temps are all heap-flagged, so decide by
        // scalar type instead of the flag.
        var src: []const u8 = val;
        if (self.loop_depth > 0 and !std.mem.eql(u8, name, val)) {
            if (self.scope_manager.lookup(val)) |sv| {
                const tn = sv.type_name;
                const scalar = std.mem.eql(u8, tn, "i32") or std.mem.eql(u8, tn, "u32") or
                    std.mem.eql(u8, tn, "number") or std.mem.eql(u8, tn, "boolean") or
                    std.mem.eql(u8, tn, "i64") or std.mem.eql(u8, tn, "u64");
                if (scalar) {
                    const tmp = try self.newTemp();
                    try self.lowerer.emit("    {s} = add {s}, 0\n", .{ tmp, val });
                    src = tmp;
                }
            }
        }
        if (!std.mem.eql(u8, name, src)) {
            try self.releaseOwnedIfLive(name);
            // Rebinding a live named variable needs the old value dead
            // first (RegisterRedefinition otherwise). Temps are excluded:
            // the backend rejects `!temp` in a block that already read it,
            // while `!named-var` verifies there. The fresh value rebinds
            // right below, so later reads see the new definition.
            if (self.scope_manager.lookup(name)) |nv| {
                if (!nv.is_heap_allocated and !nv.is_temp and !nv.is_consumed and !nv.is_released) {
                    try self.lowerer.emit("    !{s}\n", .{name});
                    nv.is_released = true;
                }
            }
            if (self.scope_manager.lookup(src)) |sv| {
                // Ownership transfer: a heap-owned source (e.g. a map/filter
                // result temp) moves its release obligation to the
                // destination. Without this `any`-typed (non-owned) receivers
                // like `matC = arr.map(...)` leak the buffer (MemoryLeak at
                // exit), because the consumed source is never released and
                // the destination is not tracked.
                const src_owned = sv.is_heap_allocated and !sv.is_consumed and !sv.is_released;
                self.scope_manager.markConsumed(src);
                if (src_owned) {
                    if (self.scope_manager.lookup(name)) |dv| dv.is_heap_allocated = true;
                }
            }
        }
        try self.lowerer.emit("    {s} = {s}\n", .{ name, src });
        self.markRebound(name);
    }

    /// Build a ready-future handle holding `val` (or zero), mirroring
    /// sa_plugin_sla's `genReadyFutureI64` / `FUTURE_READY_STATE_NEW`
    /// (`sa_std/core/future.sa`): a 16-byte heap struct with state 1 (READY)
    /// at +0 and the value at +8. The value store stays width-aware
    /// (`saTypeOf(inner)`) because TS futures carry typed values while the
    /// std macro hardcodes `u64`. Returns the owned future register.
    fn buildReadyFuture(self: *Parser, val: ?[]const u8, inner: []const u8) anyerror![]const u8 {
        const fut = try self.newTemp();
        const future_t = try futureTypeName(self.allocator, inner);
        defer self.allocator.free(future_t);
        if (self.scope_manager.lookup(fut)) |tv| {
            self.allocator.free(tv.type_name);
            tv.type_name = try self.allocator.dupe(u8, future_t);
        }
        try self.lowerer.emit("    {s} = alloc 16\n", .{fut});
        try self.lowerer.emit("    store {s} + 0, 1 as u64\n", .{fut});
        if (val) |v| {
            try self.lowerer.emit("    store {s} + 8, {s} as {s}\n", .{ fut, v, saTypeOf(inner) });
        } else {
            try self.lowerer.emit("    store {s} + 8, 0 as {s}\n", .{ fut, saTypeOf(inner) });
        }
        return fut;
    }

    /// Refuse to use a future handle as a plain value: it must be awaited
    /// first. Without this the handle pointer would silently flow into
    /// integer arithmetic or a non-future slot.
    fn rejectFutureOperand(self: *Parser, name: []const u8) anyerror!void {
        if (self.scope_manager.lookup(name)) |v| {
            if (isFutureType(v.type_name)) {
                std.debug.print("error:{d}:{d}: future '{s}' must be awaited before use as a value\n", .{
                    self.current.line,
                    self.current.col,
                    name,
                });
                return error.FutureMustBeAwaited;
            }
        }
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
        if ((self.current.tag == .keyword_let or self.current.tag == .keyword_const or self.current.tag == .keyword_var) and
            self.peek.tag == .identifier)
        {
            // Save state to check if 'of' follows the variable name
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;

            // Skip let/const/var and identifier to see if 'of' follows
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
                if (self.scope_manager.lookup(iterable)) |iv| {
                    if (isFutureType(iv.type_name)) {
                        std.debug.print("error:{d}:{d}: cannot iterate a future: await it first\n", .{
                            self.current.line,
                            self.current.col,
                        });
                        return error.FutureMustBeAwaited;
                    }
                }
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
                var fo_elem: []const u8 = "i32";
                if (self.scope_manager.lookup(iterable)) |iv2| {
                    // Strings iterate bytes (`for (const ch of word)` in the
                    // Trie): element type `u8` for a 1-byte stride. Slices
                    // strip one level as before.
                    if (std.mem.eql(u8, iv2.type_name, "string")) {
                        fo_elem = "u8";
                    } else {
                        fo_elem = elementTypeOf(iv2.type_name);
                    }
                }
                var fo_size: u32 = 4;
                var fo_align: u32 = 4;
                try getTypeSizeAndAlign(fo_elem, &fo_size, &fo_align);
                const fo_sa = saTypeOf(fo_elem);
                const ptr_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ptr_temp, iterable });
                const off_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off_temp, idx_var, fo_size });
                const addr_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, ptr_temp, off_temp });
                try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ iter_name, addr_temp, fo_sa });

                try self.scope_manager.enterScope();
                try self.scope_manager.declareVar(iter_name, fo_elem, iter_name, false);

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
                    // Single-statement body: same scope wrap as the braced path.
                    try self.scope_manager.enterScope();
                    try self.parseStatement();
                    try self.exitScopeReleasingLocals();
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
        if (self.current.tag == .keyword_let or self.current.tag == .keyword_const or self.current.tag == .keyword_var) {
            try self.parseLet();
        } else if (self.current.tag != .semicolon) {
            if (self.current.tag == .identifier and self.peek.tag == .equal) {
                // Assignment init with a pre-declared variable
                // (`let i; ...; for (i = 0; ...)`): a bare parseExpression
                // stops at `=`, so route through the assignment statement.
                try self.parseIdentifierStatement();
            } else {
                _ = try self.parseExpression();
                _ = try self.accept(.semicolon);
            }
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
            // Single-statement body: same scope wrap as the braced path.
            try self.scope_manager.enterScope();
            try self.parseStatement();
            try self.exitScopeReleasingLocals();
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
        // ASI: `return` followed by a newline and a statement keyword is a
        // bare return (`if (a === b) return` + next-line `if`). Those
        // keywords can never start an expression, so parsing one as the
        // return value only produces a cascade (`keyword_if` in expression).
        const bare = self.current.tag == .semicolon or self.current.tag == .r_brace or self.current.tag == .eof or switch (self.current.tag) {
            .keyword_if, .keyword_for, .keyword_while, .keyword_switch, .keyword_try, .keyword_return, .keyword_let, .keyword_const, .keyword_var, .keyword_break, .keyword_continue, .keyword_throw => true,
            else => false,
        };
        if (!bare) {
            // Evaluate first: the expression may read a local that is about to
            // be released, and releasing before the read is a use-after-move.
            const val = try self.parseExpression();
            // A value-return inside a void arrow callback cannot assemble
            // (`return <v>` in a `-> void` function). Refuse loudly with a
            // location instead of emitting invalid SA-ASM.
            if (self.arrow_depth > 0 and !self.arrow_value_cb and self.async_depth == 0) {
                std.debug.print("error:{d}:{d}: cannot return a value from a void arrow callback: use an expression body `x => x + 1` or add params so it declares `-> i32`\n", .{
                    self.current.line,
                    self.current.col,
                });
                return error.ValueReturnInVoidArrow;
            }
            if (self.async_depth > 0) {
                // Returning from an async function wraps the value in a
                // ready-future. Returning a future itself would nest handles,
                // which the subset cannot observe: refuse loudly.
                if (self.scope_manager.lookup(val)) |vv| {
                    if (isFutureType(vv.type_name)) {
                        std.debug.print("error:{d}:{d}: cannot return a future from an async function: await it first\n", .{
                            self.current.line,
                            self.current.col,
                        });
                        return error.NestedFuture;
                    }
                }
                try self.releaseLiveRegistersExcept(val);
                const fut = try self.buildReadyFuture(val, self.async_inner orelse "i32");
                try self.lowerer.emitTerm("    return {s}\n", .{fut});
            } else {
                if (self.scope_manager.lookup(val)) |vv| {
                    if (isFutureType(vv.type_name)) {
                        std.debug.print("error:{d}:{d}: async result must be awaited before returning it from a sync function\n", .{
                            self.current.line,
                            self.current.col,
                        });
                        return error.FutureMustBeAwaited;
                    }
                }
                // Inside an arrow callback only callback-owned registers may be
                // released; the parent's stay live for the outer function.
                if (self.arrow_depth > 0) {
                    try self.releaseArrowLiveExcept(val);
                } else {
                    try self.releaseLiveRegistersExcept(val);
                }
                try self.lowerer.emitTerm("    return {s}\n", .{val});
            }
        } else {
            if (self.async_depth > 0) {
                try self.releaseLiveRegisters();
                const fut = try self.buildReadyFuture(null, self.async_inner orelse "i32");
                try self.lowerer.emitTerm("    return {s}\n", .{fut});
            } else {
                // A bare `return` inside a value arrow (`-> i32`) must carry
                // a value or the backend rejects it. Normalise to `return 0`.
                if (self.arrow_depth > 0 and self.arrow_value_cb) {
                    try self.releaseArrowLive();
                    try self.lowerer.emitTerm("    return 0\n", .{});
                } else {
                try self.releaseLiveRegisters();
                try self.lowerer.emitTerm("    return\n", .{});
                }
            }
        }
        _ = try self.accept(.semicolon);
    }

    // ==========================================
    // Try / Catch / Throw
    // ==========================================

    fn parseTryCatch(self: *Parser) anyerror!void {
        try self.expect(.keyword_try);

        // SA-ASM has no exception edges and `throw` lowers to `panic`, which
        // aborts: a `catch` block can never resume after a real throw. The
        // previous lowering emitted the catch body as fallthrough code, so it
        // ran even when nothing threw. Scan first: a `try` whose body cannot
        // throw runs the body and skips `catch` entirely; a `throw` inside
        // is refused loudly instead of miscompiled.
        const has_throw = blk: {
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            const saved_tpl_mode = self.template_lexer_mode;
            var found = false;
            var depth: i32 = 0;
            while (true) {
                if (self.current.tag == .eof) break;
                if (self.current.tag == .l_brace) depth += 1;
                if (self.current.tag == .r_brace) {
                    depth -= 1;
                    if (depth == 0) break;
                }
                if (self.current.tag == .keyword_throw and depth >= 1) {
                    found = true;
                    break;
                }
                try self.advance();
            }
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
            self.template_lexer_mode = saved_tpl_mode;
            break :blk found;
        };
        if (has_throw) {
            std.debug.print("error:{d}:{d}: throw inside try: catch cannot resume after panic, so this try/catch cannot be lowered\n", .{
                self.current.line,
                self.current.col,
            });
            return error.ThrowInTry;
        }

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
            // The scope pops here, so the function-exit walk can never see
            // the body's temps: release them on the fallthrough path now
            // (same as a branch-arm block close). Skipped automatically when
            // the body ends in `return`/`break`/`continue`.
            try self.exitScopeReleasingLocals();
            try self.advance();
        }

        // The body may already end in a terminator (`return`); a jump after
        // one is unreachable code the assembler rejects.
        if (!self.lowerer.isTerminated()) {
            try self.lowerer.emitJumpTo(end_label);
        }
        try self.lowerer.emitLabel(catch_label);

        if (self.current.tag == .keyword_catch) {
            // No `throw` can reach here, so the handler is dead code: skip
            // its tokens without emitting anything. Emitting it would run
            // the handler unconditionally as fallthrough.
            try self.advance(); // catch
            if (self.current.tag == .l_paren) {
                var depth: u32 = 1;
                try self.advance();
                while (depth > 0 and self.current.tag != .eof) {
                    if (self.current.tag == .l_paren) depth += 1;
                    if (self.current.tag == .r_paren) depth -= 1;
                    try self.advance();
                }
            }
            if (self.current.tag == .l_brace) {
                var depth: u32 = 1;
                try self.advance();
                while (depth > 0 and self.current.tag != .eof) {
                    if (self.current.tag == .l_brace) depth += 1;
                    if (self.current.tag == .r_brace) depth -= 1;
                    try self.advance();
                }
            }
        }

        try self.lowerer.emitLabel(end_label);
    }

    fn parseThrow(self: *Parser) anyerror!void {
        try self.expect(.keyword_throw);
        const val = try self.parseExpression();
        _ = try self.accept(.semicolon);
        // SA-ASM has no `throw`: its closest terminator is the `panic(code)`
        // call form (mirroring sa_plugin_sla's `panic(1)`/`panic(87)`; the bare
        // `panic reg` instruction shape is rejected with ForbiddenSyntax).
        // `try`/`catch` therefore cannot reproduce JS exception semantics and
        // lower to a jump-based approximation. `panic` aborts, so the dead
        // `val` needs no release.
        _ = val;
        try self.lowerer.emitTerm("    panic(1)\n", .{});
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
            // WIT file import: `@wit_import` is not valid SA-ASM (the
            // assembler rejects it with ForbiddenSyntax even at top level, as
            // probed), so refuse loudly with a located diagnostic and emit no
            // directive. Symbols are still declared and tracked so any later
            // call is refused at the call site instead of assembling to an
            // undeclared callee.
            const first_sym: []const u8 = if (symbols.items.len > 0) symbols.items[0] else "(symbols)";
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "error: WIT import of '{s}' from \"{s}\" is not lowerable to SA-ASM: the assembler accepts no @wit_import directive",
                .{ first_sym, path },
            );
            try self.errors.append(.{
                .line = path_tok.line,
                .col = path_tok.col,
                .message = msg,
            });
            std.debug.print("error:{d}:{d}: {s}\n", .{ path_tok.line, path_tok.col, msg });
            for (symbols.items) |sym| {
                try self.scope_manager.declareVar(sym, "fn", sym, false);
                const key = try self.allocator.dupe(u8, sym);
                try self.wit_syms.put(key, {});
            }
            return error.WitImportNotSupported;
        } else if (std.mem.endsWith(u8, path, ".wasm")) {
            try self.lowerer.emit("    // WASM Interop: Import from {s}\n", .{path});
            for (symbols.items) |sym| {
                try self.scope_manager.declareVar(sym, "fn", sym, false);
                try self.lowerer.emit("    // Link symbol {s} to WASM export\n", .{sym});
                // Tracked so the first call site can declare an arity-matched
                // `@extern` in the header (probes: the verifier accepts the
                // callee then; linking needs the real `.wasm`). An explicit
                // `declare function` for the same name suppresses it.
                const key = try self.allocator.dupe(u8, sym);
                try self.wasm_syms.put(key, {});
            }
        } else if (path.len > 0 and path[0] == '.') {
            // Relative TS module (`./map`, `../stack/stack`): resolve the
            // file against the entry dir and parse it into the shared
            // tables (SLA whole-program style), so cross-file classes
            // resolve. A missing file stays loud at its use sites instead
            // of aborting the whole compile.
            self.parseRelativeImport(path) catch |err| {
                if (err == error.FileNotFound) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "warning: cannot resolve relative import \"{s}\" from \"{s}\": skipped (upstream import; uses stay loud)",
                        .{ path, self.base_dir },
                    );
                    try self.errors.append(.{ .line = path_tok.line, .col = path_tok.col, .message = msg });
                    std.debug.print("warning:{d}:{d}: {s}\n", .{ path_tok.line, path_tok.col, msg });
                    return;
                }
                return err;
            };
        }
    }

    /// Resolve a relative TS import to a file: `p`, `p.ts`, `p/index.ts`
    /// against `base_dir` (SLA `resolveImportFile` shape, TS flavored).
    /// Returned paths are lexically normalized (`a/./b` -> `a/b`) so the
    /// cycle guard sees one identity per file even across nested dirs.
    fn resolveRelativePath(self: *Parser, path: []const u8) anyerror![]const u8 {
        const suffixes = [_][]const u8{ "", ".ts", "/index.ts" };
        for (suffixes) |suf| {
            const raw = try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ self.base_dir, path, suf });
            defer self.allocator.free(raw);
            const cand = try self.normalizePath(raw);
            std.fs.cwd().access(cand, .{}) catch {
                self.allocator.free(cand);
                continue;
            };
            return cand;
        }
        return error.FileNotFound;
    }

    /// Lexically normalize a `/`-joined path (`a/./b` -> `a/b`,
    /// `a/x/../b` -> `a/b`), so import identities are stable.
    fn normalizePath(self: *Parser, path: []const u8) anyerror![]const u8 {
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        var it = std.mem.splitScalar(u8, path, '/');
        const absolute = path.len > 0 and path[0] == '/';
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (parts.items.len > 0) _ = parts.pop();
                continue;
            }
            try parts.append(seg);
        }
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        if (absolute) try out.append('/');
        for (parts.items, 0..) |p, i| {
            if (i > 0) try out.append('/');
            try out.appendSlice(p);
        }
        return out.toOwnedSlice();
    }

    /// Parse an imported TS file into the shared layout/method tables and
    /// emit its declarations (SLA whole-program compile). The cycle/diamond
    /// guard keeps each file parsed once; nested imports resolve against
    /// the imported file's own directory.
    fn parseRelativeImport(self: *Parser, path: []const u8) anyerror!void {
        const resolved = try self.resolveRelativePath(path);
        defer self.allocator.free(resolved);
        if (self.imported_files.contains(resolved)) return;
        try self.imported_files.put(try self.allocator.dupe(u8, resolved), {});
        const content = std.fs.cwd().readFileAlloc(self.allocator, resolved, 4 * 1024 * 1024) catch return error.FileNotFound;
        defer self.allocator.free(content);

        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_peek = self.peek;
        const saved_tpl = self.template_lexer_mode;
        const saved_dir = self.base_dir;
        errdefer {
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
            self.template_lexer_mode = saved_tpl;
            self.base_dir = saved_dir;
            self.collect_only = false;
        }
        self.base_dir = std.fs.path.dirname(resolved) orelse ".";

        self.lexer = lexer_mod.Lexer{ .source = content };
        self.current = self.lexer.next();
        self.peek = self.lexer.next();
        self.template_lexer_mode = false;
        // Forward-reference collection pass (mirror parse()).
        self.collect_only = true;
        while (self.current.tag != .eof) {
            if (self.current.tag == .keyword_class) {
                self.parseClass() catch {
                    self.skipToSync();
                };
            } else if (self.current.tag == .keyword_interface) {
                self.parseInterface() catch {
                    self.skipToSync();
                };
            } else if (self.current.tag == .identifier and std.mem.eql(u8, self.currentText(), "export")) {
                try self.advance();
                // `export abstract class`: the modifier sits between.
                while (self.current.tag == .keyword_abstract) try self.advance();
                if (self.current.tag == .keyword_class) {
                    self.parseClass() catch {
                        self.skipToSync();
                    };
                } else if (self.current.tag == .keyword_interface) {
                    self.parseInterface() catch {
                        self.skipToSync();
                    };
                }
            } else {
                try self.advance();
            }
        }
        self.collect_only = false;
        // Real pass: declarations emit into the shared output.
        self.lexer = lexer_mod.Lexer{ .source = content };
        self.current = self.lexer.next();
        self.peek = self.lexer.next();
        self.template_lexer_mode = false;
        try self.scope_manager.enterScope();
        const saved_import_base = self.import_base_depth;
        self.import_base_depth = self.scope_manager.scopeDepth() - 1;
        defer self.import_base_depth = saved_import_base;
        while (self.current.tag != .eof) {
            self.parseStatement() catch |err| {
                if (err == error.UnexpectedToken) continue;
                const msg = try std.fmt.allocPrint(self.allocator, "error: {}", .{err});
                try self.errors.append(.{ .line = self.current.line, .col = self.current.col, .message = msg });
                self.skipToSync();
            };
        }
        try self.scope_manager.exitScope(self.lowerer);

        self.lexer = saved_lexer;
        self.current = saved_current;
        self.peek = saved_peek;
        self.template_lexer_mode = saved_tpl;
        self.base_dir = saved_dir;
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
        // An explicit signature wins over the synthetic arity-matched extern
        // a `.wasm` import would otherwise declare at the first call site.
        const dkey = try self.allocator.dupe(u8, func_name);
        try self.declared_externs.put(dkey, {});
    }

    /// Declare the arity-matched `@extern` for a `.wasm` import at its first
    /// call site, unless an explicit `declare function` already covers it.
    fn ensureWasmExtern(self: *Parser, name: []const u8, arity: usize) anyerror!void {
        if (self.wasm_syms.get(name) == null) return;
        if (self.declared_externs.get(name) != null) return;
        try self.lowerer.emitExtern(name, arity);
    }

    /// Refuse a call to a `.wit` symbol loudly: there is no valid lowering.
    fn rejectWitCall(self: *Parser, name: []const u8) anyerror!void {
        if (self.wit_syms.get(name) == null) return;
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "error: call to WIT symbol '{s}' cannot be lowered to SA-ASM: the assembler accepts no @wit_import directive",
            .{name},
        );
        try self.errors.append(.{
            .line = self.current.line,
            .col = self.current.col,
            .message = msg,
        });
        std.debug.print("error:{d}:{d}: {s}\n", .{ self.current.line, self.current.col, msg });
        return error.WitCallNotSupported;
    }

    // ==========================================
    // Identifier statement (assignment, call, etc.)
    // ==========================================




    /// Lower a template literal to an SA-ASM string slice.
    ///
    /// An SA-ASM string is a `{ptr, len}` slice, not a literal: a string cannot
    /// be written as an operand. A literal is therefore materialised as a
    /// file-scope `@const NAME = utf8:"..."` data constant, then assembled into
    /// a slice with a 16-byte heap slot (this is what `SLICE_NEW` expands to,
    /// but `alloc` is used so the slice can escape its function).
    ///
    /// Templates with `${...}` interpolation render each value to text and
    /// join the chunks. Integer operands go through `sext` +
    /// `@sa_fmt_i64_into` (from `sa_std/fmt.sai`); string operands are
    /// already slices and pass through untouched. Chunks are joined with the
    /// body of stdlib's `STR_CONCAT` macro inlined (`@sa_string_concat` from
    /// `sa_std/string.sai`, whose buffer handle is read back with
    /// `@sa_fmt_buffer_data`/`@sa_fmt_buffer_len`). Boolean operands render
    /// as `0`/`1`, matching the subset's i32 encoding rather than JS
    /// `true`/`false`; floats and other types are refused loudly.
    fn parseTemplateLiteral(self: *Parser) anyerror![]const u8 {
        const raw = self.currentText();

        if (self.current.tag != .template_end) {
            return try self.parseInterpolatedTemplate();
        }

        // Strip the surrounding backticks; the lexer spans both.
        var text = raw;
        if (text.len >= 2 and text[0] == '`' and text[text.len - 1] == '`') {
            text = text[1 .. text.len - 1];
        }

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
        // the slice can be bound to a variable (see `materializeStringChunk`).
        const slice_reg = try self.materializeStringChunk(text);

        return slice_reg;
    }

    /// Materialise static text as an SA string slice: a file-scope `@const`
    /// plus a 16-byte heap slot holding `{ptr, len}`. The result is retagged
    /// `string` so interpolation and member paths treat it as a slice.
    fn materializeStringChunk(self: *Parser, text: []const u8) anyerror![]const u8 {
        const const_id = self.nextLabelId();
        const const_name = try std.fmt.allocPrint(self.allocator, "SC_{d}", .{const_id});
        try self.lowerer.emitConst(const_name, text);

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
        try self.retagTemp(slice_reg, "string");

        return slice_reg;
    }

    /// Retag a `newTemp` register with its real source-level type. Temps
    /// default to `i32`; string slices (and only real strings) must read back
    /// as `string` so interpolation passes them through instead of rendering
    /// their pointer as digits.
    fn retagTemp(self: *Parser, reg: []const u8, type_name: []const u8) anyerror!void {
        if (self.scope_manager.lookup(reg)) |tv| {
            self.allocator.free(tv.type_name);
            tv.type_name = try self.allocator.dupe(u8, type_name);
        }
    }

    /// Whether `val` holds a string slice (for the string-`slice` guard:
    /// the unguarded branch used to hijack `array.slice(...)` calls).
    fn isStringOperand(self: *Parser, val: []const u8) bool {
        if (val.len >= 2 and (val[0] == '"' or val[0] == '\'')) return true;
        if (self.scope_manager.lookup(val)) |v| {
            return std.mem.eql(u8, v.type_name, "string");
        }
        return false;
    }

    /// Whether `name` holds a native `Map` (lowered to sa_std/btree_map).
    fn isMapVar(self: *Parser, name: []const u8) bool {
        if (self.scope_manager.lookup(name)) |v| {
            // `Record<K, V>` parses to the base name `Record` (generics are
            // stripped for layout); both spellings hold btree handles.
            return std.mem.eql(u8, v.type_name, "Map") or std.mem.eql(u8, v.type_name, "Record");
        }
        return false;
    }

    /// Whether `name` holds a TS `Set` (lowered to `sa_std/btree_set`, the
    /// same key-slice encoding as `Map`).
    fn isSetVar(self: *Parser, name: []const u8) bool {
        if (self.scope_manager.lookup(name)) |v| {
            return std.mem.eql(u8, v.type_name, "Set");
        }
        return false;
    }

    /// Wrap a method-call key operand as the `&key: ptr` slice that
    /// `sa_btree_map_*` expects (`{ptr,len}` at +0/+8, byte-compared).
    /// String operands already lower to slice headers and pass through;
    /// integer operands are boxed into a 4-byte slice header on the fly.
    fn mapKeySlice(self: *Parser, key: []const u8) anyerror![]const u8 {
        // Quoted literals (`"a"`, `'a'`) materialise as real `{ptr,len}`
        // string slices; only then do byte-compared lookups match. Without
        // this, a literal fell into the integer box below and emitted
        // `store bytes + 0, "a" as i32`, which the assembler rejects.
        if (key.len >= 2 and (key[0] == '"' or key[0] == '\'') and key[key.len - 1] == key[0]) {
            return try self.materializeStringChunk(key[1 .. key.len - 1]);
        }
        if (self.scope_manager.lookup(key)) |v| {
            if (std.mem.eql(u8, v.type_name, "string")) return key;
        }
        // Single bytes (`for (const ch of str)` binds `u8`): a 1-byte key
        // slice, so byte-iteration keys match each other on lookup.
        if (self.scope_manager.lookup(key)) |v| {
            if (std.mem.eql(u8, v.type_name, "u8")) {
                const bytes = try self.newTemp();
                try self.lowerer.emit("    {s} = alloc 8\n", .{bytes});
                try self.lowerer.emit("    store {s} + 0, {s} as u8\n", .{ bytes, key });
                const slice = try self.newTemp();
                try self.lowerer.emit("    {s} = alloc 16\n", .{slice});
                try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slice, bytes });
                try self.lowerer.emit("    store {s} + 8, 1 as u64\n", .{slice});
                return slice;
            }
        }
        const bytes = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 8\n", .{bytes});
        try self.lowerer.emit("    store {s} + 0, {s} as i32\n", .{ bytes, key });
        const slice = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 16\n", .{slice});
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slice, bytes });
        try self.lowerer.emit("    store {s} + 8, 4 as u64\n", .{slice});
        return slice;
    }

    /// Expression-level native `Map` method call. `left` must be Map-typed;
    /// returns a temp holding the result (or "0" for void methods).
    fn lowerMapMethodCall(self: *Parser, left: []const u8, member_name: []const u8) anyerror![]const u8 {
        try self.lowerer.emitImport("sa_std/btree_map.sa");
        if (std.mem.eql(u8, member_name, "set")) {
            try self.expect(.l_paren);
            const k = try self.parseExpression();
            try self.expect(.comma);
            const v = try self.parseExpression();
            try self.expect(.r_paren);
            const ks = try self.mapKeySlice(k);
            try self.lowerer.emit("    call @sa_btree_map_insert(&{s}, &{s}, {s})\n", .{ left, ks, v });
            return "0";
        }
        if (std.mem.eql(u8, member_name, "get")) {
            try self.expect(.l_paren);
            const k = try self.parseExpression();
            try self.expect(.r_paren);
            const ks = try self.mapKeySlice(k);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_get(&{s}, &{s})\n", .{ t, left, ks });
            return t;
        }
        if (std.mem.eql(u8, member_name, "has")) {
            try self.expect(.l_paren);
            const k = try self.parseExpression();
            try self.expect(.r_paren);
            const ks = try self.mapKeySlice(k);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_contains_key(&{s}, &{s})\n", .{ t, left, ks });
            return t;
        }
        if (std.mem.eql(u8, member_name, "delete")) {
            try self.expect(.l_paren);
            const k = try self.parseExpression();
            try self.expect(.r_paren);
            const ks = try self.mapKeySlice(k);
            // `sa_btree_map_remove` returns the removed u64 payload (0 on
            // miss), but JS `delete` returns a boolean. Probe presence first
            // so a stored `0` still reports `true`: exact boolean semantics
            // for one extra lookup.
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_contains_key(&{s}, &{s})\n", .{ t, left, ks });
            const scratch = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_remove(&{s}, &{s})\n", .{ scratch, left, ks });
            return t;
        }
        if (std.mem.eql(u8, member_name, "clear")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.lowerer.emit("    call @sa_btree_map_clear(&{s})\n", .{left});
            return "0";
        }
        if (std.mem.eql(u8, member_name, "size")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_len(&{s})\n", .{ t, left });
            return t;
        }
        if (std.mem.eql(u8, member_name, "getSize")) {
            // Talgo `Map` spelling of `size` (map_set `getSize()`).
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_len(&{s})\n", .{ t, left });
            return t;
        }
        if (std.mem.eql(u8, member_name, "keys")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_keys_set(&{s})\n", .{ t, left });
            return t;
        }
        if (std.mem.eql(u8, member_name, "values")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_values_vec(&{s})\n", .{ t, left });
            return t;
        }
        if (std.mem.eql(u8, member_name, "entries")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_iter_vec(&{s})\n", .{ t, left });
            return t;
        }
        return error.UnknownMethod;
    }

    /// Expression-level native `Set` method call. `left` must be Set-typed;
    /// key encoding is shared with `Map` (`mapKeySlice`). Returns a temp
    /// holding the result (or "0" for void methods).
    fn lowerSetMethodCall(self: *Parser, left: []const u8, member_name: []const u8) anyerror![]const u8 {
        try self.lowerer.emitImport("sa_std/btree_set.sa");
        if (std.mem.eql(u8, member_name, "add")) {
            try self.expect(.l_paren);
            const k = try self.parseExpression();
            try self.expect(.r_paren);
            const ks = try self.mapKeySlice(k);
            try self.lowerer.emit("    call @sa_btree_set_insert(&{s}, &{s})\n", .{ left, ks });
            return "0";
        }
        if (std.mem.eql(u8, member_name, "has")) {
            try self.expect(.l_paren);
            const k = try self.parseExpression();
            try self.expect(.r_paren);
            const ks = try self.mapKeySlice(k);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_set_contains(&{s}, &{s})\n", .{ t, left, ks });
            return t;
        }
        if (std.mem.eql(u8, member_name, "delete")) {
            try self.expect(.l_paren);
            const k = try self.parseExpression();
            try self.expect(.r_paren);
            const ks = try self.mapKeySlice(k);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_set_contains(&{s}, &{s})\n", .{ t, left, ks });
            const scratch = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_set_remove(&{s}, &{s})\n", .{ scratch, left, ks });
            return t;
        }
        if (std.mem.eql(u8, member_name, "clear")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.lowerer.emit("    call @sa_btree_set_clear(&{s})\n", .{left});
            return "0";
        }
        if (std.mem.eql(u8, member_name, "size")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            const t = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_set_len(&{s})\n", .{ t, left });
            return t;
        }
        return error.UnknownMethod;
    }

    /// Whether `name` holds a TS array slice (`T[]...`, lowered to the
    /// 16-byte `{ptr,len}` header).
    fn isArrayVar(self: *Parser, name: []const u8) bool {
        if (self.scope_manager.lookup(name)) |v| {
            return isArrayType(v.type_name);
        }
        return false;
    }

    /// Grow-copy push: `arr.push(v)`.
    ///
    /// Slices carry no capacity, so every push allocates `(len+1)*esz`,
    /// copies the old elements, appends `v`, and swaps the header. O(n)
    /// per push, but always correct (the old fixed-buffer code silently
    /// dropped pushes / overflowed `[]`-seeded arrays).
    /// Shared array-construction emitters (`new Array(n)` and the `Array(n)`
    /// call form lower identically). Literal lengths unroll zero stores;
    /// register lengths use `mul` + register-sized `alloc` + `sa_mem_set`.
    /// `zero=false` skips the fill (the caller overwrites every slot, e.g.
    /// `Array.from` with a mapper). `dest` must be a fresh temp; retagged
    /// to the array type here.
    fn emitArrayAllocLit(self: *Parser, dest: []const u8, elem_type: []const u8, count: u32) anyerror!void {
        // Tag the header with the full array type (`number[]`), like array
        // literals: member dispatch (`isArrayVar`) and indexing derive the
        // element by stripping one level. A bare `i32` tag made chained
        // calls on construction temps (`Array(n).fill(1)`) miss the Array
        // path and silently drop the call.
        const arr_type = try std.fmt.allocPrint(self.allocator, "{s}[]", .{elem_type});
        try self.retagTemp(dest, arr_type);
        try self.lowerer.emit("    {s} = alloc 16\n", .{dest});
        var elem_size: u32 = 4;
        var elem_align: u32 = 4;
        try getTypeSizeAndAlign(elem_type, &elem_size, &elem_align);
        const data_reg = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc {d}\n", .{ data_reg, @max(count * elem_size, 4) });
        var idx: u32 = 0;
        while (idx < count) : (idx += 1) {
            const off = idx * elem_size;
            try self.lowerer.emit("    store {s} + {d}, 0 as {s}\n", .{ data_reg, off, saTypeOf(elem_type) });
        }
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ dest, data_reg });
        try self.lowerer.emit("    store {s} + 8, {d} as u64\n", .{ dest, count });
    }

    fn emitArrayAllocReg(self: *Parser, dest: []const u8, elem_type: []const u8, n_reg: []const u8, zero: bool) anyerror!void {
        const arr_type = try std.fmt.allocPrint(self.allocator, "{s}[]", .{elem_type});
        try self.retagTemp(dest, arr_type);
        var elem_size: u32 = 4;
        var elem_align: u32 = 4;
        try getTypeSizeAndAlign(elem_type, &elem_size, &elem_align);
        try self.lowerer.emit("    {s} = alloc 16\n", .{dest});
        const bytes_reg = try self.newTemp();
        try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ bytes_reg, n_reg, elem_size });
        const data_reg = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc {s}\n", .{ data_reg, bytes_reg });
        if (zero) {
            try self.lowerer.emitImport("sa_std/core/mem.sa");
            try self.lowerer.emit("    call @sa_mem_set(&{s}, 0, {s})\n", .{ data_reg, bytes_reg });
        }
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ dest, data_reg });
        try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ dest, n_reg });
    }

    /// `Array.from({length: n}, mapper?)`: allocate `n` slots, then call
    /// `mapper(0, i)` per index and store the result. No mapper means a
    /// zeroed array (same as the dynamic `new Array(n)` path). Only the
    /// `{length: <expr>}` shape is accepted; other array-likes are loud
    /// errors. Element type is the `i32` default (numeric mappers — the
    /// Talgo `(_, index) => index` shape); the mapper's first slot gets
    /// `0` (element is undefined for a fresh array), the second the index.
    /// Cursor must be on `(` after `Array.from`; consumes the full call.
    fn lowerArrayFrom(self: *Parser) anyerror![]const u8 {
        try self.expect(.l_paren);
        if (self.current.tag != .l_brace) {
            return self.refuseAt(
                "error: Array.from only supports the {{length: n}} shape",
                .{},
                error.ConstructorsNotSupported,
            );
        }
        try self.advance();
        const key_tok = self.current;
        try self.expect(.identifier);
        if (!std.mem.eql(u8, self.tokenText(key_tok), "length")) {
            return self.refuseAt(
                "error: Array.from only supports the {{length: n}} shape",
                .{},
                error.ConstructorsNotSupported,
            );
        }
        try self.expect(.colon);
        const n_reg = try self.parseExpression();
        try self.expect(.r_brace);
        var cb: ?[]const u8 = null;
        var map_ctx: ?[]const u8 = null;
        var map_arity: u8 = 0;
        var map_self_call = false;
        if (try self.accept(.comma)) {
            const m = try self.parseExpression();
            if (std.mem.startsWith(u8, m, "@")) {
                // Inline arrow: parseArrowBody registered ctx/arity.
                cb = m;
                const raw = self.last_arrow_ctx orelse "^ctx";
                map_ctx = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                map_arity = self.last_arrow_arity;
            } else if (self.arrow_aliases.get(m)) |aarg| {
                if (aarg.plain) {
                    return self.refuseAt(
                        "error: Array.from mapper must take a context",
                        .{},
                        error.PlainFunctionAsValue,
                    );
                }
                cb = aarg.cb;
                const raw = aarg.ctx;
                map_ctx = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                map_arity = aarg.arity;
                map_self_call = aarg.self_call;
            } else {
                return self.refuseAt(
                    "error: Array.from mapper must be an arrow function",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
        }
        try self.expect(.r_paren);
        const dest = try self.newTemp();
        try self.emitArrayAllocReg(dest, "i32", n_reg, false);
        if (cb == null) return dest;
        const data = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, dest });
        const id = self.nextLabelId();
        const l_top = try std.fmt.allocPrint(self.allocator, "L_from_top_{d}", .{id});
        const l_body = try std.fmt.allocPrint(self.allocator, "L_from_body_{d}", .{id});
        const l_end = try std.fmt.allocPrint(self.allocator, "L_from_end_{d}", .{id});
        try self.lowerer.reserveLabel(l_top);
        try self.lowerer.reserveLabel(l_body);
        try self.lowerer.reserveLabel(l_end);
        const i = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{i});
        try self.lowerer.emitLabel(l_top);
        const c = try self.newTemp();
        try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, n_reg });
        try self.lowerer.emitBranchTo(c, l_body, l_end);
        try self.lowerer.emitLabel(l_body);
        // Mapper args: element slot is `0` (fresh array), index slot is
        // `i`, any further slots are `0`.
        var arg_buf = std.ArrayList(u8).init(self.allocator);
        defer arg_buf.deinit();
        var slot: u8 = 0;
        while (slot < @max(map_arity, 1)) : (slot += 1) {
            if (slot > 0) try arg_buf.appendSlice(", ");
            if (slot == 1) {
                try arg_buf.appendSlice(i);
            } else {
                try arg_buf.appendSlice("0");
            }
        }
        const v = try self.newTemp();
        if (arg_buf.items.len == 0) {
                try self.lowerer.emit("    {s} = call @{s}({s})\n", .{ v, cb.?[1..], map_ctx.? });
            } else {
                try self.lowerer.emit("    {s} = call @{s}({s}, {s})\n", .{ v, cb.?[1..], arg_buf.items, map_ctx.? });
            }
        const off = try self.newTemp();
        try self.lowerer.emit("    {s} = mul {s}, 4\n", .{ off, i });
        const addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, off });
        try self.lowerer.emit("    store {s} + 0, {s} as i32\n", .{ addr, v });
        const inext = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
        try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
        self.scope_manager.markConsumed(inext);
        try self.lowerer.emitJumpTo(l_top);
        try self.lowerer.emitLabel(l_end);
        // Caller-side context release, once (not per iteration): mirrors
        // the alias direct-call borrow rule.
        if (!map_self_call) try self.lowerer.emit("    !{s}\n", .{map_ctx.?});
        self.last_arrow_ctx = null;
        return dest;
    }

    /// Indirect call through an `fn`-typed field (`this.compare(a, b)`):
    /// the field holds a code pointer (vtable-materialized at the arrow
    /// decay site). A fresh empty context is passed, so only captureless
    /// callbacks are valid callees (enforced where the pointer is made).
    /// Returns a temp holding the `i32` result.
    fn lowerFnFieldCall(self: *Parser, left: []const u8, off: u32) anyerror![]const u8 {
        try self.expect(.l_paren);
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const a = try self.parseExpression();
            try args.append(try self.argReg(a));
            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);
        const f = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + {d} as ptr\n", .{ f, left, off });
        const ctx = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 8\n", .{ctx});
        const v = try self.newTemp();
        try self.lowerer.emit("    {s} = call_indirect {s}(", .{ v, f });
        for (args.items) |a| {
            try self.lowerer.emit("{s}, ", .{a});
        }
        try self.lowerer.emit("{s})\n", .{ctx});
        // No explicit context release: unlike direct calls (borrow), an
        // indirect call moves its operands, so the fresh box is consumed
        // by the call itself (a `!ctx` here is UseAfterMove).
        return v;
    }

    /// Offset of `member` in `left`'s layout when it is an `fn`-typed
    /// field (type text contains `=>`), else null (normal paths apply).
    fn fnFieldOffset(self: *Parser, left: []const u8, member: []const u8) ?u32 {
        const lv = self.scope_manager.lookup(left) orelse return null;
        const layout = self.layout_table.find(lv.type_name) orelse return null;
        for (layout.fields.items) |fld| {
            if (std.mem.eql(u8, fld.name, member)) {
                // `fn`-typed fields (layout pre-scan normalizes arrow
                // types to the literal `"fn"`) hold code pointers.
                if (std.mem.eql(u8, fld.type_name, "fn") or std.mem.indexOf(u8, fld.type_name, "=>") != null) return fld.offset;
                return null;
            }
        }
        return null;
    }

    /// Replay recorded field initializers (`= <src>`) as stores into a
    /// fresh instance. Runs at the start of explicit ctors (before the
    /// body, after property stores) and in synthesized default ctors.
    /// `{...}` inits are skipped (Map/Record fields already hold fresh
    /// btree handles from the `new` site); everything else re-parses from
    /// the recorded source (arrow inits materialize through the fn-ptr
    /// helper, like parameter defaults).
    fn replayFieldInits(self: *Parser, class_name: []const u8) anyerror!void {
        const layout = self.layout_table.find(class_name) orelse return;
        for (layout.fields.items) |fld| {
            const fkey = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, fld.name });
            const src = self.field_inits.get(fkey) orelse continue;
            const trimmed = std.mem.trim(u8, src, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '{') continue;
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            const saved_tpl = self.template_lexer_mode;
            const saved_ctx = self.last_arrow_ctx;
            self.last_arrow_ctx = null;
            self.lexer = lexer_mod.Lexer{ .source = src };
            self.current = self.lexer.next();
            self.peek = self.lexer.next();
            self.template_lexer_mode = false;
            const v = try self.parseExpression();
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
            self.template_lexer_mode = saved_tpl;
            if (std.mem.startsWith(u8, v, "@closure_callback_")) {
                const fpreg = try self.fnPtrForCb(v);
                if (self.last_arrow_ctx) |actx| {
                    const borrow = if (actx.len > 0 and actx[0] == '^') actx[1..] else actx;
                    try self.lowerer.emit("    !{s}\n", .{borrow});
                }
                self.last_arrow_ctx = saved_ctx;
                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ "this", fld.offset, fpreg, saTypeOf(fld.type_name) });
                continue;
            }
            self.last_arrow_ctx = saved_ctx;
            try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ "this", fld.offset, v, saTypeOf(fld.type_name) });
        }
    }

    fn lowerArrayPush(self: *Parser, arr: []const u8, val: []const u8) anyerror![]const u8 {
        var elem_type: []const u8 = "i32";
        if (self.scope_manager.lookup(arr)) |av| {
            elem_type = elementTypeOf(av.type_name);
        }
        var esz: u32 = 4;
        var eal: u32 = 4;
        try getTypeSizeAndAlign(elem_type, &esz, &eal);
        const sa_elem = saTypeOf(elem_type);
        const len = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, arr });
        const data = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, arr });
        const new_len = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ new_len, len });
        const nbytes = try self.newTemp();
        try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ nbytes, new_len, esz });
        const new_data = try self.newTemp();
        const id = self.nextLabelId();
        const alloc_ok = try std.fmt.allocPrint(self.allocator, "L_push_alloc_{d}", .{id});
        const alloc_empty = try std.fmt.allocPrint(self.allocator, "L_push_empty_{d}", .{id});
        const alloc_done = try std.fmt.allocPrint(self.allocator, "L_push_done_{d}", .{id});
        try self.lowerer.reserveLabel(alloc_ok);
        try self.lowerer.reserveLabel(alloc_empty);
        try self.lowerer.reserveLabel(alloc_done);
        const is_empty = try self.newTemp();
        try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ is_empty, nbytes });
        try self.lowerer.emitBranchTo(is_empty, alloc_empty, alloc_ok);
        try self.lowerer.emitLabel(alloc_empty);
        try self.lowerer.emit("    {s} = alloc 4\n", .{new_data});
        try self.lowerer.emitJumpTo(alloc_done);
        try self.lowerer.emitLabel(alloc_ok);
        try self.lowerer.emit("    {s} = alloc {s}\n", .{ new_data, nbytes });
        try self.lowerer.emitLabel(alloc_done);
        const i = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{i});
        const l_copy = try std.fmt.allocPrint(self.allocator, "L_push_copy_{d}", .{id});
        const l_body = try std.fmt.allocPrint(self.allocator, "L_push_body_{d}", .{id});
        const l_end = try std.fmt.allocPrint(self.allocator, "L_push_end_{d}", .{id});
        try self.lowerer.reserveLabel(l_copy);
        try self.lowerer.reserveLabel(l_body);
        try self.lowerer.reserveLabel(l_end);
        try self.lowerer.emitLabel(l_copy);
        const c = try self.newTemp();
        try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
        try self.lowerer.emitBranchTo(c, l_body, l_end);
        try self.lowerer.emitLabel(l_body);
        const s_off = try self.newTemp();
        try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ s_off, i, esz });
        const s_addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ s_addr, data, s_off });
        const tmp = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ tmp, s_addr, sa_elem });
        const d_addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ d_addr, new_data, s_off });
        try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ d_addr, tmp, sa_elem });
        const inext = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
        try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
        self.scope_manager.markConsumed(inext);
        try self.lowerer.emitJumpTo(l_copy);
        try self.lowerer.emitLabel(l_end);
        const a_off = try self.newTemp();
        try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ a_off, len, esz });
        const a_addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ a_addr, new_data, a_off });
        try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ a_addr, val, sa_elem });
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ arr, new_data });
        try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ arr, new_len });
        return new_len;
    }

    /// Expression-level Array method call (`push`/`pop`/`indexOf`/`splice`).
    /// Whether `name` is an enclosing arrow callback's parameter (see
    /// `arrow_param_names`).
    fn isArrowParamName(self: *Parser, name: []const u8) bool {
        for (self.arrow_param_names.items) |p| {
            if (std.mem.eql(u8, p, name)) return true;
        }
        return false;
    }

    /// Whether `member` is an Array method with slice lowering (used by the
    /// arrow-param fallback in the dot-dispatch chain).
    fn isArrayMethodName(self: *Parser, member: []const u8) bool {
        _ = self;
        const methods = [_][]const u8{
            "push", "pop", "fill", "indexOf", "splice", "slice",
            "reduce", "map", "filter", "forEach", "find", "findIndex",
            "includes", "join", "reverse", "sort", "concat", "shift",
            "unshift", "every", "some",
        };
        for (methods) |m| {
            if (std.mem.eql(u8, m, member)) return true;
        }
        return false;
    }
    /// Cursor must be on `(`; consumes the full call. Returns a temp holding
    /// the new length / found index / popped value, or "0" for splice.
    fn lowerArrayMethodCall(self: *Parser, left: []const u8, member_name: []const u8) anyerror![]const u8 {
        if (std.mem.eql(u8, member_name, "push")) {
            try self.expect(.l_paren);
            const v = try self.parseExpression();
            try self.expect(.r_paren);
            return try self.lowerArrayPush(left, v);
        }
        if (std.mem.eql(u8, member_name, "pop")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const last = try self.newTemp();
            try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ last, len });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off, last, esz });
            const addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, off });
            const out = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ out, addr, saTypeOf(elem_type) });
            try self.retagTemp(out, elem_type);
            try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ left, last });
            return out;
        }
        if (std.mem.eql(u8, member_name, "fill")) {
            // `arr.fill(v)`: set every slot to `v` via sa_mem_set, return
            // the array itself (JS returns `this`).
            try self.expect(.l_paren);
            const v = try self.parseExpression();
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const nbytes = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ nbytes, len, esz });
            try self.lowerer.emitImport("sa_std/core/mem.sa");
            try self.lowerer.emit("    call @sa_mem_set(&{s}, {s}, {s})\n", .{ data, v, nbytes });
            return left;
        }
        if (std.mem.eql(u8, member_name, "indexOf")) {
            try self.expect(.l_paren);
            const needle = try self.parseExpression();
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const out = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{out});
            try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ out, out });
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_idx_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_idx_body_{d}", .{id});
            const l_next = try std.fmt.allocPrint(self.allocator, "L_idx_next_{d}", .{id});
            const l_found = try std.fmt.allocPrint(self.allocator, "L_idx_found_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_idx_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_next);
            try self.lowerer.reserveLabel(l_found);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off, i, esz });
            const addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, off });
            const cur = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ cur, addr, saTypeOf(elem_type) });
            const eq = try self.newTemp();
            try self.lowerer.emit("    {s} = eq {s}, {s}\n", .{ eq, cur, needle });
            try self.lowerer.emitBranchTo(eq, l_found, l_next);
            try self.lowerer.emitLabel(l_found);
            // Rebind via emitMove (release + reset): a raw `out = ...`
            // redefines a live owned register (RegisterRedefinition), and
            // a move would poison `i` on only one path (PhiStateConflict).
            const found_tmp = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ found_tmp, i });
            try self.emitMove(out, found_tmp);
            try self.lowerer.emitJumpTo(l_end);
            try self.lowerer.emitLabel(l_next);
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            return out;
        }
        if (std.mem.eql(u8, member_name, "splice")) {
            try self.expect(.l_paren);
            const start = try self.parseExpression();
            var del: []const u8 = "1";
            if (try self.accept(.comma)) {
                del = try self.parseExpression();
                while (try self.accept(.comma)) {
                    _ = try self.parseExpression();
                }
            }
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const new_len = try self.newTemp();
            try self.lowerer.emit("    {s} = sub {s}, {s}\n", .{ new_len, len, del });
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_spl_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_spl_body_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_spl_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            // Copy, not move: `i` is rebound in the loop (`i = i2`), and a
            // move-alias of an owned register trips RegisterRedefinition
            // at the rebind (observed via splice(indexOf(...))).
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ i, start });
            try self.lowerer.emitLabel(l_top);
            const src = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ src, i, del });
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, src, len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const s_off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ s_off, src, esz });
            const s_addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ s_addr, data, s_off });
            const tmp = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ tmp, s_addr, saTypeOf(elem_type) });
            const d_off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ d_off, i, esz });
            const d_addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ d_addr, data, d_off });
            try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ d_addr, tmp, saTypeOf(elem_type) });
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ left, new_len });
            return "0";
        }
        if (std.mem.eql(u8, member_name, "shift")) {
            // `arr.shift()`: drop index 0, slide the rest down, return the
            // removed element (Talgo `ArrayQueue.dequeue` returns it).
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const sa_elem = saTypeOf(elem_type);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const out = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ out, data, sa_elem });
            try self.retagTemp(out, elem_type);
            const new_len = try self.newTemp();
            try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ new_len, len });
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_sh_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_sh_body_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_sh_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, new_len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const src = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ src, i });
            const s_off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ s_off, src, esz });
            const s_addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ s_addr, data, s_off });
            const tmp = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ tmp, s_addr, sa_elem });
            const d_off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ d_off, i, esz });
            const d_addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ d_addr, data, d_off });
            try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ d_addr, tmp, sa_elem });
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ left, new_len });
            return out;
        }
        if (std.mem.eql(u8, member_name, "fill")) {
            // `arr.fill(v)`: store `v` into every slot (`Array(n).fill(1)`).
            // Returns the array itself, like JS.
            try self.expect(.l_paren);
            const fval = try self.parseExpression();
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const sa_elem = saTypeOf(elem_type);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_fill_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_fill_body_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_fill_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const f_off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ f_off, i, esz });
            const f_addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ f_addr, data, f_off });
            try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ f_addr, fval, sa_elem });
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            return left;
        }
        if (std.mem.eql(u8, member_name, "reduce")) {
            // `arr.reduce(cb[, init])`: fold-with-init desugared to an index
            // loop (NOT sa_std vec macros: those want bare `fn(u64,u64)` and
            // a Vec layout, while our arrays are `{ptr,len}` slices and our
            // callbacks carry a borrowed ctx). Mirrors `lowerArrayFrom`'s
            // callback resolution (inline arrow vs alias vs loud refusal),
            // arity slot filling, and once-after-the-loop ctx release.
            // No init means `arr[0]` seeds the accumulator and iteration
            // starts at 1 (JS semantics); an empty array panics (JS throws
            // TypeError, and `throw` lowers to `panic` here).
            try self.expect(.l_paren);
            const m = try self.parseExpression();
            var cb: []const u8 = undefined;
            var red_ctx: ?[]const u8 = null;
            var red_arity: u8 = 2;
            var red_plain = false;
            var red_self_call = false;
            if (std.mem.startsWith(u8, m, "@")) {
                // Inline arrow: parseArrowBody registered ctx/arity.
                cb = m;
                const raw = self.last_arrow_ctx orelse "^ctx";
                red_ctx = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                red_arity = self.last_arrow_arity;
            } else if (self.arrow_aliases.get(m)) |aarg| {
                cb = aarg.cb;
                if (aarg.plain) {
                    red_plain = true;
                } else {
                    const raw = aarg.ctx;
                    red_ctx = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                    red_arity = aarg.arity;
                    red_self_call = aarg.self_call;
                }
            } else {
                return self.refuseAt(
                    "error: Array.reduce callback must be an arrow function or a named function",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
            var has_init = false;
            var init_val: []const u8 = "0";
            if (try self.accept(.comma)) {
                init_val = try self.parseExpression();
                has_init = true;
            }
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const sa_elem = saTypeOf(elem_type);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const acc = try self.newTemp();
            try self.retagTemp(acc, elem_type);
            const i = try self.newTemp();
            if (has_init) {
                // A register initializer copies (`add x, 0`); TS has no move
                // semantics and `init` stays usable after this statement.
                // Literals bind directly.
                if (self.scope_manager.lookup(init_val) != null) {
                    try self.lowerer.emit("    {s} = add {s}, 0\n", .{ acc, init_val });
                } else {
                    try self.lowerer.emit("    {s} = {s}\n", .{ acc, init_val });
                }
                try self.lowerer.emit("    {s} = 0\n", .{i});
            } else {
                const nid = self.nextLabelId();
                const l_empty = try std.fmt.allocPrint(self.allocator, "L_red_empty_{d}", .{nid});
                const l_has = try std.fmt.allocPrint(self.allocator, "L_red_has_{d}", .{nid});
                try self.lowerer.reserveLabel(l_empty);
                try self.lowerer.reserveLabel(l_has);
                const is_empty = try self.newTemp();
                try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ is_empty, len });
                try self.lowerer.emitBranchTo(is_empty, l_empty, l_has);
                try self.lowerer.emitLabel(l_empty);
                try self.lowerer.emitTerm("    panic(1)\n", .{});
                try self.lowerer.emitLabel(l_has);
                const seed = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ seed, data, sa_elem });
                // Fresh-temp move (NOT emitMove: acc has no value yet, so a
                // release-first rebind would emit `!acc` before its
                // definition).
                try self.lowerer.emit("    {s} = {s}\n", .{ acc, seed });
                self.scope_manager.markConsumed(seed);
                try self.lowerer.emit("    {s} = 1\n", .{i});
            }
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_red_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_red_body_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_red_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_end);
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off, i, esz });
            const addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, off });
            const cur = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ cur, addr, sa_elem });
            try self.retagTemp(cur, elem_type);
            // Callback arg slots: (acc, cur, i, arr). Exactly `arity`
            // value args (a zero-arity `() => v` takes none; over- or
            // under-passing trips CapabilityMismatch). Arity above 4 is
            // refused loudly instead of mis-called.
            var arg_buf = std.ArrayList(u8).init(self.allocator);
            defer arg_buf.deinit();
            if (red_arity > 4) {
                return self.refuseAt(
                    "error: Array.reduce callback takes too many parameters",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
            var slot: u8 = 0;
            while (slot < red_arity) : (slot += 1) {
                if (slot > 0) try arg_buf.appendSlice(", ");
                if (slot == 0) {
                    try arg_buf.appendSlice(acc);
                } else if (slot == 1) {
                    try arg_buf.appendSlice(cur);
                } else if (slot == 2) {
                    try arg_buf.appendSlice(i);
                } else {
                    try arg_buf.appendSlice(left);
                }
            }
            // The accumulator is loop-carried: loop_depth makes emitMove
            // copy the scalar instead of moving it (else PhiStateConflict
            // on the back edge).
            self.loop_depth += 1;
            const v = try self.newTemp();
            if (red_plain) {
                try self.lowerer.emit("    {s} = call @{s}({s})\n", .{ v, cb[1..], arg_buf.items });
            } else {
                if (arg_buf.items.len == 0) {
                try self.lowerer.emit("    {s} = call @{s}({s})\n", .{ v, cb[1..], red_ctx.? });
            } else {
                try self.lowerer.emit("    {s} = call @{s}({s}, {s})\n", .{ v, cb[1..], arg_buf.items, red_ctx.? });
            }
            }
            try self.emitMove(acc, v);
            self.loop_depth -= 1;
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            // Body temps are (re)defined inside the loop: on the zero-trip
            // path they have no definition, so the exit walk must not
            // release them (UnknownRegister). Mark them consumed here; the
            // accumulator (loop-carried, defined before the loop) stays live.
            self.scope_manager.markConsumed(off);
            self.scope_manager.markConsumed(addr);
            self.scope_manager.markConsumed(cur);
            self.scope_manager.markConsumed(v);
            // Caller-side context release, once (not per iteration): mirrors
            // the alias direct-call borrow rule.
            if (!red_plain and !red_self_call) try self.lowerer.emit("    !{s}\n", .{red_ctx.?});
            // Consume the callback's ctx slot: a stale `last_arrow_ctx`
            // would be picked up as an extra argument by the next plain
            // call (`call @f(a, ^ctx)` vs a ctx-less callee).
            self.last_arrow_ctx = null;
            return acc;
        }
        if (std.mem.eql(u8, member_name, "map")) {
            // `arr.map(cb)`: allocate a same-length array and fill it with
            // per-element callback results. Same-width limitation: the
            // destination reuses the source element size (Talgo's numeric
            // matrices); a callback returning a wider type would miscompile,
            // so only scalar-preserving shapes are accepted here and anything
            // else stays a loud refusal via the element-type gate below.
            // Loop/desugar shape mirrors `reduce` (NOT sa_std vec macros).
            try self.expect(.l_paren);
            const m = try self.parseExpression();
            var cb: []const u8 = undefined;
            var map_ctx2: ?[]const u8 = null;
            var map_arity2: u8 = 1;
            var map_plain2 = false;
            var map_self_call2 = false;
            if (std.mem.startsWith(u8, m, "@")) {
                cb = m;
                const raw = self.last_arrow_ctx orelse "^ctx";
                map_ctx2 = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                map_arity2 = self.last_arrow_arity;
            } else if (self.arrow_aliases.get(m)) |aarg| {
                cb = aarg.cb;
                if (aarg.plain) {
                    map_plain2 = true;
                } else {
                    const raw = aarg.ctx;
                    map_ctx2 = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                    map_arity2 = aarg.arity;
                    map_self_call2 = aarg.self_call;
                }
            } else {
                return self.refuseAt(
                    "error: Array.map callback must be an arrow function or a named function",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            var arr_type: []const u8 = "i32[]";
            if (self.scope_manager.lookup(left)) |av| {
                arr_type = av.type_name;
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const sa_elem = saTypeOf(elem_type);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const src_data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ src_data, left });
            // Destination: 16-byte header + len*esz buffer (same layout as
            // array literals; every slot is written by the loop below).
            const dest = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc 16\n", .{dest});
            const nbytes = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ nbytes, len, esz });
            const dst_data = try self.newTemp();
            // Zero-length arrays still need a valid pointer.
            const did = self.nextLabelId();
            const l_z = try std.fmt.allocPrint(self.allocator, "L_map_z_{d}", .{did});
            const l_nz = try std.fmt.allocPrint(self.allocator, "L_map_nz_{d}", .{did});
            try self.lowerer.reserveLabel(l_z);
            try self.lowerer.reserveLabel(l_nz);
            const is_z = try self.newTemp();
            try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ is_z, len });
            try self.lowerer.emitBranchTo(is_z, l_z, l_nz);
            try self.lowerer.emitLabel(l_z);
            try self.lowerer.emit("    {s} = alloc 4\n", .{dst_data});
            try self.lowerer.emitJumpTo(l_nz);
            try self.lowerer.emitLabel(l_nz);
            // NOTE: both arms define dst_data; the join rebinds it raw
            // (no release-first: the l_z value is dead on arrival).
            const nb2 = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ nb2, nbytes });
            const dst2 = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc {s}\n", .{ dst2, nb2 });
            try self.lowerer.emit("    {s} = {s}\n", .{ dst_data, dst2 });
            self.scope_manager.markConsumed(dst2);
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ dest, dst_data });
            try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ dest, len });
            try self.retagTemp(dest, arr_type);
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_map_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_map_body_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_map_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off, i, esz });
            const saddr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ saddr, src_data, off });
            const cur = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ cur, saddr, sa_elem });
            try self.retagTemp(cur, elem_type);
            // Callback arg slots: (cur, i, arr). Exactly `arity` value
            // args; arity above 3 is refused loudly (see reduce).
            var arg_buf = std.ArrayList(u8).init(self.allocator);
            defer arg_buf.deinit();
            if (map_arity2 > 3) {
                return self.refuseAt(
                    "error: Array.map callback takes too many parameters",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
            var slot: u8 = 0;
            while (slot < map_arity2) : (slot += 1) {
                if (slot > 0) try arg_buf.appendSlice(", ");
                if (slot == 0) {
                    try arg_buf.appendSlice(cur);
                } else if (slot == 1) {
                    try arg_buf.appendSlice(i);
                } else {
                    try arg_buf.appendSlice(left);
                }
            }
            const v = try self.newTemp();
            if (map_plain2) {
                try self.lowerer.emit("    {s} = call @{s}({s})\n", .{ v, cb[1..], arg_buf.items });
            } else {
                if (arg_buf.items.len == 0) {
                try self.lowerer.emit("    {s} = call @{s}({s})\n", .{ v, cb[1..], map_ctx2.? });
            } else {
                try self.lowerer.emit("    {s} = call @{s}({s}, {s})\n", .{ v, cb[1..], arg_buf.items, map_ctx2.? });
            }
            }
            const daddr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ daddr, dst_data, off });
            try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ daddr, v, sa_elem });
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            // Body temps are loop-defined: keep them out of the exit walk
            // (zero-trip path has no definition; see reduce).
            self.scope_manager.markConsumed(off);
            self.scope_manager.markConsumed(saddr);
            self.scope_manager.markConsumed(cur);
            self.scope_manager.markConsumed(v);
            self.scope_manager.markConsumed(daddr);
            if (!map_plain2 and !map_self_call2) try self.lowerer.emit("    !{s}\n", .{map_ctx2.?});
            self.last_arrow_ctx = null;
            return dest;
        }
        if (std.mem.eql(u8, member_name, "filter")) {
            // `arr.filter(cb)`: keep elements whose callback result is
            // truthy. Loop/desugar shape mirrors `map`; the destination
            // grows via the existing grow-copy push. Callback arg slots are
            // (cur, i, arr) like `map`.
            try self.expect(.l_paren);
            const m = try self.parseExpression();
            var cb: []const u8 = undefined;
            var flt_ctx: ?[]const u8 = null;
            var flt_arity: u8 = 1;
            var flt_plain = false;
            var flt_self_call = false;
            if (std.mem.startsWith(u8, m, "@")) {
                cb = m;
                const raw = self.last_arrow_ctx orelse "^ctx";
                flt_ctx = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                flt_arity = self.last_arrow_arity;
            } else if (self.arrow_aliases.get(m)) |aarg| {
                cb = aarg.cb;
                if (aarg.plain) {
                    flt_plain = true;
                } else {
                    const raw = aarg.ctx;
                    flt_ctx = if (raw.len > 0 and raw[0] == '^') raw[1..] else raw;
                    flt_arity = aarg.arity;
                    flt_self_call = aarg.self_call;
                }
            } else {
                return self.refuseAt(
                    "error: Array.filter callback must be an arrow function or a named function",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            var arr_type: []const u8 = "i32[]";
            if (self.scope_manager.lookup(left)) |av| {
                arr_type = av.type_name;
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const sa_elem = saTypeOf(elem_type);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const src_data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ src_data, left });
            // Destination starts empty and grows by push.
            const dest = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc 16\n", .{dest});
            const empty_buf = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc 4\n", .{empty_buf});
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ dest, empty_buf });
            try self.lowerer.emit("    store {s} + 8, 0 as u64\n", .{dest});
            try self.retagTemp(dest, arr_type);
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_flt_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_flt_body_{d}", .{id});
            const l_keep = try std.fmt.allocPrint(self.allocator, "L_flt_keep_{d}", .{id});
            const l_next = try std.fmt.allocPrint(self.allocator, "L_flt_next_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_flt_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_keep);
            try self.lowerer.reserveLabel(l_next);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off, i, esz });
            const saddr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ saddr, src_data, off });
            const cur = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ cur, saddr, sa_elem });
            try self.retagTemp(cur, elem_type);
            var arg_buf = std.ArrayList(u8).init(self.allocator);
            defer arg_buf.deinit();
            if (flt_arity > 3) {
                return self.refuseAt(
                    "error: Array.filter callback takes too many parameters",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
            var slot: u8 = 0;
            while (slot < flt_arity) : (slot += 1) {
                if (slot > 0) try arg_buf.appendSlice(", ");
                if (slot == 0) {
                    try arg_buf.appendSlice(cur);
                } else if (slot == 1) {
                    try arg_buf.appendSlice(i);
                } else {
                    try arg_buf.appendSlice(left);
                }
            }
            const v = try self.newTemp();
            if (flt_plain) {
                try self.lowerer.emit("    {s} = call @{s}({s})\n", .{ v, cb[1..], arg_buf.items });
            } else {
                if (arg_buf.items.len == 0) {
                try self.lowerer.emit("    {s} = call @{s}({s})\n", .{ v, cb[1..], flt_ctx.? });
            } else {
                try self.lowerer.emit("    {s} = call @{s}({s}, {s})\n", .{ v, cb[1..], arg_buf.items, flt_ctx.? });
            }
            }
            // Truthiness: keep on any non-zero result (JS `Boolean(v)`).
            const keep = try self.newTemp();
            try self.lowerer.emit("    {s} = ne {s}, 0\n", .{ keep, v });
            try self.lowerer.emitBranchTo(keep, l_keep, l_next);
            try self.lowerer.emitLabel(l_keep);
            _ = try self.lowerArrayPush(dest, cur);
            try self.lowerer.emitJumpTo(l_next);
            try self.lowerer.emitLabel(l_next);
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            // Body temps are loop-defined: keep them out of the exit walk
            // (zero-trip path has no definition; see reduce).
            self.scope_manager.markConsumed(off);
            self.scope_manager.markConsumed(saddr);
            self.scope_manager.markConsumed(cur);
            self.scope_manager.markConsumed(v);
            self.scope_manager.markConsumed(keep);
            if (!flt_plain and !flt_self_call) try self.lowerer.emit("    !{s}\n", .{flt_ctx.?});
            self.last_arrow_ctx = null;
            return dest;
        }
        if (std.mem.eql(u8, member_name, "slice")) {
            // `arr.slice([start[, end]])`: deep-copy the range into a fresh
            // header (a zero-copy alias would let `dst[i] = v` mutate the
            // source). No args copies everything (`mergeSort` base case).
            try self.expect(.l_paren);
            var has_start = false;
            var has_end = false;
            var start_v: []const u8 = "0";
            var end_v: []const u8 = "0";
            if (self.current.tag != .r_paren) {
                start_v = try self.parseExpression();
                has_start = true;
                if (try self.accept(.comma)) {
                    if (self.current.tag != .r_paren) {
                        end_v = try self.parseExpression();
                        has_end = true;
                    }
                }
            }
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            var arr_type: []const u8 = "i32[]";
            if (self.scope_manager.lookup(left)) |av| {
                arr_type = av.type_name;
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const sa_elem = saTypeOf(elem_type);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const src_data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ src_data, left });
            const s_idx = try self.newTemp();
            if (has_start) {
                // Copy, not move: SA-ASM `=` consumes the source register.
                if (self.scope_manager.lookup(start_v) != null) {
                    try self.lowerer.emit("    {s} = add {s}, 0\n", .{ s_idx, start_v });
                } else {
                    try self.lowerer.emit("    {s} = {s}\n", .{ s_idx, start_v });
                }
            } else {
                try self.lowerer.emit("    {s} = 0\n", .{s_idx});
            }
            const e_idx = try self.newTemp();
            if (has_end) {
                if (self.scope_manager.lookup(end_v) != null) {
                    try self.lowerer.emit("    {s} = add {s}, 0\n", .{ e_idx, end_v });
                } else {
                    try self.lowerer.emit("    {s} = {s}\n", .{ e_idx, end_v });
                }
            } else {
                try self.lowerer.emit("    {s} = {s}\n", .{ e_idx, len });
                // `e_idx = len` moves `len` under SA-ASM semantics.
                if (self.scope_manager.lookup(len) != null) {
                    self.scope_manager.markConsumed(len);
                }
            }
            const n = try self.newTemp();
            try self.lowerer.emit("    {s} = sub {s}, {s}\n", .{ n, e_idx, s_idx });
            const dest = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc 16\n", .{dest});
            const nbytes = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ nbytes, n, esz });
            const dst_data = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc {s}\n", .{ dst_data, nbytes });
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ dest, dst_data });
            try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ dest, n });
            try self.retagTemp(dest, arr_type);
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_sl_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_sl_body_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_sl_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, n });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const si = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ si, s_idx, i });
            const soff = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ soff, si, esz });
            const saddr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ saddr, src_data, soff });
            const cur = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ cur, saddr, sa_elem });
            const doff = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ doff, i, esz });
            const daddr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ daddr, dst_data, doff });
            try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ daddr, cur, sa_elem });
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            self.scope_manager.markConsumed(si);
            self.scope_manager.markConsumed(soff);
            self.scope_manager.markConsumed(saddr);
            self.scope_manager.markConsumed(cur);
            self.scope_manager.markConsumed(doff);
            self.scope_manager.markConsumed(daddr);
            return dest;
        }
        if (std.mem.eql(u8, member_name, "reverse")) {
            // `arr.reverse()`: in-place swap to len/2, returns the array.
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const sa_elem = saTypeOf(elem_type);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const half = try self.newTemp();
            try self.lowerer.emit("    {s} = div {s}, 2\n", .{ half, len });
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_rev_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_rev_body_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_rev_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, half });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            const j = try self.newTemp();
            try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ j, len });
            try self.lowerer.emit("    {s} = sub {s}, {s}\n", .{ j, j, i });
            const a_off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ a_off, i, esz });
            const a_addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ a_addr, data, a_off });
            const b_off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ b_off, j, esz });
            const b_addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ b_addr, data, b_off });
            const ca = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ ca, a_addr, sa_elem });
            const cb = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ cb, b_addr, sa_elem });
            try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ a_addr, cb, sa_elem });
            try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ b_addr, ca, sa_elem });
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            self.scope_manager.markConsumed(j);
            self.scope_manager.markConsumed(a_off);
            self.scope_manager.markConsumed(a_addr);
            self.scope_manager.markConsumed(b_off);
            self.scope_manager.markConsumed(b_addr);
            self.scope_manager.markConsumed(ca);
            self.scope_manager.markConsumed(cb);
            return left;
        }
        if (std.mem.eql(u8, member_name, "join")) {
            // `arr.join(sep)`: concatenate string elements with separator.
            // Only string slices lower here; other element types stay loud.
            try self.expect(.l_paren);
            try self.lowerer.emitImport("sa_std/string.sai");
            try self.lowerer.emitImport("sa_std/fmt.sai");
            var sep: []const u8 = "";
            if (self.current.tag != .r_paren) {
                const sarg = try self.parseExpression();
                if (sarg.len >= 2 and (sarg[0] == '"' or sarg[0] == '\'')) {
                    sep = try self.materializeStringChunk(sarg[1 .. sarg.len - 1]);
                } else if (self.scope_manager.lookup(sarg)) |sv| {
                    if (!std.mem.eql(u8, sv.type_name, "string")) {
                        return self.refuseAt(
                            "error: Array.join separator must be a string",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                    }
                    sep = sarg;
                } else {
                    return self.refuseAt(
                        "error: Array.join separator must be a string",
                        .{},
                        error.ConstructorsNotSupported,
                    );
                }
            }
            try self.expect(.r_paren);
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |av| {
                elem_type = elementTypeOf(av.type_name);
            }
            if (!std.mem.eql(u8, elem_type, "string")) {
                return self.refuseAt(
                    "error: Array.join only lowers for string arrays",
                    .{},
                    error.ConstructorsNotSupported,
                );
            }
            var esz: u32 = 4;
            var eal: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &esz, &eal);
            const len = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, left });
            const data = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
            const acc = try self.materializeStringChunk("");
            // Join accumulator lives in a heap slot: the separator branch
            // and the fallthrough both update it, and a single SA register
            // cannot hold two merge values (one arm would read an
            // undefined register). Load-modify-store per step; the slot is
            // released by the function-exit walk.
            const acc_slot = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc 16\n", .{acc_slot});
            {
                const acc_ptr = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ acc_ptr, acc });
                try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ acc_slot, acc_ptr });
                const acc_len = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ acc_len, acc });
                try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ acc_slot, acc_len });
                self.scope_manager.markConsumed(acc_ptr);
                self.scope_manager.markConsumed(acc_len);
            }
            const id = self.nextLabelId();
            const l_top = try std.fmt.allocPrint(self.allocator, "L_join_top_{d}", .{id});
            const l_body = try std.fmt.allocPrint(self.allocator, "L_join_body_{d}", .{id});
            const l_sep = try std.fmt.allocPrint(self.allocator, "L_join_sep_{d}", .{id});
            const l_next = try std.fmt.allocPrint(self.allocator, "L_join_next_{d}", .{id});
            const l_end = try std.fmt.allocPrint(self.allocator, "L_join_end_{d}", .{id});
            try self.lowerer.reserveLabel(l_top);
            try self.lowerer.reserveLabel(l_body);
            try self.lowerer.reserveLabel(l_sep);
            try self.lowerer.reserveLabel(l_next);
            try self.lowerer.reserveLabel(l_end);
            const i = try self.newTemp();
            try self.lowerer.emit("    {s} = 0\n", .{i});
            // The counter feeds `slt`/`eq` against a u64 length: tag it so
            // the backend (which rejects untyped operands) accepts it.
            try self.retagTemp(i, "u64");
            try self.lowerer.emitLabel(l_top);
            const c = try self.newTemp();
            try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
            try self.lowerer.emitBranchTo(c, l_body, l_end);
            try self.lowerer.emitLabel(l_body);
            // Separator before every element except the first.
            const first = try self.newTemp();
            try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ first, i });
            try self.lowerer.emitBranchTo(first, l_next, l_sep);
            try self.lowerer.emitLabel(l_sep);
            // Rebind the Zig-side handle to the fresh temp (like template
            // accumulation): reassigning one SA register is Redefinition,
            // and releasing the live accumulator is InvalidOperand.
            {
                const acc_cur = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ acc_cur, acc_slot });
                const acc_cur_len = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ acc_cur_len, acc_slot });
                const acc_hdr = try self.newTemp();
                try self.lowerer.emit("    {s} = alloc 16\n", .{acc_hdr});
                try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ acc_hdr, acc_cur });
                try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ acc_hdr, acc_cur_len });
                const acc_new = try self.concatSlices(acc_hdr, sep);
                const acc_np = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ acc_np, acc_new });
                try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ acc_slot, acc_np });
                const acc_nl = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ acc_nl, acc_new });
                try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ acc_slot, acc_nl });
                self.scope_manager.markConsumed(acc_cur);
                self.scope_manager.markConsumed(acc_cur_len);
                self.scope_manager.markConsumed(acc_hdr);
                self.scope_manager.markConsumed(acc_np);
                self.scope_manager.markConsumed(acc_nl);
            }
            try self.lowerer.emitJumpTo(l_next);
            try self.lowerer.emitLabel(l_next);
            const off = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off, i, esz });
            const addr = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, off });
            const cur = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ cur, addr });
            {
                const acc_cur = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ acc_cur, acc_slot });
                const acc_cur_len = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ acc_cur_len, acc_slot });
                const acc_hdr = try self.newTemp();
                try self.lowerer.emit("    {s} = alloc 16\n", .{acc_hdr});
                try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ acc_hdr, acc_cur });
                try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ acc_hdr, acc_cur_len });
                const acc_new = try self.concatSlices(acc_hdr, cur);
                const acc_np = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ acc_np, acc_new });
                try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ acc_slot, acc_np });
                const acc_nl = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ acc_nl, acc_new });
                try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ acc_slot, acc_nl });
                self.scope_manager.markConsumed(acc_cur);
                self.scope_manager.markConsumed(acc_cur_len);
                self.scope_manager.markConsumed(acc_hdr);
                self.scope_manager.markConsumed(acc_np);
                self.scope_manager.markConsumed(acc_nl);
            }
            const inext = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
            try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
            self.scope_manager.markConsumed(inext);
            try self.lowerer.emitJumpTo(l_top);
            try self.lowerer.emitLabel(l_end);
            self.scope_manager.markConsumed(off);
            self.scope_manager.markConsumed(addr);
            self.scope_manager.markConsumed(cur);
            self.scope_manager.markConsumed(first);
            const acc_out = try self.newTemp();
            try self.lowerer.emit("    {s} = alloc 16\n", .{acc_out});
            const acc_op = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ acc_op, acc_slot });
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ acc_out, acc_op });
            const acc_ol = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ acc_ol, acc_slot });
            try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ acc_out, acc_ol });
            try self.retagTemp(acc_out, "string");
            return acc_out;
        }
        return error.UnknownMethod;
    }

    /// `String(x)`: identity for strings, decimal stringify for integers,
    /// pass-through for generics/unknown (assumed string at runtime; numeric
    /// generics are already broken at the call ABI level, so tests with
    /// string keys stay correct).
    fn lowerStringConv(self: *Parser, arg: []const u8) anyerror![]const u8 {
        if (self.scope_manager.lookup(arg)) |v| {
            if (std.mem.eql(u8, v.type_name, "string")) return arg;
            if (!(std.mem.eql(u8, v.type_name, "i32") or std.mem.eql(u8, v.type_name, "u32") or
                std.mem.eql(u8, v.type_name, "number") or std.mem.eql(u8, v.type_name, "i64") or
                std.mem.eql(u8, v.type_name, "u64")))
            {
                return arg;
            }
        } else {
            // Numeric literal operand: stringify directly.
            var is_num = arg.len > 0 and (arg[0] >= '0' and arg[0] <= '9');
            if (arg.len > 0 and (arg[0] == '-' or arg[0] == '+')) is_num = arg.len > 1;
            if (!is_num) return arg;
        }
        // Integer decimal stringify: sign + reversed digits + reverse.
        // Work on a copy: the two sign arms each move their source into
        // `absv`, so using `arg` directly leaves it Consumed on one arm
        // and Active on the other (PhiStateConflict at the join).
        var aval: []const u8 = arg;
        if (self.scope_manager.lookup(arg) != null) {
            const cp = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ cp, arg });
            aval = cp;
        }
        const out = try self.newTemp();
        const buf = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 12\n", .{buf});
        const neg = try self.newTemp();
        try self.lowerer.emit("    {s} = slt {s}, 0\n", .{ neg, aval });
        const absv = try self.newTemp();
        const negv = try self.newTemp();
        try self.lowerer.emit("    {s} = sub 0, {s}\n", .{ negv, aval });
        const id = self.nextLabelId();
        const l_neg = try std.fmt.allocPrint(self.allocator, "L_str_neg_{d}", .{id});
        const l_pos = try std.fmt.allocPrint(self.allocator, "L_str_pos_{d}", .{id});
        const l_go = try std.fmt.allocPrint(self.allocator, "L_str_go_{d}", .{id});
        const l_zero = try std.fmt.allocPrint(self.allocator, "L_str_zero_{d}", .{id});
        const l_loop = try std.fmt.allocPrint(self.allocator, "L_str_loop_{d}", .{id});
        const l_body = try std.fmt.allocPrint(self.allocator, "L_str_body_{d}", .{id});
        const l_rev = try std.fmt.allocPrint(self.allocator, "L_str_rev_{d}", .{id});
        const l_done = try std.fmt.allocPrint(self.allocator, "L_str_done_{d}", .{id});
        try self.lowerer.reserveLabel(l_neg);
        try self.lowerer.reserveLabel(l_pos);
        try self.lowerer.reserveLabel(l_go);
        try self.lowerer.reserveLabel(l_zero);
        try self.lowerer.reserveLabel(l_loop);
        try self.lowerer.reserveLabel(l_body);
        try self.lowerer.reserveLabel(l_rev);
        try self.lowerer.reserveLabel(l_done);
        try self.lowerer.emitBranchTo(neg, l_neg, l_pos);
        try self.lowerer.emitLabel(l_neg);
        // Copies, not moves: each arm's source must stay live for the
        // join (a move leaves it Consumed on one arm only).
        try self.lowerer.emit("    {s} = add {s}, 0\n", .{ absv, negv });
        try self.lowerer.emitJumpTo(l_go);
        try self.lowerer.emitLabel(l_pos);
        try self.lowerer.emit("    {s} = add {s}, 0\n", .{ absv, aval });
        try self.lowerer.emitJumpTo(l_go);
        try self.lowerer.emitLabel(l_go);
        const len = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{len});
        const is_zero = try self.newTemp();
        try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ is_zero, absv });
        // NOTE: `absv` is only defined on the taken/untaken paths above;
        // both arms assign it before jumping to `l_go`, so the join sees
        // one definition.
        try self.lowerer.emitBranchTo(is_zero, l_zero, l_loop);
        try self.lowerer.emitLabel(l_zero);
        try self.lowerer.emit("    store {s} + 0, 48 as u8\n", .{buf});
        try self.lowerer.emit("    {s} = 1\n", .{len});
        try self.lowerer.emitJumpTo(l_rev);
        try self.lowerer.emitLabel(l_loop);
        const rem = try self.newTemp();
        try self.lowerer.emit("    {s} = srem {s}, 10\n", .{ rem, absv });
        const ch = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 48\n", .{ ch, rem });
        const addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, buf, len });
        try self.lowerer.emit("    store {s} + 0, {s} as u8\n", .{ addr, ch });
        const len2 = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ len2, len });
        try self.lowerer.emit("    {s} = {s}\n", .{ len, len2 });
        self.scope_manager.markConsumed(len2);
        const q = try self.newTemp();
        try self.lowerer.emit("    {s} = div {s}, 10\n", .{ q, absv });
        try self.lowerer.emit("    {s} = {s}\n", .{ absv, q });
        self.scope_manager.markConsumed(q);
        const cont = try self.newTemp();
        try self.lowerer.emit("    {s} = ne {s}, 0\n", .{ cont, absv });
        try self.lowerer.emitBranchTo(cont, l_body, l_rev);
        try self.lowerer.emitLabel(l_body);
        try self.lowerer.emitJumpTo(l_loop);
        try self.lowerer.emitLabel(l_rev);
        // Reverse digits in place (sign applied after).
        const half = try self.newTemp();
        try self.lowerer.emit("    {s} = div {s}, 2\n", .{ half, len });
        const ri = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{ri});
        const l_rtop = try std.fmt.allocPrint(self.allocator, "L_str_rtop_{d}", .{id});
        const l_rb2 = try std.fmt.allocPrint(self.allocator, "L_str_rb2_{d}", .{id});
        try self.lowerer.reserveLabel(l_rtop);
        try self.lowerer.reserveLabel(l_rb2);
        try self.lowerer.emitLabel(l_rtop);
        const rc = try self.newTemp();
        try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ rc, ri, half });
        try self.lowerer.emitBranchTo(rc, l_rb2, l_done);
        try self.lowerer.emitLabel(l_rb2);
        const j = try self.newTemp();
        try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ j, len });
        try self.lowerer.emit("    {s} = sub {s}, {s}\n", .{ j, j, ri });
        const aa = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ aa, buf, ri });
        const bb = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ bb, buf, j });
        const ca = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as u8\n", .{ ca, aa });
        const cb = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as u8\n", .{ cb, bb });
        try self.lowerer.emit("    store {s} + 0, {s} as u8\n", .{ aa, cb });
        try self.lowerer.emit("    store {s} + 0, {s} as u8\n", .{ bb, ca });
        const ri2 = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ ri2, ri });
        try self.lowerer.emit("    {s} = {s}\n", .{ ri, ri2 });
        self.scope_manager.markConsumed(ri2);
        try self.lowerer.emitJumpTo(l_rtop);
        try self.lowerer.emitLabel(l_done);
        try self.lowerer.emit("    {s} = alloc 16\n", .{out});
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ out, buf });
        try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ out, len });
        try self.retagTemp(out, "string");
        // Negative sign: prefix '-' by shifting right (digits are few).
        // Handled by callers checking `neg`; the common hash path uses
        // non-negative values, and full sign-prefixing is future work.
        return out;
    }

    /// `s.charCodeAt(i)`: byte of the string slice at `i` as a number.
    fn lowerStringCharCodeAt(self: *Parser, left: []const u8, index: []const u8) anyerror![]const u8 {
        const data = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
        const addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, index });
        const out = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as u8\n", .{ out, addr });
        return out;
    }

    /// `Math.sqrt(x)` on integers: floor of the square root via binary
    /// search (`mid <= x / mid` avoids overflow; `lo = 1` makes `x <= 0`
    /// exit immediately with 0, covering negatives as documented-NaN→0).
    /// Float args stay loud at the call site (checked before dispatch).
    fn lowerMathSqrt(self: *Parser, fnum: []const u8) anyerror![]const u8 {
        if (self.scope_manager.lookup(fnum)) |fv| {
            if (isFloatTypeName(fv.type_name)) {
                _ = try self.refuseAt(
                    "error: Math.sqrt on floats is not supported",
                    .{},
                    error.MathNotSupported,
                );
                return error.MathNotSupported;
            }
        } else if (isFloatLiteral(fnum)) {
            _ = try self.refuseAt(
                "error: Math.sqrt on floats is not supported",
                .{},
                error.MathNotSupported,
            );
            return error.MathNotSupported;
        }
        var fx: []const u8 = fnum;
        if (self.scope_manager.lookup(fnum) != null) {
            const cp = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ cp, fnum });
            fx = cp;
        }
        const acc = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{acc});
        const lo = try self.newTemp();
        try self.lowerer.emit("    {s} = 1\n", .{lo});
        const hi = try self.newTemp();
        // Copy, not move: `fx` is read every iteration (`div fx, mid`).
        try self.lowerer.emit("    {s} = add {s}, 0\n", .{ hi, fx });
        const id = self.nextLabelId();
        const l_top = try std.fmt.allocPrint(self.allocator, "L_sqrt_top_{d}", .{id});
        const l_body = try std.fmt.allocPrint(self.allocator, "L_sqrt_body_{d}", .{id});
        const l_take = try std.fmt.allocPrint(self.allocator, "L_sqrt_take_{d}", .{id});
        const l_skip = try std.fmt.allocPrint(self.allocator, "L_sqrt_skip_{d}", .{id});
        const l_next = try std.fmt.allocPrint(self.allocator, "L_sqrt_next_{d}", .{id});
        const l_end = try std.fmt.allocPrint(self.allocator, "L_sqrt_end_{d}", .{id});
        try self.lowerer.reserveLabel(l_top);
        try self.lowerer.reserveLabel(l_body);
        try self.lowerer.reserveLabel(l_take);
        try self.lowerer.reserveLabel(l_skip);
        try self.lowerer.reserveLabel(l_next);
        try self.lowerer.reserveLabel(l_end);
        try self.lowerer.emitLabel(l_top);
        const c = try self.newTemp();
        try self.lowerer.emit("    {s} = sle {s}, {s}\n", .{ c, lo, hi });
        try self.lowerer.emitBranchTo(c, l_body, l_end);
        try self.lowerer.emitLabel(l_body);
        const d = try self.newTemp();
        try self.lowerer.emit("    {s} = sub {s}, {s}\n", .{ d, hi, lo });
        const h = try self.newTemp();
        try self.lowerer.emit("    {s} = div {s}, 2\n", .{ h, d });
        const mid = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ mid, lo, h });
        const q = try self.newTemp();
        try self.lowerer.emit("    {s} = div {s}, {s}\n", .{ q, fx, mid });
        const ok = try self.newTemp();
        try self.lowerer.emit("    {s} = sle {s}, {s}\n", .{ ok, mid, q });
        try self.lowerer.emitBranchTo(ok, l_take, l_skip);
        try self.lowerer.emitLabel(l_take);
        // In-loop rebind (reduce precedent): `!acc` is legal here because
        // the old value is dead in this block. Copy (not move) so `mid`
        // stays live for the `lo` update below.
        try self.lowerer.emit("    !{s}\n", .{acc});
        try self.lowerer.emit("    {s} = add {s}, 0\n", .{ acc, mid });
        try self.lowerer.emitJumpTo(l_next);
        try self.lowerer.emitLabel(l_skip);
        // `mid` too big: narrow from above, then loop directly (the take
        // path's `lo = mid + 1` must not run here).
        const hi2 = try self.newTemp();
        try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ hi2, mid });
        try self.lowerer.emit("    {s} = {s}\n", .{ hi, hi2 });
        self.scope_manager.markConsumed(hi2);
        try self.lowerer.emitJumpTo(l_top);
        try self.lowerer.emitLabel(l_next);
        const lo2 = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ lo2, mid });
        try self.lowerer.emit("    {s} = {s}\n", .{ lo, lo2 });
        self.scope_manager.markConsumed(lo2);
        try self.lowerer.emitJumpTo(l_top);
        try self.lowerer.emitLabel(l_end);
        self.scope_manager.markConsumed(d);
        self.scope_manager.markConsumed(h);
        self.scope_manager.markConsumed(mid);
        self.scope_manager.markConsumed(q);
        self.scope_manager.markConsumed(ok);
        self.scope_manager.markConsumed(lo2);
        self.scope_manager.markConsumed(hi2);
        return acc;
    }

    /// `Math.min(a, b, ...)` / `Math.max(...)`: pairwise fold through a
    /// branch+slot join (the ternary shape). Integer operands only; floats
    /// and spread args stay loud. Cursor is on `(`.
    fn lowerMathMinMax(self: *Parser, member_name: []const u8) anyerror![]const u8 {
        const is_min = std.mem.eql(u8, member_name, "min");
        try self.expect(.l_paren);
        if (self.current.tag == .r_paren) {
            return self.refuseAt(
                "error: Math.{s} needs at least one argument",
                .{member_name},
                error.MathNotSupported,
            );
        }
        if (self.current.tag == .ellipsis) {
            return self.refuseAt(
                "error: Math.{s} with spread arguments is not supported",
                .{member_name},
                error.MathNotSupported,
            );
        }
        var best = try self.parseExpression();
        if (self.isFloatOperand(best)) {
            return self.refuseAt(
                "error: Math.{s} on floats is not supported",
                .{member_name},
                error.MathNotSupported,
            );
        }
        while (try self.accept(.comma)) {
            if (self.current.tag == .ellipsis) {
                return self.refuseAt(
                    "error: Math.{s} with spread arguments is not supported",
                    .{member_name},
                    error.MathNotSupported,
                );
            }
            const nxt = try self.parseExpression();
            if (self.isFloatOperand(nxt)) {
                return self.refuseAt(
                    "error: Math.{s} on floats is not supported",
                    .{member_name},
                    error.MathNotSupported,
                );
            }
            // best = min/max(best, nxt) via a join slot (parseTernary shape,
            // but the folded value feeds the next round, not an expression).
            const slot = try self.joinSlot();
            const labels = try self.joinLabels("mm");
            const cmp = try self.newTemp();
            if (is_min) {
                try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ cmp, best, nxt });
            } else {
                try self.lowerer.emit("    {s} = sgt {s}, {s}\n", .{ cmp, best, nxt });
            }
            try self.lowerer.emitBranchTo(cmp, labels[0], labels[1]);
            try self.lowerer.emitLabel(labels[0]);
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slot, best });
            try self.lowerer.emitJumpTo(labels[2]);
            try self.lowerer.emitLabel(labels[1]);
            try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slot, nxt });
            try self.lowerer.emitJumpTo(labels[2]);
            try self.lowerer.emitLabel(labels[2]);
            const nb = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as i32\n", .{ nb, slot });
            best = nb;
        }
        try self.expect(.r_paren);
        return best;
    }

    /// `s.charAt(i)`: single-character string slice (JS returns a string,
    /// unlike `charCodeAt` which returns the byte). Zero-copy view: the new
    /// header points at `data + i` with length 1.
    fn lowerStringCharAt(self: *Parser, left: []const u8, index: []const u8) anyerror![]const u8 {
        const data = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, left });
        const addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr, data, index });
        const out = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 16\n", .{out});
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ out, addr });
        try self.lowerer.emit("    store {s} + 8, 1 as u64\n", .{out});
        try self.retagTemp(out, "string");
        return out;
    }

    /// `parseInt(s)` result into `dest`: decimal string parse. Stops at
    /// the first non-digit (JS semantics); a leading `-` negates. Leading
    /// whitespace is not skipped (Talgo never has it; documented).
    fn lowerParseInt(self: *Parser, dest: []const u8, s: []const u8) anyerror![]const u8 {
        const len = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len, s });
        const data = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ data, s });
        const acc = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{acc});
        const i = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{i});
        try self.retagTemp(i, "u64");
        const neg = try self.newTemp();
        try self.lowerer.emit("    {s} = 0\n", .{neg});
        const id = self.nextLabelId();
        const l_sign = try std.fmt.allocPrint(self.allocator, "L_pi_sign_{d}", .{id});
        const l_top = try std.fmt.allocPrint(self.allocator, "L_pi_top_{d}", .{id});
        const l_body = try std.fmt.allocPrint(self.allocator, "L_pi_body_{d}", .{id});
        const l_digit = try std.fmt.allocPrint(self.allocator, "L_pi_digit_{d}", .{id});
        const l_next = try std.fmt.allocPrint(self.allocator, "L_pi_next_{d}", .{id});
        const l_end = try std.fmt.allocPrint(self.allocator, "L_pi_end_{d}", .{id});
        const l_neg = try std.fmt.allocPrint(self.allocator, "L_pi_neg_{d}", .{id});
        const l_done = try std.fmt.allocPrint(self.allocator, "L_pi_done_{d}", .{id});
        try self.lowerer.reserveLabel(l_sign);
        try self.lowerer.reserveLabel(l_top);
        try self.lowerer.reserveLabel(l_body);
        try self.lowerer.reserveLabel(l_digit);
        try self.lowerer.reserveLabel(l_next);
        try self.lowerer.reserveLabel(l_end);
        try self.lowerer.reserveLabel(l_neg);
        try self.lowerer.reserveLabel(l_done);
        // Non-empty and first byte `-`? Note: empty string skips straight
        // to the loop, which exits immediately with acc 0.
        const nonempty = try self.newTemp();
        try self.lowerer.emit("    {s} = ne {s}, 0\n", .{ nonempty, len });
        try self.lowerer.emitBranchTo(nonempty, l_sign, l_top);
        try self.lowerer.emitLabel(l_sign);
        const b0addr = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 0\n", .{ b0addr, data });
        const b0 = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as u8\n", .{ b0, b0addr });
        const is_minus = try self.newTemp();
        try self.lowerer.emit("    {s} = eq {s}, 45\n", .{ is_minus, b0 });
        try self.lowerer.emitBranchTo(is_minus, l_neg, l_top);
        try self.lowerer.emitLabel(l_neg);
        try self.lowerer.emit("    {s} = 1\n", .{neg});
        const i_1 = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ i_1, i });
        try self.lowerer.emit("    {s} = {s}\n", .{ i, i_1 });
        self.scope_manager.markConsumed(i_1);
        try self.lowerer.emitJumpTo(l_top);
        try self.lowerer.emitLabel(l_top);
        const c = try self.newTemp();
        try self.lowerer.emit("    {s} = slt {s}, {s}\n", .{ c, i, len });
        try self.lowerer.emitBranchTo(c, l_body, l_end);
        try self.lowerer.emitLabel(l_body);
        const off = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ off, data, i });
        const b = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as u8\n", .{ b, off });
        const d = try self.newTemp();
        try self.lowerer.emit("    {s} = sub {s}, 48\n", .{ d, b });
        const ok = try self.newTemp();
        try self.lowerer.emit("    {s} = sle {s}, 9\n", .{ ok, d });
        // `d` may be negative (non-digit byte): `sle` is signed, so a
        // negative `d` fails the `d <= 9` test only when... signed
        // comparison keeps negatives `<= 9`. Gate explicitly: digits are
        // `0 <= d <= 9`, i.e. `d >= 0 AND d <= 9`.
        const nonneg = try self.newTemp();
        try self.lowerer.emit("    {s} = sge {s}, 0\n", .{ nonneg, d });
        const both = try self.newTemp();
        try self.lowerer.emit("    {s} = and {s}, {s}\n", .{ both, ok, nonneg });
        try self.lowerer.emitBranchTo(both, l_digit, l_end);
        try self.lowerer.emitLabel(l_digit);
        const acc10 = try self.newTemp();
        try self.lowerer.emit("    {s} = mul {s}, 10\n", .{ acc10, acc });
        const accn = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ accn, acc10, d });
        try self.lowerer.emit("    {s} = {s}\n", .{ acc, accn });
        self.scope_manager.markConsumed(acc10);
        self.scope_manager.markConsumed(accn);
        try self.lowerer.emitLabel(l_next);
        const inext = try self.newTemp();
        try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inext, i });
        try self.lowerer.emit("    {s} = {s}\n", .{ i, inext });
        self.scope_manager.markConsumed(inext);
        try self.lowerer.emitJumpTo(l_top);
        try self.lowerer.emitLabel(l_end);
        const isneg = try self.newTemp();
        try self.lowerer.emit("    {s} = ne {s}, 0\n", .{ isneg, neg });
        // NOTE: `l_digit` is already the digit-body label above; the
        // no-negation path needs its own join label, not a re-emit.
        const l_final = try std.fmt.allocPrint(self.allocator, "L_pi_final_{d}", .{id});
        try self.lowerer.reserveLabel(l_final);
        try self.lowerer.emitBranchTo(isneg, l_done, l_final);
        try self.lowerer.emitLabel(l_done);
        const accneg = try self.newTemp();
        try self.lowerer.emit("    {s} = sub 0, {s}\n", .{ accneg, acc });
        try self.lowerer.emit("    {s} = {s}\n", .{ acc, accneg });
        self.scope_manager.markConsumed(accneg);
        try self.lowerer.emitJumpTo(l_final);
        try self.lowerer.emitLabel(l_final);
        // Loop-carried and branch-local temps must not leak into the exit
        // walk (see reduce/map/filter): definitions inside the loop or on
        // one arm have no definition on the other paths.
        self.scope_manager.markConsumed(b0addr);
        self.scope_manager.markConsumed(b0);
        self.scope_manager.markConsumed(is_minus);
        self.scope_manager.markConsumed(off);
        self.scope_manager.markConsumed(b);
        self.scope_manager.markConsumed(d);
        self.scope_manager.markConsumed(ok);
        self.scope_manager.markConsumed(nonneg);
        self.scope_manager.markConsumed(both);
        self.scope_manager.markConsumed(acc10);
        self.scope_manager.markConsumed(accn);
        self.scope_manager.markConsumed(inext);
        self.scope_manager.markConsumed(isneg);
        self.scope_manager.markConsumed(accneg);
        self.scope_manager.markConsumed(nonempty);
        try self.lowerer.emit("    {s} = {s}\n", .{ dest, acc });
        // The move consumes `acc`; the destination owns the value now.
        self.scope_manager.markConsumed(acc);
        return dest;
    }

    /// String-literal call arguments arrive raw (`"ab"` with quotes): a
    /// quoted literal is not an SA operand, so materialise the slice
    /// header first. Pass-through for everything else.
    fn argReg(self: *Parser, arg: []const u8) anyerror![]const u8 {
        if (arg.len >= 2 and arg[0] == '"' and arg[arg.len - 1] == '"') {
            return try self.materializeStringChunk(arg[1 .. arg.len - 1]);
        }
        return arg;
    }

    /// Trait-downgrade static dispatch: `obj.m(args)` where `obj` has a
    /// concrete class type lowers to `t = call @C_m(obj, args...)` with the
    /// receiver as the hidden first (`this: ptr`) parameter. Returns null
    /// when no `C.m` is registered; interface-typed receivers are refused
    /// loudly (dynamic/vtable dispatch is Phase 2).
    fn classMethodEmitName(self: *Parser, static_type: []const u8, method: []const u8) anyerror!?[]const u8 {
        const key = try self.methodKey(static_type, method);
        if (self.class_methods.contains(key)) {
            // Copy-down alias: the body emits once under the defining class.
            if (self.method_emit_owner.get(key)) |owner| {
                return try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, method });
            }
            return try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ static_type, method });
        }
        return null;
    }

    fn classMethodIsVoid(self: *Parser, static_type: []const u8, method: []const u8) anyerror!bool {
        const key = try self.methodKey(static_type, method);
        if (self.class_methods.get(key)) |sig| {
            if (sig.is_void or std.mem.eql(u8, method, "ctor")) return true;
            // Unannotated methods emit void-typed functions (no `->`), so a
            // value call would name a void result (LLVMBackend rejects it).
            // Only known-real bodies count: pre-scan stubs (forward calls)
            // keep the old assign-temp behavior.
            if (sig.ret == null and sig.body_src != null) return true;
        }
        return false;
    }

    fn lowerClassMethodCall(self: *Parser, left: []const u8, member_name: []const u8) anyerror![]const u8 {
        const tv = self.scope_manager.lookup(left) orelse return error.UnknownMethod;
        // Copy the receiver type slice NOW: `newTemp` below can reallocate
        // the variables array, dangling `tv` (observed as a garbage
        // `type_name.len` overflowing the arena in `methodKey`).
        const recv_type: []const u8 = tv.type_name;
        const emit_name = (try self.classMethodEmitName(recv_type, member_name)) orelse {
            // Interface-typed receiver with a class impl somewhere: dynamic
            // dispatch is not lowered yet, refuse loudly instead of miscompiling.
            if (self.layout_table.find(recv_type) != null) return error.UnknownMethod;
            return error.UnknownMethod;
        };
        try self.expect(.l_paren);
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const a = try self.parseExpression();
            try args.append(try self.argReg(a));
            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);
        // Short-call padding for defaulted/optional params (mirrors the
        // arrow-alias rule): `this.bubbleUp()` replays `index = ...` in the
        // callee prologue from a padded `0`.
        if (self.class_methods.get(try self.methodKey(recv_type, member_name))) |msig| {
            if (msig.params) |sparams| {
                var mreq: usize = 0;
                for (sparams) |sp| {
                    if (!sp.optional and sp.default_src == null) mreq += 1;
                }
                if (args.items.len < mreq) {
                    _ = try self.refuseAt(
                        "error: too few arguments in call",
                        .{},
                        error.TooFewArguments,
                    );
                    return error.TooFewArguments;
                }
                var mpad: usize = sparams.len;
                if (mpad > args.items.len) {
                    mpad -= args.items.len;
                    var mi: usize = 0;
                    while (mi < mpad) : (mi += 1) {
                        try args.append("0");
                    }
                }
            }
        }
        const is_void = try self.classMethodIsVoid(recv_type, member_name);
        if (is_void) {
            try self.lowerer.emit("    call @{s}({s}", .{ emit_name, left });
            for (args.items) |a| {
                try self.lowerer.emit(", {s}", .{a});
            }
            try self.lowerer.emit(")\n", .{});
            return "0";
        }
        const t = try self.newTemp();
        try self.lowerer.emit("    {s} = call @{s}({s}", .{ t, emit_name, left });
        for (args.items) |a| {
            try self.lowerer.emit(", {s}", .{a});
        }
        try self.lowerer.emit(")\n", .{});
        // Retag the result: method returns like `MapEntry[]` must not stay
        // `i32`, or downstream indexing/for-of derives the wrong stride
        // and field access aborts the caller mid-body.
        if (self.class_methods.get(try self.methodKey(recv_type, member_name))) |sig| {
            if (sig.ret) |rt| {
                if (!std.mem.eql(u8, rt, "void")) {
                    try self.retagTemp(t, rt);
                }
            }
        }
        return t;
    }

    /// Report a loud located diagnostic and fail the lowering with `err`.
    /// Returns `[]const u8` only so it can be `return`ed directly from the
    /// expression-typed lowering paths; it never produces a value.
    fn refuseAt(self: *Parser, comptime fmt: []const u8, args: anytype, err: anyerror) anyerror![]const u8 {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(.{
            .line = self.current.line,
            .col = self.current.col,
            .message = msg,
        });
        // The CLI surfaces parser diagnostics on stderr via this channel;
        // `self.errors` is only consumed programmatically.
        std.debug.print("error:{d}:{d}: {s}\n", .{ self.current.line, self.current.col, msg });
        return err;
    }

    /// Lower `` `head ${e1} mid ${e2} tail` `` to an SA string slice.
    ///
    /// `current` is the `template_start` chunk on entry. Each static chunk is
    /// materialised with `materializeStringChunk`, each `${expr}` with
    /// `renderInterpValue`, and pairs are joined with `concatSlices`. The
    /// expression is a normal `parseExpression`: it stops at the `}` that
    /// closes the interpolation because `}` is not an infix operator. That
    /// `}` is consumed by an explicit `nextTemplateChunk` call (with
    /// `interp_expr_open` forced, so nested templates cannot clobber the
    /// flag), never by the normal `advance` path.
    fn parseInterpolatedTemplate(self: *Parser) anyerror![]const u8 {
        try self.lowerer.emitImport("sa_std/string.sai");
        try self.lowerer.emitImport("sa_std/fmt.sai");

        var acc = try self.materializeStringChunk(stripTemplateHead(self.tokenText(self.current)));
        // Onto the first `${expr}`.
        try self.advance();
        while (true) {
            const val = try self.parseExpression();
            // A nested template ends with `template_end` while the outer
            // `}` is still pending in `peek`; step onto it so the brace
            // check below sees the real close.
            if (self.current.tag == .template_end) try self.advance();
            if (self.current.tag != .r_brace) {
                return self.refuseAt(
                    "error: expected '}}' to close template interpolation, got {s}",
                    .{@tagName(self.current.tag)},
                    error.UnterminatedInterpolation,
                );
            }
            const seg = try self.renderInterpValue(val);
            acc = try self.concatSlices(acc, seg);

            // The two-token lookahead means the lexer cursor is already past
            // this `}` (priming `peek` consumed it and whatever followed), so
            // `nextTemplateChunk` cannot run from the cursor: re-anchor it
            // just past the `}` that closes the interpolation. Line/col are
            // re-anchored too so later tokens keep real positions.
            self.lexer.pos = self.current.start + self.current.len;
            self.lexer.line = self.current.line;
            self.lexer.col = self.current.col + 1;
            self.lexer.interp_expr_open = true;
            const chunk = self.lexer.nextTemplateChunk();
            self.current = chunk;
            self.peek = self.lexer.next();
            const tail = try self.materializeStringChunk(self.tokenText(chunk));
            acc = try self.concatSlices(acc, tail);
            if (chunk.tag == .template_end) break;
            if (chunk.tag != .template_mid) {
                return self.refuseAt(
                    "error: expected template chunk after interpolation, got {s}",
                    .{@tagName(chunk.tag)},
                    error.BadTemplateChunk,
                );
            }
            // Onto the next `${expr}`.
            try self.advance();
        }
        // The final chunk is fully consumed: step onto the token primed after
        // the closing backtick (usually `;`), mirroring the plain path, so no
        // stray `template_end` reaches the statement loop.
        self.current = self.peek;
        self.peek = self.lexer.next();
        self.template_lexer_mode = false;
        self.lexer.interp_expr_open = false;
        return acc;
    }

    /// Render an interpolation operand to a string slice register.
    ///
    /// Strings pass through; integers go through `sext` +
    /// `@sa_fmt_i64_into`, floats through `@sa_fmt_f64_into` (precision 6,
    /// the C-like default; mirrors `sa_plugin_sla` float printing via
    /// `sa_std/fmt.sai`), into a scratch buffer that the slice borrows (the
    /// buffer stays live until scope exit, like any owned temp). String
    /// literals interpolate as their own text. Anything else is refused
    /// loudly: `null`/unknown operands must not silently become digits.
    fn renderInterpValue(self: *Parser, val: []const u8) anyerror![]const u8 {
        try self.rejectFutureOperand(val);
        if (val.len > 0 and val[0] == '"') {
            const inner = if (val.len >= 2) val[1 .. val.len - 1] else "";
            return try self.materializeStringChunk(inner);
        }
        if (self.scope_manager.lookup(val)) |v| {
            if (std.mem.eql(u8, v.type_name, "string")) return val;
            if (isFloatTypeName(v.type_name)) {
                return try self.renderFloatInterpValue(val);
            }
        } else {
            if (isFloatLiteral(val)) {
                return try self.renderFloatInterpValue(val);
            }
            if (!isIntLiteral(val)) {
                return self.refuseAt(
                    "error: cannot interpolate '{s}': only integers, floats and strings lower to text",
                    .{val},
                    error.BadInterpolationOperand,
                );
            }
        }
        const wide = try self.newTemp();
        try self.lowerer.emit("    {s} = sext {s} as i64\n", .{ wide, val });
        const numbuf = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 64\n", .{numbuf});
        const numlen = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 8\n", .{numlen});
        const rc = try self.newTemp();
        try self.lowerer.emit("    {s} = call @sa_fmt_i64_into({s}, 10, {s}, 64, &{s})\n", .{ rc, wide, numbuf, numlen });
        const nlen = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as u64\n", .{ nlen, numlen });
        const vslice = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 16\n", .{vslice});
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ vslice, numbuf });
        try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ vslice, nlen });
        try self.releaseOwnedIfLive(rc);
        try self.releaseOwnedIfLive(nlen);
        try self.retagTemp(vslice, "string");
        return vslice;
    }

    /// Render a float operand via `@sa_fmt_f64_into` (precision 6).
    /// Shape mirrors the integer path above and `sa_plugin_sla` float
    /// printing: scratch 64-byte buffer + 8-byte length slot, then pack a
    /// fresh 16-byte `{ptr, len}` slice retagged as `string`.
    fn renderFloatInterpValue(self: *Parser, val: []const u8) anyerror![]const u8 {
        const numbuf = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 64\n", .{numbuf});
        const numlen = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 8\n", .{numlen});
        const rc = try self.newTemp();
        try self.lowerer.emit("    {s} = call @sa_fmt_f64_into({s}, 6, {s}, 64, &{s})\n", .{ rc, val, numbuf, numlen });
        const nlen = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as u64\n", .{ nlen, numlen });
        const vslice = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 16\n", .{vslice});
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ vslice, numbuf });
        try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ vslice, nlen });
        try self.releaseOwnedIfLive(rc);
        try self.releaseOwnedIfLive(nlen);
        try self.retagTemp(vslice, "string");
        return vslice;
    }

    /// Whether `name` is a float source-level type (`f64`/`f32`).
    fn isFloatTypeName(name: []const u8) bool {
        return std.mem.eql(u8, name, "f64") or std.mem.eql(u8, name, "f32");
    }

    /// Whether `text` looks like a float literal (`[-]digits.digits`).
    fn isFloatLiteral(text: []const u8) bool {
        if (text.len == 0) return false;
        var i: usize = 0;
        if (text[0] == '-') {
            if (text.len == 1) return false;
            i = 1;
        }
        var digits_before: usize = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            digits_before += 1;
        }
        if (i >= text.len or text[i] != '.') return false;
        i += 1;
        var digits_after: usize = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            digits_after += 1;
        }
        return digits_before > 0 and digits_after > 0 and i == text.len;
    }

    /// Whether a value register/literal should be treated as float for
    /// type-directed lowering (copies sa_plugin_sla's
    /// `isFloatType or` rule): float-typed variable or float literal.
    fn isFloatOperand(self: *Parser, val: []const u8) bool {
        if (self.scope_manager.lookup(val)) |v| {
            if (isFloatTypeName(v.type_name)) return true;
            return false;
        }
        return isFloatLiteral(val);
    }

    /// Join two string slices with the body of stdlib's `STR_CONCAT` macro
    /// inlined: `@sa_string_concat` yields a buffer handle, which is read
    /// back with `@sa_fmt_buffer_data`/`@sa_fmt_buffer_len` and packed into
    /// a fresh 16-byte slice. Loaded field temps and the buffer handle are
    /// released here (the macro does the same); both input slices and the
    /// output stay live until scope exit.
    fn concatSlices(self: *Parser, left: []const u8, right: []const u8) anyerror![]const u8 {
        const lptr = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ lptr, left });
        const llen = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ llen, left });
        const rptr = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ rptr, right });
        const rlen = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ rlen, right });
        const obuf = try self.newTemp();
        try self.lowerer.emit("    {s} = call @sa_string_concat({s}, {s}, {s}, {s})\n", .{ obuf, lptr, llen, rptr, rlen });
        const optr = try self.newTemp();
        try self.lowerer.emit("    {s} = call @sa_fmt_buffer_data({s})\n", .{ optr, obuf });
        const olen = try self.newTemp();
        try self.lowerer.emit("    {s} = call @sa_fmt_buffer_len({s})\n", .{ olen, obuf });
        const out = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 16\n", .{out});
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ out, optr });
        try self.lowerer.emit("    store {s} + 8, {s} as u64\n", .{ out, olen });
        try self.releaseOwnedIfLive(lptr);
        try self.releaseOwnedIfLive(llen);
        try self.releaseOwnedIfLive(rptr);
        try self.releaseOwnedIfLive(rlen);
        try self.releaseOwnedIfLive(optr);
        try self.releaseOwnedIfLive(olen);
        try self.releaseOwnedIfLive(obuf);
        try self.retagTemp(out, "string");
        return out;
    }

    /// Strip the opening backtick from a `template_start` chunk. The token
    /// starts at the backtick but its length covers only the literal text, so
    /// the raw slice still carries the leading `` ` `` (`sum=${x}` would
    /// otherwise materialise "`sum="). `template_mid`/`template_end` chunks
    /// from `nextTemplateChunk` start after `}`/content and need no strip.
    fn stripTemplateHead(text: []const u8) []const u8 {
        if (text.len > 0 and text[0] == '`') return text[1..];
        return text;
    }

    /// Print an SA string slice (`{ptr, len}`) to stdout.
    ///
    /// Shape is copied from sa_plugin_sla's `emitPrintln`: a `call
    /// @sa_print_bytes(&ptr, len)` with the slice fields loaded into temps
    /// (from `sa_std/io/print.sai`, the Zig-backed stdout primitive). Loaded
    /// field temps are released here, mirroring `concatSlices`; the input
    /// slice itself stays live until scope exit.
    fn printSliceText(self: *Parser, slice_reg: []const u8) anyerror!void {
        try self.lowerer.emitImport("sa_std/io/print.sai");
        const sptr = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ sptr, slice_reg });
        const slen = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ slen, slice_reg });
        try self.lowerer.emit("    call @sa_print_bytes(&{s}, {s})\n", .{ sptr, slen });
        try self.releaseOwnedIfLive(sptr);
        try self.releaseOwnedIfLive(slen);
    }

    /// Print static text by materialising it as a string slice first, so the
    /// call shape stays uniform with `printSliceText` (separators, newlines).
    fn printConstText(self: *Parser, text: []const u8) anyerror!void {
        const slice_reg = try self.materializeStringChunk(text);
        try self.printSliceText(slice_reg);
    }

    /// Print one `console.log` operand: normalise it to a text slice with
    /// `renderInterpValue` (strings pass through, integers render via
    /// `sext` + `@sa_fmt_i64_into`, booleans as 0/1, anything else refused
    /// loudly there) and print the slice.
    fn printLogValue(self: *Parser, val: []const u8) anyerror!void {
        // Integer operands render through `@sa_fmt_i64_into` /
        // `@sa_string_concat`, so their modules must be imported even when
        // no template literal is involved (deduped by `emitImport`).
        try self.lowerer.emitImport("sa_std/string.sai");
        try self.lowerer.emitImport("sa_std/fmt.sai");
        const seg = try self.renderInterpValue(val);
        try self.printSliceText(seg);
    }

    /// Whether `text` is a plain integer literal (optional `-`, digits only).
    /// Only these lower through `sext`; anything else reaching the renderer
    /// as a bare operand (floats, `null`, booleans-as-text) is refused.
    fn isIntLiteral(text: []const u8) bool {        if (text.len == 0) return false;
        var i: usize = 0;
        if (text[0] == '-') {
            if (text.len == 1) return false;
            i = 1;
        }
        if (i >= text.len) return false;
        for (text[i..]) |ch| {
            if (ch < '0' or ch > '9') return false;
        }
        return true;
    }

    /// Parse arrow function body and emit closure callback + context.
    ///
    /// `params` are the arrow's own parameters (excluding `ctx`, which is
    /// always appended last). They are declared as owned registers in the
    /// callback scope so they are released on every exit path, mirroring
    /// `parseFunction`. Captured outer variables are packed into the context
    /// struct as before; parameter names never become captures.
    /// Block bodies keep the historic void shape when they take no params
    /// (`cb(ctx: ptr):`), so the existing test stays green. Any arrow with
    /// params, and any expression body, declares `-> i32:`: expression bodies
    /// lower to `return <expr>` per JS semantics, and param block bodies may
    /// return a value the same way.
    /// `ret_is_slice` comes from an explicit return annotation (`: T[]` or
    /// `: string`): slice returns declare `-> ptr`, since a `-> i32`
    /// callback returning a slice register is rejected at build time.
    fn parseArrowBody(self: *Parser, params: []const ArrowParam, ret_is_slice: bool) anyerror![]const u8 {
        const cb_id = self.nextLabelId();
        const cb_name = try std.fmt.allocPrint(self.allocator, "@closure_callback_{d}", .{cb_id});
        // Self-recursion: `const name = (...) => ...` registered `name` as
        // pending; bind it now (arity is known up front) so body calls
        // resolve through the alias table instead of failing as undefined.
        // The entry is overwritten with the real context after the body.
        if (self.pending_arrow_bind) |bname| {
            self.pending_arrow_bind = null;
            var arity: u8 = 0;
            var required: u8 = 0;
            for (params) |pp| {
                arity += 1;
                if (!pp.optional) required += 1;
            }
            const bkey = try self.allocator.dupe(u8, bname);
            try self.arrow_aliases.put(bkey, .{ .cb = cb_name, .ctx = "ctx", .arity = arity, .required = required, .self_call = true });
        }

        // Scan body to find captured variables from outer scope
        var captures = std.ArrayList(scope_mod.Variable).init(self.allocator);
        defer captures.deinit();

        const is_expr_body = self.current.tag != .l_brace;
        const value_cb = params.len > 0 or is_expr_body;

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
                    var is_param = false;
                    for (params) |p| {
                        if (std.mem.eql(u8, p.name, name)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (is_param) {
                        try self.advance();
                        continue;
                    }
                    // Arrow aliases (named functions and callbacks) resolve
                    // through the alias table at call sites; capturing the
                    // `fn` pseudo-variable as a context value would emit a
                    // bogus `name = load ctx + off` for a non-register. This
                    // also keeps self-recursive references out of the context.
                    if (self.arrow_aliases.get(name) != null) {
                        try self.advance();
                        continue;
                    }
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
        } else {
            // Expression body `x => x + 1`: scan the single expression for
            // outer references with a save/restore lookahead. The expression
            // is re-parsed for real below, so this scan must not consume.
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            // Scan until a statement boundary (`,`, `)`, `;`, `}` or EOF) at
            // depth zero. This is heuristic but covers call args, `let` inits
            // and bare expression statements where arrows appear.
            var p_depth: u32 = 0;
            while (self.current.tag != .eof) {
                if (self.current.tag == .l_paren) p_depth += 1;
                if (self.current.tag == .r_paren) {
                    if (p_depth == 0) break;
                    p_depth -= 1;
                }
                if (p_depth == 0 and (self.current.tag == .comma or self.current.tag == .semicolon or self.current.tag == .r_brace)) break;
                if (self.current.tag == .identifier) {
                    const name = self.currentText();
                    var is_param = false;
                    for (params) |p| {
                        if (std.mem.eql(u8, p.name, name)) {
                            is_param = true;
                            break;
                        }
                    }
                    // Same alias skip as the block-body scan above: callable
                    // names are not capturable values.
                    if (!is_param and self.arrow_aliases.get(name) != null) {
                        try self.advance();
                        continue;
                    }
                    if (!is_param) {
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
                }
                try self.advance();
            }
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

        // SA-ASM has no nested functions: the callback must not be emitted
        // inline inside the parent's basic block (FallthroughForbidden).
        // Swap emission to a scratch lowerer with its own CFG state, then
        // splice the finished callback into the file-scope `callbacks`
        // buffer. The parent-side context allocation below runs on the
        // original lowerer after the swap is restored.
        const orig_low = self.lowerer;
        var tmp_low = lowerer_mod.Lowerer.init(self.allocator);
        defer tmp_low.deinit();
        self.lowerer = &tmp_low;
        defer self.lowerer = orig_low;
        tmp_low.beginFunction();

        // Mirror `parseFunction`: releases are emitted at return sites and
        // at function exit, never by a bare scope pop. Without this a
        // top-level arrow's `}` pop emitted `!` for still-live registers
        // (including the just-returned value, after its terminator), because
        // `defer_releases` defaults to off outside `parseFunction`.
        const saved_defer = self.scope_manager.defer_releases;
        self.scope_manager.defer_releases = true;
        defer self.scope_manager.defer_releases = saved_defer;

        // Emit callback function. Params come first, `ctx` is always last so
        // call sites can append `^ctx` unconditionally.
        try self.lowerer.emit("{s}(", .{cb_name});
        for (params, 0..) |p, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}: {s}", .{ p.name, saTypeOf(p.type_name) });
        }
        if (params.len > 0) try self.lowerer.emit(", ", .{});
        if (value_cb) {
            // An annotated slice return (`: T[]`, `: string`) declares
            // `-> ptr`; scalars keep the historic `-> i32`.
            if (ret_is_slice) {
                try self.lowerer.emit("ctx: ptr) -> ptr:\n", .{});
            } else {
                try self.lowerer.emit("ctx: ptr) -> i32:\n", .{});
            }
        } else {
            try self.lowerer.emit("ctx: ptr):\n", .{});
        }
        try self.scope_manager.enterScope();
        self.arrow_depth += 1;
        defer self.arrow_depth -= 1;

        const saved_arrow_value = self.arrow_value_cb;
        self.arrow_value_cb = value_cb;
        defer self.arrow_value_cb = saved_arrow_value;

        const saved_arrow_base = self.arrow_base_depth;
        // Scopes open so far belong to the parent; the callback's own scope
        // was just entered above, so releases stop at `saved` depth... note
        // `enterScope` already ran, so subtract one to exclude it.
        self.arrow_base_depth = self.scope_manager.scopeDepth() - 1;
        defer self.arrow_base_depth = saved_arrow_base;

        // Mark for the param-name fallback set (restored by defer below so
        // nested arrows do not leak names into siblings).
        const param_mark = self.arrow_param_names.items.len;
        for (params) |p| {
            // `_` is a throwaway placeholder (e.g. `(_, i) => i`): binding
            // it would collide across arrows, so it stays undeclared and
            // call sites pass `0` for its slot.
            if (std.mem.eql(u8, p.name, "_")) continue;
            try self.scope_manager.declareVar(p.name, p.type_name, p.name, true);
            // Track unannotated params for the array-method fallback in the
            // dot-dispatch chain (see arrow_param_names). Annotated params
            // carry a real type and need no fallback.
            if (std.mem.eql(u8, p.type_name, "i32")) {
                try self.arrow_param_names.append(p.name);
            }
        }
        defer self.arrow_param_names.shrinkRetainingCapacity(param_mark);

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

        // Short-call defaults replay here, mirroring methods: a call site
        // padding a defaulted parameter with `0` gets the default value.
        try self.emitDefaultPrologue(params);

        // Parse body statements
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            // Termination-aware pop: a body ending in `return <v>` already
            // terminated the block, and a plain `exitScope` would emit the
            // returned value's `!` after the terminator (unreachable, and it
            // flips the terminated flag so a bogus `!ctx` / `return 0` gets
            // appended too). At top level `defer_releases` is off, so the
            // plain pop was also the second emit of every body temp.
            try self.exitScopeReleasingLocals();
            try self.advance();
        } else {
            // Expression body: `return <expr>` per JS semantics. Releases go
            // before the terminator so they stay reachable.
            const val = try self.parseExpression();
            // Scoped to the callback: the parent's registers stay live.
            try self.releaseArrowLiveExcept(val);
            // The context parameter is not tracked in scope (it is named
            // `ctx` in every callback), so release it manually before the
            // terminator. Without this the callback leaks `ctx`.
            try self.lowerer.emit("    !ctx\n", .{});
            try self.lowerer.emitTerm("    return {s}\n", .{val});
        }

        // Release context in callback. For value callbacks the terminator is
        // `return 0` when the body fell through; expression bodies already
        // returned above.
        if (!self.lowerer.isTerminated()) {
            try self.releaseArrowLive();
            try self.lowerer.emit("    !ctx\n", .{});
            if (value_cb) {
                try self.lowerer.emitTerm("    return 0\n", .{});
            }
        } else {
            // A `return <expr>` already terminated the block; `!ctx` after it
            // would be unreachable code, so release ctx before it is too late
            // is impossible here. The early-return path leaks ctx by design
            // today; value callbacks are still assembler-valid.
            try self.scope_manager.exitScope(self.lowerer);
            // Seal the out-of-line callback before touching the parent stream.
            {
                const default_ret: []const u8 = if (value_cb) "return 0" else "return";
                try self.lowerer.finishFunction(default_ret);
                try orig_low.callbacks.appendSlice(tmp_low.output.items);
                // Doubly-nested callbacks (e.g. map inside map): the inner
                // definition lands in tmp_low.callbacks, not output.
                try orig_low.callbacks.appendSlice(tmp_low.callbacks.items);
                if (tmp_low.header.items.len > 0) try orig_low.header.appendSlice(tmp_low.header.items);
                for (tmp_low.imports.items) |imp| try orig_low.emitImport(imp);
                self.lowerer = orig_low;
            }
            // Align final ctx size to max alignment (8 for ptr)
            if (ctx_size > 0 and captures.items.len > 0) {
                ctx_size = alignTo(ctx_size, 8);
            }
            const parent_ctx_early = try std.fmt.allocPrint(self.allocator, "ctx_{d}", .{cb_id});
            // Always materialise a context so `^ctx_N` is defined even when
            // nothing is captured: the callback unconditionally takes `ctx`
            // and releases it, so an undefined register would fail assembly.
            const early_size: u32 = if (ctx_size == 0) 8 else ctx_size;
            try self.lowerer.emit("    {s} = alloc {d}\n", .{ parent_ctx_early, early_size });
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
                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ parent_ctx_early, offset, cap.name, store_type });
                offset += cap_size;
            }
            // Each arrow gets its own parent-side context register so two
            // arrows in one function do not clobber each other.
            self.last_arrow_ctx = try std.fmt.allocPrint(self.allocator, "^{s}", .{parent_ctx_early});
            // Publish arity for the `const f = <arrow>` alias recorded by
            // `parseLet`: short calls pad missing defaulted params with `0`.
            // Set at exit (not entry) so a nested arrow's values do not stick.
            self.last_arrow_arity = @as(u8, @intCast(params.len));
            {
                var req_count: u8 = 0;
                for (params) |pp| {
                    if (!pp.optional) req_count += 1;
                }
                self.last_arrow_required = req_count;
            }
            // Captureless callbacks lower as `fn` values (vtable + indirect
            // call); record for the default-replay and decay sites.
            if (captures.items.len == 0) {
                try self.captureless_cb.put(cb_name, {});
            }
            return cb_name;
        }
        try self.scope_manager.exitScope(self.lowerer);
        // Seal the out-of-line callback before touching the parent stream.
        {
            const default_ret: []const u8 = if (value_cb) "return 0" else "return";
            try self.lowerer.finishFunction(default_ret);
            try orig_low.callbacks.appendSlice(tmp_low.output.items);
            // Doubly-nested callbacks land in tmp_low.callbacks (see above).
            try orig_low.callbacks.appendSlice(tmp_low.callbacks.items);
            if (tmp_low.header.items.len > 0) try orig_low.header.appendSlice(tmp_low.header.items);
            for (tmp_low.imports.items) |imp| try orig_low.emitImport(imp);
            self.lowerer = orig_low;
        }

        // Align final ctx size to max alignment (8 for ptr)
        if (ctx_size > 0 and captures.items.len > 0) {
            ctx_size = alignTo(ctx_size, 8);
        }

        // In the parent scope, allocate and populate context
        const parent_ctx = try std.fmt.allocPrint(self.allocator, "ctx_{d}", .{cb_id});
        {
            const emit_size: u32 = if (ctx_size == 0) 8 else ctx_size;
            try self.lowerer.emit("    {s} = alloc {d}\n", .{ parent_ctx, emit_size });

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

                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ parent_ctx, offset, cap.name, store_type });
                offset += cap_size;
            }
        }

        // Store context for caller to pick up as ^ctx_N
        self.last_arrow_ctx = try std.fmt.allocPrint(self.allocator, "^{s}", .{parent_ctx});

        // Publish arity for the `const f = <arrow>` alias recorded by
        // `parseLet`: short calls pad missing defaulted params with `0`.
        // Set at exit (not entry) so a nested arrow's values do not stick.
        self.last_arrow_arity = @as(u8, @intCast(params.len));
        {
            var req_count: u8 = 0;
            for (params) |pp| {
                if (!pp.optional) req_count += 1;
            }
            self.last_arrow_required = req_count;
        }
        if (captures.items.len == 0) {
            try self.captureless_cb.put(cb_name, {});
        }

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
        // `this.f = v` / `this.m(...)` inside class bodies: `this` lexes as a
        // keyword, so bind it as the receiver name and share the paths below.
        var name_tok = self.current;
        var name: []const u8 = undefined;
        if (self.current.tag == .keyword_this) {
            try self.advance();
            name_tok = self.current;
            name = "this";
        } else {
            try self.expect(.identifier);
            name = self.tokenText(name_tok);
        }

        // Postfix assertion on a bare name (`currentNode!.next = ...`):
        // no-op, so the dot/call/index/assign dispatches below see through it.
        while (self.current.tag == .bang) try self.advance();

        if (std.mem.eql(u8, name, "store") and self.current.tag == .identifier) {            // Statement-level intrinsic: `store reg + off, val as Type;`
            // mirrors the SA-ASM instruction (which requires an explicit
            // byte offset) so low-level initialisation can be written inline.
            const base_tok = self.current;
            try self.advance();
            const base = self.tokenText(base_tok);
            try self.expect(.plus);
            const off = try self.parseExpression();
            try self.expect(.comma);
            const val = try self.parseExpression();
            try self.expect(.keyword_as);
            const type_tok = self.current;
            try self.expect(.identifier);
            const type_name = self.tokenText(type_tok);
            _ = try self.accept(.semicolon);
            try self.lowerer.emit("    store {s} + {s}, {s} as {s}\n", .{ base, off, val, saTypeOf(type_name) });
            return;
        }

        if (std.mem.eql(u8, name, "console") and self.current.tag == .dot) {
            // `console.log(a, b, ...)`: print each operand as text separated
            // by a space, then a trailing newline (JS console.log shape).
            // Only `log` is lowerable; other members are refused loudly.
            try self.advance();
            const member_tok = self.current;
            try self.expect(.identifier);
            const member_name = self.tokenText(member_tok);
            if (!std.mem.eql(u8, member_name, "log")) {
                _ = self.refuseAt(
                    "error: unsupported console method '{s}': only console.log lowers to SA-ASM",
                    .{member_name},
                    error.UnsupportedConsoleMethod,
                ) catch |err| return err;
                return error.UnsupportedConsoleMethod;
            }
            try self.expect(.l_paren);
            var first_arg = true;
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                const arg = try self.parseExpression();
                if (!first_arg) try self.printConstText(" ");
                try self.printLogValue(arg);
                first_arg = false;
                _ = try self.accept(.comma);
            }
            try self.expect(.r_paren);
            _ = try self.accept(.semicolon);
            try self.printConstText("\n");
            return;
        }

        if (self.current.tag == .l_paren) {
            // Bare function call
            try self.expect(.l_paren);
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                const arg = try self.parseExpression();
                try args.append(try self.argReg(arg));
                _ = try self.accept(.comma);
            }
            try self.expect(.r_paren);
            _ = try self.accept(.semicolon);

            if (std.mem.eql(u8, name, "alloc") and args.items.len == 1) {
                // Bare `alloc(N);`: the same primitive instruction as the
                // expression form, result discarded. The temp is tracked and
                // released at scope exit, so nothing leaks.
                const temp_name = try self.newTemp();
                try self.lowerer.emit("    {s} = alloc {s}\n", .{ temp_name, args.items[0] });
                return;
            }

            // A future handle must be awaited before it is passed on: the
            // callee would otherwise receive a pointer where it expects a
            // plain value, with no diagnostic at the SA level.
            for (args.items) |arg| {
                try self.rejectFutureOperand(arg);
            }

            // WIT symbols have no valid lowering: refuse at the call site.
            // WASM symbols get their arity-matched `@extern` now, at the first
            // call where the arity is known.
            try self.rejectWitCall(name);
            try self.ensureWasmExtern(name, args.items.len);

            // Check if this is a stdlib function
            if (self.lookupStdlib(name)) |entry| {
                try self.emitStdlibCall(null, entry, args);
            } else if (self.arrow_aliases.get(name)) |alias| {
                // Direct call to an arrow alias: `f(41)` lowers straight to
                // the callback. Unlike higher-order passing (`setTimeout(cb,
                // ^ctx, ms)`, which moves ownership to a storing callee), a
                // direct call borrows the context: the callback declares
                // `ctx: ptr` (borrow contract), so `^ctx` is rejected with
                // CapabilityMismatch. The caller keeps ownership and releases
                // `ctx_N` after the call; the callback's own `!ctx` only ends
                // the borrow. Verified by probe: borrow + both-side `!` gives
                // exit 42, move gives CapabilityMismatch.
                // Alias args used as values expand inline (`g(f, 1)` passes
                // `cb, ctx` for `f`).
                if (alias.plain) {
                    // Plain named function from a top-level arrow: no context
                    // parameter exists, so call directly with just the args.
                    for (args.items) |arg| {
                        if (self.arrow_aliases.get(arg)) |aarg| {
                            if (aarg.plain) {
                                std.debug.print("error:{d}:{d}: plain function '{s}' cannot be passed as a callback value (it takes no context)\n", .{
                                    self.current.line,
                                    self.current.col,
                                    arg,
                                });
                                return error.PlainFunctionAsValue;
                            }
                        }
                    }
                    try self.lowerer.emit("    call @{s}(", .{alias.cb[1..]});
                    for (args.items, 0..) |arg, idx| {
                        if (idx > 0) try self.lowerer.emit(", ", .{});
                        if (self.arrow_aliases.get(arg)) |aarg| {
                            try self.lowerer.emit("{s}, {s}", .{ aarg.cb, aarg.ctx });
                        } else {
                            try self.lowerer.emit("{s}", .{arg});
                        }
                    }
                    // A direct arrow arg in this call still carries its own ctx.
                    if (self.last_arrow_ctx) |ctx_arg| {
                        if (args.items.len > 0) try self.lowerer.emit(", ", .{});
                        try self.lowerer.emit("{s}", .{ctx_arg});
                        self.last_arrow_ctx = null;
                    }
                    try self.lowerer.emit(")\n", .{});
                    return;
                }
                var expanded = std.ArrayList([]const u8).init(self.allocator);
                defer expanded.deinit();
                for (args.items) |arg| {
                    if (self.arrow_aliases.get(arg)) |aarg| {
                        try expanded.append(aarg.cb);
                        try expanded.append(aarg.ctx);
                    } else {
                        try expanded.append(arg);
                    }
                }
                // Short-call padding: missing defaulted params become `0`
                // (the callee prologue replays the default); fewer than the
                // required count is a loud error, not a silent mis-call.
                if (alias.arity > 0) {
                    if (args.items.len < alias.required) {
                        _ = try self.refuseAt(
                            "error: too few arguments in call",
                            .{},
                            error.TooFewArguments,
                        );
                        return error.TooFewArguments;
                    }
                    var need_pad: u8 = alias.arity - @as(u8, @intCast(@min(args.items.len, alias.arity)));
                    while (need_pad > 0) : (need_pad -= 1) {
                        try expanded.append("0");
                    }
                }
                const borrow_ctx = if (alias.ctx.len > 0 and alias.ctx[0] == '^') alias.ctx[1..] else alias.ctx;
                try self.lowerer.emit("    call @{s}(", .{alias.cb[1..]});
                for (expanded.items, 0..) |arg, idx| {
                    if (idx > 0) try self.lowerer.emit(", ", .{});
                    try self.lowerer.emit("{s}", .{arg});
                }
                // The callback's own context is always last (borrowed).
                if (expanded.items.len > 0) try self.lowerer.emit(", ", .{});
                try self.lowerer.emit("{s}", .{borrow_ctx});
                // A direct arrow arg in this call still carries its own ctx.
                if (self.last_arrow_ctx) |ctx_arg| {
                    try self.lowerer.emit(", {s}", .{ctx_arg});
                    self.last_arrow_ctx = null;
                }
                try self.lowerer.emit(")\n", .{});
                // Self-recursion passes the callback's own `ctx`: the shared
                // exit sequence owns its single release, so skip the trailing
                // borrow release here (per ArrowAlias.self_call). Emitting it
                // desyncs branch joins (`cond ? a : self(...)` leaves one arm
                // Consumed and the other Active -> PhiStateConflict).
                if (!alias.self_call) try self.lowerer.emit("    !{s}\n", .{borrow_ctx});
            } else {
                try self.lowerer.emit("    call @{s}(", .{name});
                // Arrow closure context travels immediately after the callback
                // (`setTimeout(cb, ^ctx, ms)`), which is the historic shape the
                // test asserts. Zero-arg calls have no callback slot, so `^ctx`
                // becomes the sole argument.
                if (self.last_arrow_ctx) |ctx_arg| {
                    if (args.items.len == 0) {
                        try self.lowerer.emit("{s}", .{ctx_arg});
                    } else {
                        for (args.items, 0..) |arg, idx| {
                            if (idx > 0) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}", .{arg});
                            if (idx == 0) {
                                try self.lowerer.emit(", {s}", .{ctx_arg});
                            }
                        }
                    }
                    self.last_arrow_ctx = null;
                } else {
                    // Alias values passed as arguments expand to `cb, ctx`.
                    var first = true;
                    for (args.items) |arg| {
                        if (self.arrow_aliases.get(arg)) |aarg| {
                            if (!first) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}, {s}", .{ aarg.cb, aarg.ctx });
                            first = false;
                        } else {
                            if (!first) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}", .{arg});
                            first = false;
                        }
                    }
                }
                try self.lowerer.emit(")\n", .{});
            }
        } else if (self.current.tag == .dot) {
            // Assignment via property access: obj.field = val
            var left_name = name;
            var chain_base: ?[]const u8 = null;
            var chain_off: u32 = 0;
            var chain_ty: ?[]const u8 = null;
            var chain_len: u32 = 0;
            while (self.current.tag == .dot) {
                try self.advance();
                // Postfix non-null assertion mid-chain (`this.tail!.next`):
                // no-op, same as the expression-level `!` skip.
                while (self.current.tag == .bang) try self.advance();
                const member_tok = self.current;
                try self.expect(.identifier);
                const member_name = self.tokenText(member_tok);

                // Statement-level native Map call: `m.set(k, v);`
                // The field path below has no layout for `Map`, so dispatch
                // here and discard the result.
                if (self.isMapVar(left_name) and self.current.tag == .l_paren) {
                    _ = try self.lowerMapMethodCall(left_name, member_name);
                    _ = try self.accept(.semicolon);
                    return;
                }
                // Statement-level native Set call: `s.add(v);` (same).
                if (self.isSetVar(left_name) and self.current.tag == .l_paren) {
                    _ = try self.lowerSetMethodCall(left_name, member_name);
                    _ = try self.accept(.semicolon);
                    return;
                }
                // Statement-level Array call: `arr.push(v);` (grow-copy).
                if (self.isArrayVar(left_name) and self.current.tag == .l_paren) {
                    _ = try self.lowerArrayMethodCall(left_name, member_name);
                    _ = try self.accept(.semicolon);
                    return;
                }
                // Statement-level `s.charCodeAt(i);` (result discarded).
                if (std.mem.eql(u8, member_name, "charCodeAt") and self.current.tag == .l_paren) {
                    try self.expect(.l_paren);
                    const idx = try self.parseExpression();
                    try self.expect(.r_paren);
                    _ = try self.lowerStringCharCodeAt(left_name, idx);
                    _ = try self.accept(.semicolon);
                    return;
                }
                // Statement-level class call: `obj.m(args);` (trait downgrade:
                // static dispatch on the receiver's concrete type).
                if (self.current.tag == .l_paren) {
                    if (self.scope_manager.lookup(left_name)) |lv| {
                        const mkey = try self.methodKey(lv.type_name, member_name);
                        if (self.class_methods.contains(mkey)) {
                            _ = try self.lowerClassMethodCall(left_name, member_name);
                            _ = try self.accept(.semicolon);
                            return;
                        }
                    }
                }
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
                    // store obj.field = expr (chains fold right: `a.b = c.d = v`)
                    try self.advance();
                    const val = try self.parseAssignRhs();
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
                    chain_base = left_name;
                    chain_off = field.offset;
                    chain_ty = field.type_name;
                    chain_len += 1;
                    left_name = temp_name;
                    // Postfix assertion after a member (`x.next!.prev`):
                    // skip it before the next loop-head check.
                    while (self.current.tag == .bang) try self.advance();
                }
            }
            // Single-segment member update: `obj.f++` / `this.size--`.
            // (Multi-segment chains stay loads; write-back through a temp
            // would store into the temp, not the original object.)
            if (chain_len == 1 and (self.current.tag == .plus_plus or self.current.tag == .minus_minus)) {
                const is_inc = self.current.tag == .plus_plus;
                try self.advance();
                _ = try self.accept(.semicolon);
                const base = chain_base orelse left_name;
                const ty = chain_ty orelse "i32";
                const cur = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + {d} as {s}\n", .{ cur, base, chain_off, saTypeOf(ty) });
                const nxt = try self.newTemp();
                try self.lowerer.emit("    {s} = {s} {s}, 1\n", .{ nxt, if (is_inc) "add" else "sub", cur });
                self.scope_manager.markConsumed(cur);
                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ base, chain_off, nxt, saTypeOf(ty) });
                self.scope_manager.markConsumed(nxt);
                return;
            }
            // Trailing non-null assertion (`this.tail! = node`): no-op.
            while (self.current.tag == .bang) try self.advance();
            // Index into a chained base: `this.queue[i] = v` (slice store)
            // or `node.children[k] = v` (Map insert) / `m[k]` (Map get).
            // The direct-`name[i]` path below only fires without a dot chain.
            if (self.current.tag == .l_bracket) {
                try self.advance();
                const chain_index = try self.parseExpression();
                try self.expect(.r_bracket);
                if (self.isMapVar(left_name)) {
                    const cks = try self.mapKeySlice(chain_index);
                    if (try self.accept(.equal)) {
                        const cval = try self.parseExpression();
                        _ = try self.accept(.semicolon);
                        try self.lowerer.emitImport("sa_std/btree_map.sa");
                        try self.lowerer.emit("    call @sa_btree_map_insert(&{s}, &{s}, {s})\n", .{ left_name, cks, cval });
                        return;
                    }
                    const cget = try self.newTemp();
                    try self.lowerer.emitImport("sa_std/btree_map.sa");
                    try self.lowerer.emit("    {s} = call @sa_btree_map_get(&{s}, &{s})\n", .{ cget, left_name, cks });
                    _ = try self.accept(.semicolon);
                    return;
                }
                if (self.current.tag == .equal or self.current.tag == .plus_equal or self.current.tag == .minus_equal) {
                    const ch_add_assign = self.current.tag != .equal;
                    const ch_add_plus = self.current.tag == .plus_equal;
                    try self.advance();
                    const chain_val = try self.parseExpression();
                    _ = try self.accept(.semicolon);
                    // `left_name` is the slice header temp: address elements
                    // through its data pointer, like the direct path below.
                    var ch_elem: []const u8 = "i32";
                    if (self.scope_manager.lookup(left_name)) |clv| {
                        ch_elem = elementTypeOf(clv.type_name);
                    }
                    var ch_size: u32 = 4;
                    var ch_align: u32 = 4;
                    try getTypeSizeAndAlign(ch_elem, &ch_size, &ch_align);
                    const ch_base = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ch_base, left_name });
                    const ch_off = try self.newTemp();
                    try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ ch_off, chain_index, ch_size });
                    const ch_addr = try self.newTemp();
                    try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ ch_addr, ch_base, ch_off });
                    if (ch_add_assign) {
                        // `this.arr[i] += v` / `-= v` (disjoint `join`).
                        const ch_cur = try self.newTemp();
                        try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ ch_cur, ch_addr, saTypeOf(ch_elem) });
                        const ch_nxt = try self.newTemp();
                        try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ ch_nxt, if (ch_add_plus) "add" else "sub", ch_cur, chain_val });
                        self.scope_manager.markConsumed(ch_cur);
                        try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ ch_addr, ch_nxt, saTypeOf(ch_elem) });
                        self.scope_manager.markConsumed(ch_nxt);
                    } else {
                        try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ ch_addr, chain_val, saTypeOf(ch_elem) });
                    }
                    return;
                }
            }
        } else if (self.current.tag == .l_bracket) {
            // Array indexing: arr[i] = val or arr[i]
            try self.advance();
            const index = try self.parseExpression();
            try self.expect(.r_bracket);

            if (self.current.tag == .l_bracket) {
                // Chained index store: `mat[i][j] = v` / `+= v` (the single-
                // level path below only fires for `arr[i]`). Resolve the
                // outer header, load the inner header, then store through it.
                // Element sizes derive from the declared type when known;
                // `any` receivers step pointer-sized headers (see above).
                try self.advance();
                const index2 = try self.parseExpression();
                try self.expect(.r_bracket);
                if (self.current.tag == .equal or self.current.tag == .plus_equal or self.current.tag == .minus_equal) {
                    const ch_assign = self.current.tag != .equal;
                    const ch_plus = self.current.tag == .plus_equal;
                    try self.advance();
                    const ch_val = try self.parseExpression();
                    _ = try self.accept(.semicolon);
                    var ch_outer: []const u8 = "i32";
                    if (self.scope_manager.lookup(name)) |cnv| {
                        // `any` chains step pointer-sized headers (see the
                        // expression-index rule above).
                        if (std.mem.eql(u8, cnv.type_name, "any")) {
                            ch_outer = "ptr";
                        } else {
                            ch_outer = elementTypeOf(cnv.type_name);
                        }
                    }
                    var ch_osz: u32 = 4;
                    var ch_oal: u32 = 4;
                    try getTypeSizeAndAlign(ch_outer, &ch_osz, &ch_oal);
                    const ch_inner = elementTypeOf(ch_outer);
                    var ch_isz: u32 = 4;
                    var ch_ial: u32 = 4;
                    try getTypeSizeAndAlign(ch_inner, &ch_isz, &ch_ial);
                    const ch_sa = saTypeOf(ch_inner);
                    const ch_data = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ch_data, name });
                    const ch_off = try self.newTemp();
                    try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ ch_off, index, ch_osz });
                    const ch_haddr = try self.newTemp();
                    try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ ch_haddr, ch_data, ch_off });
                    const ch_hdr = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ch_hdr, ch_haddr });
                    const ch_ptr = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ch_ptr, ch_hdr });
                    const ch_eoff = try self.newTemp();
                    try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ ch_eoff, index2, ch_isz });
                    const ch_eaddr = try self.newTemp();
                    try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ ch_eaddr, ch_ptr, ch_eoff });
                    if (ch_assign) {
                        const ch_cur = try self.newTemp();
                        try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ ch_cur, ch_eaddr, ch_sa });
                        const ch_nxt = try self.newTemp();
                        try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ ch_nxt, if (ch_plus) "add" else "sub", ch_cur, ch_val });
                        self.scope_manager.markConsumed(ch_cur);
                        try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ ch_eaddr, ch_nxt, ch_sa });
                        self.scope_manager.markConsumed(ch_nxt);
                    } else {
                        try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ ch_eaddr, ch_val, ch_sa });
                    }
                    return;
                }
                // Bare chained read as a statement (`mat[i][j];`) is a no-op.
                _ = try self.accept(.semicolon);
                return;
            }

            if (self.current.tag == .equal or self.current.tag == .plus_equal or self.current.tag == .minus_equal) {
                const is_add_assign = self.current.tag != .equal;
                const add_is_plus = self.current.tag == .plus_equal;
                try self.advance();
                const val = try self.parseExpression();
                _ = try self.accept(.semicolon);
                // A Map-typed base stores through the btree, not the slice
                // header (`m[k] = v` sugar for `m.set(k, v)`). Compound
                // assignment on map entries stays refused (no read-modify
                // -write sugar there yet).
                if (self.isMapVar(name)) {
                    if (is_add_assign) {
                        _ = try self.refuseAt(
                            "error: compound assignment on map entries is not supported",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                        return error.ConstructorsNotSupported;
                    }
                    const mks = try self.mapKeySlice(index);
                    try self.lowerer.emitImport("sa_std/btree_map.sa");
                    try self.lowerer.emit("    call @sa_btree_map_insert(&{s}, &{s}, {s})\n", .{ name, mks, val });
                    return;
                }
                // `name` is a slice, so the element address comes from the
                // header's data pointer at +0, not from the header itself.
                var st_elem: []const u8 = "i32";
                if (self.scope_manager.lookup(name)) |nv| {
                    st_elem = elementTypeOf(nv.type_name);
                }
                var st_size: u32 = 4;
                var st_align: u32 = 4;
                try getTypeSizeAndAlign(st_elem, &st_size, &st_align);
                const base_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ base_temp, name });
                const off_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off_temp, index, st_size });
                const addr_temp = try self.newTemp();
                try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, base_temp, off_temp });
                if (is_add_assign) {
                    // `arr[i] += v` / `arr[i] -= v`: load, combine, store.
                    const cur_temp = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ cur_temp, addr_temp, saTypeOf(st_elem) });
                    const nxt_temp = try self.newTemp();
                    try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ nxt_temp, if (add_is_plus) "add" else "sub", cur_temp, val });
                    self.scope_manager.markConsumed(cur_temp);
                    try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ addr_temp, nxt_temp, saTypeOf(st_elem) });
                    self.scope_manager.markConsumed(nxt_temp);
                } else {
                    // `store` requires an explicit byte offset, like `load`.
                    try self.lowerer.emit("    store {s} + 0, {s} as {s}\n", .{ addr_temp, val, saTypeOf(st_elem) });
                }
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
            // Chains fold right (`a = b = v` parses `b = v` first).
            const val = try self.parseAssignRhs();
            _ = try self.accept(.semicolon);

            // Assigning a future handle into a non-future variable would
            // silently store a pointer as a plain value: refuse loudly.
            if (self.scope_manager.lookup(val)) |vv| {
                if (isFutureType(vv.type_name)) {
                    const dst_is_future = if (self.scope_manager.lookup(name)) |dv| isFutureType(dv.type_name) else false;
                    if (!dst_is_future) {
                        std.debug.print("error:{d}:{d}: cannot assign future to '{s}': await it first\n", .{
                            self.current.line,
                            self.current.col,
                            name,
                        });
                        return error.FutureMustBeAwaited;
                    }
                }
            }

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
        } else if (self.current.tag == .plus_equal or self.current.tag == .minus_equal) {
            // Compound assignment on a scalar: `x += v` / `x -= v`.
            const is_add = self.current.tag == .plus_equal;
            try self.advance();
            const val = try self.parseExpression();
            _ = try self.accept(.semicolon);
            const temp = try self.newTemp();
            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp, if (is_add) "add" else "sub", name, val });
            // Rebinding a live register is RegisterRedefinition: kill the
            // old value first (same rule as expression `++`).
            try self.releaseOwnedIfLive(name);
            if (self.scope_manager.lookup(name)) |llv| {
                if (!llv.is_heap_allocated and !llv.is_consumed and !llv.is_released) {
                    try self.lowerer.emit("    !{s}\n", .{name});
                    llv.is_released = true;
                }
            }
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ name, temp });
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
            // Postfix non-null assertion (`this.head!`, `x!.y`): a no-op at
            // runtime, the value is already its lowered form. `!=`/`!==` lex
            // as one token, so a bare `!` here is always the assertion.
            if (self.current.tag == .bang) {
                try self.advance();
                continue;
            }
            // `?.` / `??` / ternary `?:`: the lexer emits single `?`
            // tokens, so dispatch on the peek. Ternary binds loosest and is
            // decided purely by exclusion (`?` not followed by `.`/`?`).
            if (self.current.tag == .question) {
                if (self.peek.tag == .dot) {
                    if (try self.optionalIsCall()) {
                        // `a?.m(...)`: degrade to the plain dot dispatch
                        // (documented; Talgo only chains properties).
                        try self.advance(); // ?
                        left = try self.parseInfix(left, .call);
                    } else {
                        try self.advance(); // ?
                        left = try self.parseOptionalProperty(left);
                    }
                    continue;
                } else if (self.peek.tag == .question) {
                    // `??` binds at or-level: only consume when the caller
                    // allows or/looser (top-level or another `??` rhs).
                    // Otherwise `a == b ?? c` would swallow `?? c` into the
                    // `==` right operand instead of `(a==b) ?? c`.
                    if (@intFromEnum(min_prec) > @intFromEnum(Precedence.@"or")) break;
                    try self.advance(); // ?
                    try self.advance(); // ?
                    left = try self.parseNullishCoalesce(left);
                    continue;
                } else {
                    // Ternary binds loosest: only consume at the loosest
                    // level. Otherwise `a == b ? c : d` parses the `? c : d`
                    // into the `==` right operand (cond becomes literal "0",
                    // emitting `br 0`), instead of `(a==b) ? c : d`.
                    if (min_prec != .lowest) break;
                    try self.advance(); // ?
                    left = try self.parseTernary(left);
                    continue;
                }
            }
            const prec = getPrecedence(self.current.tag);
            if (@intFromEnum(prec) <= @intFromEnum(min_prec)) break;
            left = try self.parseInfix(left, prec);
        }

        return left;
    }

    /// Speculative shape check for `?.`: true when `?.name(` follows (up to
    /// the `(`), i.e. an optional method call rather than a property.
    /// Restores all lexer state; safe before the real parse.
    fn optionalIsCall(self: *Parser) anyerror!bool {
        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_peek = self.peek;
        defer {
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
        }
        // current == `?`, peek == `.`
        try self.advance(); // ?
        if (self.current.tag != .dot) return false;
        try self.advance(); // .
        if (self.current.tag != .identifier) return false;
        try self.advance(); // member
        return self.current.tag == .l_paren;
    }

    /// Allocate an 8-byte join slot for value branches (`?.`, `??`, `?:`):
    /// each arm stores, the merge loads into a fresh temp.
    fn joinSlot(self: *Parser) anyerror![]const u8 {
        const slot = try self.newTemp();
        try self.lowerer.emit("    {s} = alloc 8\n", .{slot});
        return slot;
    }

    /// Reserve a true/false/end label triple for a value join.
    fn joinLabels(self: *Parser, prefix: []const u8) anyerror![3][]const u8 {
        const id = self.nextLabelId();
        const l_true = try std.fmt.allocPrint(self.allocator, "L_{s}_t_{d}", .{ prefix, id });
        const l_false = try std.fmt.allocPrint(self.allocator, "L_{s}_f_{d}", .{ prefix, id });
        const l_end = try std.fmt.allocPrint(self.allocator, "L_{s}_end_{d}", .{ prefix, id });
        try self.lowerer.reserveLabel(l_true);
        try self.lowerer.reserveLabel(l_false);
        try self.lowerer.reserveLabel(l_end);
        return .{ l_true, l_false, l_end };
    }

    /// `a?.field` (cursor on `.`): null-guarded property access. A null
    /// receiver stores zero without touching memory; otherwise the same
    /// load the plain `.` path emits runs. Arms join through a slot.
    fn parseOptionalProperty(self: *Parser, left: []const u8) anyerror![]const u8 {
        try self.expect(.dot);
        const member_tok = self.current;
        try self.expect(.identifier);
        const member_name = self.tokenText(member_tok);
        const v = self.scope_manager.lookup(left) orelse {
            std.debug.print("error:{d}:{d}: property access on undefined variable '{s}'\n", .{
                member_tok.line, member_tok.col, left,
            });
            return error.UndefinedVariable;
        };
        // Length/size aliases lower inline (receivers are non-null slices
        // and maps by construction); only struct fields need the guard.
        if (std.mem.eql(u8, v.type_name, "string") and std.mem.eql(u8, member_name, "length")) {
            const temp_name = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u32\n", .{ temp_name, left });
            return temp_name;
        }
        if (std.mem.eql(u8, member_name, "length") and self.layout_table.find(v.type_name) == null) {
            const temp_name = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ temp_name, left });
            return temp_name;
        }
        if (self.isMapVar(left) and std.mem.eql(u8, member_name, "size")) {
            try self.lowerer.emitImport("sa_std/btree_map.sa");
            const temp_name = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_map_len(&{s})\n", .{ temp_name, left });
            return temp_name;
        }
        if (self.isSetVar(left) and std.mem.eql(u8, member_name, "size")) {
            try self.lowerer.emitImport("sa_std/btree_set.sa");
            const temp_name = try self.newTemp();
            try self.lowerer.emit("    {s} = call @sa_btree_set_len(&{s})\n", .{ temp_name, left });
            return temp_name;
        }
        const layout = self.layout_table.find(v.type_name) orelse return error.TypeIsNotAnInterface;
        var found_field: ?Field = null;
        for (layout.fields.items) |f| {
            if (std.mem.eql(u8, f.name, member_name)) {
                found_field = f;
                break;
            }
        }
        const field = found_field orelse return error.UnknownField;
        const slot = try self.joinSlot();
        const labels = try self.joinLabels("opt");
        const isnull = try self.newTemp();
        try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ isnull, left });
        try self.lowerer.emitBranchTo(isnull, labels[1], labels[0]);
        try self.lowerer.emitLabel(labels[1]);
        try self.lowerer.emit("    store {s} + 0, 0 as ptr\n", .{slot});
        try self.lowerer.emitJumpTo(labels[2]);
        try self.lowerer.emitLabel(labels[0]);
        try self.scope_manager.enterScope();
        const av = try self.newTemp();
        const sa_type = if (std.mem.eql(u8, field.type_name, "i32") or std.mem.eql(u8, field.type_name, "u32") or std.mem.eql(u8, field.type_name, "f64"))
            field.type_name
        else
            "ptr";
        try self.lowerer.emit("    {s} = load {s} + {d} as {s}\n", .{ av, left, field.offset, sa_type });
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slot, av });
        try self.exitScopeReleasingLocals();
        try self.lowerer.emitJumpTo(labels[2]);
        try self.lowerer.emitLabel(labels[2]);
        const res = try self.newTemp();
        try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ res, slot, sa_type });
        try self.retagTemp(res, field.type_name);
        return res;
    }

    /// `a ?? b`: `a` when non-null, else `b`. Arms join through a slot;
    /// the result carries the left arm's type when known.
    fn parseNullishCoalesce(self: *Parser, left: []const u8) anyerror![]const u8 {
        const slot = try self.joinSlot();
        const labels = try self.joinLabels("nullish");
        const isnull = try self.newTemp();
        try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ isnull, left });
        try self.lowerer.emitBranchTo(isnull, labels[0], labels[1]);
        // Right arm first (branch-target order): evaluate `b`.
        try self.lowerer.emitLabel(labels[0]);
        try self.scope_manager.enterScope();
        const rv = try self.parseExpressionWithPrecedence(.lowest);
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slot, rv });
        try self.exitScopeReleasingLocals();
        try self.lowerer.emitJumpTo(labels[2]);
        // Left arm: keep `a` (a store never moves its source).
        try self.lowerer.emitLabel(labels[1]);
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slot, left });
        try self.lowerer.emitJumpTo(labels[2]);
        try self.lowerer.emitLabel(labels[2]);
        const res = try self.newTemp();
        var sa_t: []const u8 = "ptr";
        if (self.scope_manager.lookup(left)) |lv| {
            sa_t = saTypeOf(lv.type_name);
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ res, slot, sa_t });
            try self.retagTemp(res, lv.type_name);
        } else {
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ res, slot });
        }
        return res;
    }

    /// Parse an assignment right-hand side, folding chained stores
    /// (`this.head = this.tail = undefined`, `a = b = v`): when the rhs
    /// opens with a plain-var or single-dot-field target followed by `=`,
    /// consume the target, recurse for the value, store into the target.
    /// A var target moves the value and re-reads from the target; a field
    /// target stores without moving (a `store` never moves its source).
    fn parseAssignRhs(self: *Parser) anyerror![]const u8 {
        if (self.current.tag == .identifier or self.current.tag == .keyword_this) {
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_peek = self.peek;
            try self.advance();
            var dots: usize = 0;
            var shape_ok = true;
            while (self.current.tag == .dot) {
                try self.advance();
                if (self.current.tag == .identifier) {
                    try self.advance();
                    dots += 1;
                } else {
                    shape_ok = false;
                    break;
                }
            }
            // Postfix `!` may sit between target and `=` (`this.t! = v`).
            while (self.current.tag == .bang) try self.advance();
            const is_chained = shape_ok and self.current.tag == .equal and dots <= 1;
            const was_this = saved_current.tag == .keyword_this;
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.peek = saved_peek;
            if (is_chained) {
                if (dots == 0 and !was_this) {
                    const t_tok = self.current;
                    try self.advance();
                    const tname = self.tokenText(t_tok);
                    try self.expect(.equal);
                    const v = try self.parseAssignRhs();
                    try self.emitMove(tname, v);
                    // Re-read from the target: `v` just moved into it.
                    return tname;
                } else if (dots == 1) {
                    var base_is_this = false;
                    var base_name: []const u8 = "";
                    if (self.current.tag == .keyword_this) {
                        try self.advance();
                        base_is_this = true;
                    } else {
                        const bt = self.current;
                        try self.expect(.identifier);
                        base_name = self.tokenText(bt);
                    }
                    try self.expect(.dot);
                    while (self.current.tag == .bang) try self.advance();
                    const ft = self.current;
                    try self.expect(.identifier);
                    const fname = self.tokenText(ft);
                    while (self.current.tag == .bang) try self.advance();
                    try self.expect(.equal);
                    const v = try self.parseAssignRhs();
                    const base_reg = if (base_is_this) "this" else base_name;
                    if (self.scope_manager.lookup(base_reg)) |bv| {
                        if (self.layout_table.find(bv.type_name)) |layout| {
                            for (layout.fields.items) |f| {
                                if (std.mem.eql(u8, f.name, fname)) {
                                    try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ base_reg, f.offset, v, saTypeOf(f.type_name) });
                                    return v;
                                }
                            }
                        }
                    }
                    return v;
                }
            }
        }
        return self.parseExpression();
    }

    /// `c ? a : b`: branch + slot join. The result carries the true arm's
    /// type when known (8-byte slot stores preserve int bit patterns, so a
    /// later narrow load reads the same value).
    fn parseTernary(self: *Parser, cond: []const u8) anyerror![]const u8 {
        const slot = try self.joinSlot();
        const labels = try self.joinLabels("tern");
        try self.lowerer.emitBranchTo(try self.condReg(cond), labels[0], labels[1]);
        try self.lowerer.emitLabel(labels[0]);
        var tern_flags = try self.scope_manager.snapshotFlags(self.allocator);
        defer self.scope_manager.freeSnap(&tern_flags);
        try self.scope_manager.enterScope();
        const tv = try self.parseExpressionWithPrecedence(.lowest);
        try self.expect(.colon);
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slot, tv });
        // The arm scope pops below (freeing its variable records), so copy
        // the arm type for the merge load before it dangles.
        var tv_type: ?[]const u8 = null;
        if (self.scope_manager.lookup(tv)) |tvar| {
            tv_type = try self.allocator.dupe(u8, tvar.type_name);
        }
        try self.exitScopeReleasingLocals();
        try self.lowerer.emitJumpTo(labels[2]);
        try self.lowerer.emitLabel(labels[1]);
        // The else arm restarts from entry state (see parseIf).
        self.scope_manager.restoreFlags(tern_flags);
        try self.scope_manager.enterScope();
        const fv = try self.parseExpressionWithPrecedence(.lowest);
        try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ slot, fv });
        try self.exitScopeReleasingLocals();
        try self.lowerer.emitJumpTo(labels[2]);
        try self.lowerer.emitLabel(labels[2]);
        const res = try self.newTemp();
        if (tv_type) |tt| {
            const sa_t = saTypeOf(tt);
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ res, slot, sa_t });
            try self.retagTemp(res, tt);
        } else {
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ res, slot });
        }
        return res;
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
                // Bare `x => ...`: single untyped param arrow.
                if (self.current.tag == .arrow) {
                    try self.advance(); // =>
                    var single = [_]ArrowParam{.{ .name = self.tokenText(tok), .type_name = "i32" }};
                    return try self.parseArrowBody(&single, false);
                }
                // Move-forwarding: a register consumed by an earlier move
                // reads as its destination instead (same value, still live).
                // One-shot; rebinds invalidate it (see `markRebound`).
                const word = self.tokenText(tok);
                // Global numeric constants: `NaN` folds to 0 (no NaN
                // payload in the integer subset; documented), `Infinity`
                // to i32 max (same fold as `Number.MAX_VALUE`). A user
                // declaration shadows the global.
                if (self.scope_manager.lookup(word) == null) {
                    if (std.mem.eql(u8, word, "NaN")) return "0";
                    if (std.mem.eql(u8, word, "Infinity")) return "2147483647";
                }
                return word;
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
                // Null is the zero pointer/address: `return null` and
                // `x === null` lower as `0` (there is no `null` register).
                return "0";
            },
            .keyword_this => {
                try self.advance();
                return "this";
            },
            .keyword_super => {
                // `super(args)` runs the parent ctor on `this`;
                // `super.m(args)` statically calls the parent method.
                // Both need the enclosing class (set for every method body,
                // including ctors) and a recorded intra-file parent.
                try self.advance();
                const cur = self.current_class orelse {
                    _ = try self.refuseAt(
                        "error: super outside a class method",
                        .{},
                        error.SuperOutsideClass,
                    );
                    return error.SuperOutsideClass;
                };
                const parent = self.class_parent.get(cur) orelse {
                    _ = try self.refuseAt(
                        "error: super in a class without extends",
                        .{},
                        error.SuperWithoutExtends,
                    );
                    return error.SuperWithoutExtends;
                };
                if (self.current.tag == .l_paren) {
                    try self.advance();
                    // No explicit parent ctor: `super()` is a no-op (there
                    // is no body to run; field memory comes from the child
                    // allocation). Emitting a call would reference a
                    // function that was never declared.
                    const ckey = try self.methodKey(parent, "ctor");
                    if (self.class_methods.get(ckey) == null) {
                        while (self.current.tag != .r_paren and self.current.tag != .eof) {
                            _ = try self.parseExpression();
                            _ = try self.accept(.comma);
                        }
                        try self.expect(.r_paren);
                        return "0";
                    }
                    try self.lowerer.emit("    call @{s}_ctor(this", .{parent});
                    while (self.current.tag != .r_paren and self.current.tag != .eof) {
                        const a = try self.parseExpression();
                        try self.lowerer.emit(", {s}", .{try self.argReg(a)});
                        _ = try self.accept(.comma);
                    }
                    try self.expect(.r_paren);
                    try self.lowerer.emit(")\n", .{});
                    return "0";
                }
                try self.expect(.dot);
                const mtok = self.current;
                try self.expect(.identifier);
                const mname = self.tokenText(mtok);
                try self.expect(.l_paren);
                var sargs = std.ArrayList([]const u8).init(self.allocator);
                defer sargs.deinit();
                while (self.current.tag != .r_paren and self.current.tag != .eof) {
                    const a = try self.parseExpression();
                    try sargs.append(try self.argReg(a));
                    _ = try self.accept(.comma);
                }
                try self.expect(.r_paren);
                const skey = try self.methodKey(parent, mname);
                const sentry = self.class_methods.get(skey) orelse {
                    _ = try self.refuseAt(
                        "error: super.{s} does not resolve in parent '{s}'",
                        .{ mname, parent },
                        error.UnknownParentMethod,
                    );
                    return error.UnknownParentMethod;
                };
                // Resolve through the copy-down alias chain: the body emits
                // once under the defining class (`Min.swap` aliases
                // `Heap.swap`, so `super.swap` in `PQ` calls `@Heap_swap`).
                const semit = self.method_emit_owner.get(skey) orelse parent;
                if (sentry.is_void) {
                    try self.lowerer.emit("    call @{s}_{s}(this", .{ semit, mname });
                    for (sargs.items) |a| {
                        try self.lowerer.emit(", {s}", .{a});
                    }
                    try self.lowerer.emit(")\n", .{});
                    return "0";
                }
                const st = try self.newTemp();
                try self.lowerer.emit("    {s} = call @{s}_{s}(this", .{ st, semit, mname });
                for (sargs.items) |a| {
                    try self.lowerer.emit(", {s}", .{a});
                }
                try self.lowerer.emit(")\n", .{});
                if (sentry.ret) |rt| {
                    if (!std.mem.eql(u8, rt, "void")) try self.retagTemp(st, rt);
                }
                return st;
            },
            .l_paren => {
                try self.advance();
                // Detect arrow function: () =>, (a) =>, (a: T, b) =>.
                // Typed params contain `:` so they never parse as an
                // expression; do a speculative param-list scan first.
                if (self.current.tag == .r_paren and self.peek.tag == .arrow) {
                    // Empty params arrow function
                    try self.advance(); // )
                    try self.advance(); // =>
                    return try self.parseArrowBody(&[_]ArrowParam{}, false);
                }
                if (self.current.tag == .identifier) {
                    const saved_lexer = self.lexer;
                    const saved_current = self.current;
                    const saved_peek = self.peek;
                    var probe = std.ArrayList(ArrowParam).init(self.allocator);
                    defer probe.deinit();
                    var is_arrow = false;
                    // Walk `ident [: type] (, ident [: type])* ) =>`
                    while (true) {
                        if (self.current.tag != .identifier) break;
                        const pn_tok = self.current;
                        try self.advance();
                        _ = try self.accept(.question);
                        var pt: []const u8 = "i32";
                        if (try self.accept(.colon)) {
                            const tt = self.current;
                            // Type names lex as identifiers (or keywords like
                            // `string`); accept either.
                            if (self.current.tag == .identifier) {
                                try self.advance();
                                pt = self.tokenText(tt);
                                // Generic args (`TreeNode<T>`) then array
                                // suffix `T[]`, so typed callbacks still scan
                                // as arrows.
                                try self.skipGenericArgs();
                                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                                    try self.advance(); // [
                                    try self.advance(); // ]
                                }
                            } else {
                                // Unknown token in type position: not an arrow.
                                break;
                            }
                        }
                        if (try self.accept(.equal)) {
                            _ = try self.skipBalancedDefault();
                        }
                        try probe.append(.{ .name = self.tokenText(pn_tok), .type_name = pt });
                        if (try self.accept(.comma)) continue;
                        break;
                    }
                    // Optional return annotation `: T` / `: T[]` between `)`
                    // and `=>` (e.g. `(arr: number[]): number[] =>`). The
                    // probe restores the lexer afterwards, so speculative
                    // advances are free.
                    // After consuming the annotation `current` sits on `=>`
                    // itself (not `)`), so the two shapes need two checks.
                    var ann_consumed = false;
                    if (self.current.tag == .r_paren and self.peek.tag == .colon) {
                        try self.advance(); // )
                        try self.advance(); // :
                        if (self.current.tag == .identifier) {
                            try self.advance(); // base type name
                            try self.skipGenericArgs();
                            while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                                try self.advance(); // [
                                try self.advance(); // ]
                            }
                            // Union remainder (`: number | null`): skip `| U`
                            // arms like the top-level probe does.
                            while (self.current.tag == .pipe) {
                                try self.advance(); // |
                                if (self.current.tag != .identifier and self.current.tag != .keyword_void and self.current.tag != .keyword_null and self.current.tag != .keyword_undefined) break;
                                try self.advance();
                                try self.skipGenericArgs();
                                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                                    try self.advance();
                                    try self.advance();
                                }
                            }
                            ann_consumed = true;
                        }
                    }
                    if (self.current.tag == .r_paren and self.peek.tag == .arrow) {
                        is_arrow = true;
                    } else if (ann_consumed and self.current.tag == .arrow) {
                        is_arrow = true;
                    }
                    // Restore; the real parse below consumes for real.
                    self.lexer = saved_lexer;
                    self.current = saved_current;
                    self.peek = saved_peek;
                    if (is_arrow) {
                        var real = std.ArrayList(ArrowParam).init(self.allocator);
                        defer real.deinit();
                        while (true) {
                            const pn_tok = self.current;
                            try self.expect(.identifier);
                            const pn = self.tokenText(pn_tok);
                            var p_opt = try self.accept(.question);
                            var pt: []const u8 = "i32";
                            if (try self.accept(.colon)) {
                                const tt = self.current;
                                try self.advance();
                                pt = self.tokenText(tt);
                                // Same generic/`T[]` skip as the probe above;
                                // the probe already validated the shape.
                                try self.skipGenericArgs();
                                var arr_pairs: u32 = 0;
                                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                                    try self.advance(); // [
                                    try self.advance(); // ]
                                    arr_pairs += 1;
                                }
                                // Keep the `[]` suffixes: without them an
                                // array param (`arr: number[]`) declares as a
                                // scalar, so `arr.push()` inside the body
                                // misses the Array path and desyncs the parse.
                                if (arr_pairs > 0) {
                                    const buf = try self.allocator.alloc(u8, pt.len + arr_pairs * 2);
                                    @memcpy(buf[0..pt.len], pt);
                                    for (0..arr_pairs) |k| {
                                        buf[pt.len + k * 2] = '[';
                                        buf[pt.len + k * 2 + 1] = ']';
                                    }
                                    pt = buf;
                                }
                            }
                            var p_def: ?[]const u8 = null;
                            if (try self.accept(.equal)) {
                                p_opt = true;
                                p_def = try self.saveBalancedDefault();
                            }
                            try real.append(.{ .name = pn, .type_name = pt, .optional = p_opt, .default_src = p_def });
                            if (try self.accept(.comma)) continue;
                            break;
                        }
                        try self.expect(.r_paren);
                        // The return annotation the probe validated: `: T[]`
                        // and `: string` lower the callback as `-> ptr`.
                        // Unions (`: number | null`) skip `| U` arms.
                        var ret_is_slice = false;
                        if (try self.accept(.colon)) {
                            const rt_tok = self.current;
                            try self.advance();
                            try self.skipGenericArgs();
                            if (std.mem.eql(u8, self.tokenText(rt_tok), "string")) ret_is_slice = true;
                            while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                                try self.advance(); // [
                                try self.advance(); // ]
                                ret_is_slice = true;
                            }
                            while (self.current.tag == .pipe) {
                                try self.advance(); // |
                                if (self.current.tag != .identifier and self.current.tag != .keyword_void and self.current.tag != .keyword_null and self.current.tag != .keyword_undefined) break;
                                try self.advance();
                                try self.skipGenericArgs();
                                while (self.current.tag == .l_bracket and self.peek.tag == .r_bracket) {
                                    try self.advance();
                                    try self.advance();
                                }
                            }
                        }
                        try self.expect(.arrow);
                        const owned = try self.allocator.dupe(ArrowParam, real.items);
                        return try self.parseArrowBody(owned, ret_is_slice);
                    }
                }
                const expr = try self.parseExpression();
                try self.expect(.r_paren);
                // Check for arrow: (expr) => 
                if (self.current.tag == .arrow) {
                    // (single_param) => { ... }
                    try self.advance(); // =>
                    var single = [_]ArrowParam{.{ .name = expr, .type_name = "i32" }};
                    return try self.parseArrowBody(&single, false);
                }
                return expr;
            },
            .minus => {
                try self.advance();
                const operand = try self.parseExpressionWithPrecedence(.product);
                const temp_name = try self.newTemp();
                // Type-directed like the binary ops: float operands need
                // `fneg`; plain `neg` is rejected with InvalidOperand.
                if (self.isFloatOperand(operand)) {
                    try self.lowerer.emit("    {s} = fneg {s}\n", .{ temp_name, operand });
                    try self.retagTemp(temp_name, "f64");
                } else {
                    try self.lowerer.emit("    {s} = sub 0, {s}\n", .{ temp_name, operand });
                }
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
            .keyword_typeof => {
                // `typeof x` folds to its type-tag string literal (JEV:
                // string-literal comparison folding). The subset's `number`
                // params are i32/f64, so they tag "number"; strings tag
                // "string", booleans "boolean", null/undefined "undefined",
                // everything else "object". Returned double-quoted like a
                // string literal so `===`/`!==` against `'number'` folds by
                // content in the comparison arm below (SA has no runtime
                // string eq; emitting `eq "a",'b'` would be rejected).
                try self.advance();
                const operand = try self.parseExpressionWithPrecedence(.prefix);
                var tag: []const u8 = "object";
                if (self.scope_manager.lookup(operand)) |v| {
                    if (std.mem.eql(u8, v.type_name, "string")) {
                        tag = "string";
                    } else if (std.mem.eql(u8, v.type_name, "boolean") or std.mem.eql(u8, v.type_name, "bool")) {
                        tag = "boolean";
                    } else if (std.mem.eql(u8, v.type_name, "undefined") or std.mem.eql(u8, v.type_name, "null") or std.mem.eql(u8, v.type_name, "void")) {
                        tag = "undefined";
                    } else if (isFloatTypeName(v.type_name) or std.mem.eql(u8, v.type_name, "i32") or std.mem.eql(u8, v.type_name, "i64") or std.mem.eql(u8, v.type_name, "u32") or std.mem.eql(u8, v.type_name, "number")) {
                        tag = "number";
                    } else if (isArrayType(v.type_name)) {
                        tag = "object";
                    }
                } else if (operand.len >= 2 and (operand[0] == '"' or operand[0] == '\'')) {
                    tag = "string";
                } else if (std.mem.eql(u8, operand, "1") or std.mem.eql(u8, operand, "0") or isFloatLiteral(operand)) {
                    tag = "number";
                }
                return try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{tag});
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
                // Array literal in expression context (slice-header model,
                // matching `parseLet`: 16-byte `{ptr,len}` header plus a
                // separate element buffer; the old inline layout read back
                // shifted via the +0/+8 header slots).
                try self.advance();
                var vals = std.ArrayList([]const u8).init(self.allocator);
                defer vals.deinit();
                while (self.current.tag != .r_bracket and self.current.tag != .eof) {
                    const val = try self.parseExpression();
                    try vals.append(val);
                    _ = try self.accept(.comma);
                }
                try self.expect(.r_bracket);
                // Element width follows the first element when known
                // (nested `[]` values are header pointers, 8 bytes);
                // otherwise the i32 default keeps scalar literals packed.
                var esz: u32 = 4;
                var sa_elem: []const u8 = "i32";
                var elem_tag: []const u8 = "i32[]";
                for (vals.items) |v| {
                    if (self.scope_manager.lookup(v)) |vv| {
                        if (isArrayType(vv.type_name) or std.mem.eql(u8, vv.type_name, "string")) {
                            esz = 8;
                            sa_elem = "ptr";
                            elem_tag = "ptr[]";
                        }
                        break;
                    }
                }
                const n = @as(u32, @intCast(vals.items.len));
                const hdr = try self.newTemp();
                try self.lowerer.emit("    {s} = alloc 16\n", .{hdr});
                const data_reg = try self.newTemp();
                try self.lowerer.emit("    {s} = alloc {d}\n", .{ data_reg, @max(n * esz, 4) });
                for (vals.items, 0..) |val, idx| {
                    const off = @as(u32, @intCast(idx)) * esz;
                    try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ data_reg, off, val, sa_elem });
                }
                try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ hdr, data_reg });
                try self.lowerer.emit("    store {s} + 8, {d} as u64\n", .{ hdr, n });
                try self.retagTemp(hdr, elem_tag);
                return hdr;
            },
            .keyword_await => {
                // `await` unwraps a future handle into its value, mirroring
                // sa_plugin_sla's await lowering (`planAwaitFuture` +
                // `FUTURE_READY_STATE_INTO_INNER`): the ready value is loaded
                // out of the `{state, value}` handle (ReadyFuture layout,
                // state +0, value +8) and the handle is consumed (state set
                // to 0 = PENDING, so a second poll observes pending, exactly
                // like the std macro). Stores stay width-aware
                // (`saTypeOf(inner)`): the std macro hardcodes `u64`, but TS
                // futures carry typed values (`i32`, `f64`, pointers), so a
                // literal `EXPAND FUTURE_READY_STATE_NEW/INTO_INNER` would be
                // a width mismatch on 32-bit inners.
                //
                // Inside an `async function` (but not inside a nested arrow
                // callback, whose `return` targets the callback, not the
                // async function) a pending handle propagates: state is
                // checked, `0` returns the handle to the caller (SLA's
                // `ready_pending_state_return_if_async` shape:
                // `br pending -> L_pend, L_ready` / `L_pend: return fut`),
                // otherwise the ready value is unwrapped. Pending handles
                // are not constructible yet (every created future is ready),
                // but the branch keeps the lowering honest for consumed
                // (double-awaited) handles and executor-driven futures.
                //
                // Awaiting a plain value is the identity, per JS semantics.
                // Like other unary operators the operand is parsed tightly,
                // so `await f() + 1` awaits the call, then adds.
                try self.advance();
                const operand = try self.parseExpressionWithPrecedence(.prefix);
                if (self.scope_manager.lookup(operand)) |v| {
                    if (isFutureType(v.type_name)) {
                        const inner = futureInner(v.type_name);
                        // The result temp is created after the pending branch
                        // below: creating it before would make the pending-path
                        // cleanup release a register that is only defined on
                        // the ready path (`UnknownRegister`).
                        if (self.async_depth > 0 and self.arrow_depth == 0) {
                            const await_id = self.nextLabelId();
                            const pend_label = try std.fmt.allocPrint(self.allocator, "L_await_pend_{d}", .{await_id});
                            const ready_label = try std.fmt.allocPrint(self.allocator, "L_await_ready_{d}", .{await_id});
                            const state_reg = try self.newTemp();
                            const is_pend = try self.newTemp();
                            try self.lowerer.emit("    {s} = load {s} + 0 as u64\n", .{ state_reg, operand });
                            try self.lowerer.emit("    {s} = eq {s}, 0\n", .{ is_pend, state_reg });
                            try self.lowerer.emitBranchTo(is_pend, pend_label, ready_label);
                            try self.lowerer.emitLabel(pend_label);
                            try self.emitPendingReturnCleanups(operand);
                            try self.lowerer.emitTerm("    return {s}\n", .{operand});
                            try self.lowerer.emitLabel(ready_label);
                        }
                        const temp_name = try self.newTemp();
                        try self.retagTemp(temp_name, inner);
                        try self.lowerer.emit("    {s} = load {s} + 8 as {s}\n", .{ temp_name, operand, saTypeOf(inner) });
                        try self.lowerer.emit("    store {s} + 0, 0 as u64\n", .{operand});
                        return temp_name;
                    }
                }
                return operand;
            },
            .keyword_new => {
                // `new Map()` / `new Array(n)` plus default-constructed
                // declared interfaces. `Map` lowers to the real
                // `sa_std/btree_map.sa` backend (`call @sa_btree_map_new()`);
                // `Array` lowers to the 16-byte `{ptr,len}` slice header plus
                // a zeroed element buffer (same layout as array literals, and
                // what `sa_std` slice helpers expect). Other types fall back
                // to interface default-construction; unknown types and
                // non-literal Array lengths are refused loudly.
                const new_tok = self.current;
                try self.advance();
                const type_tok = self.current;
                try self.expect(.identifier);
                const type_name = self.tokenText(type_tok);
                if (std.mem.eql(u8, type_name, "Map")) {
                    // Skip optional `Map<K, V>` type args at the expression site.
                    if (self.current.tag == .less) {
                        try self.advance();
                        var depth: usize = 1;
                        while (depth > 0 and self.current.tag != .eof) {
                            if (self.current.tag == .less) depth += 1;
                            if (self.current.tag == .greater) depth -= 1;
                            try self.advance();
                        }
                    }
                    try self.expect(.l_paren);
                    if (self.current.tag != .r_paren) {
                        return self.refuseAt(
                            "error: new 'Map' with arguments: Map() takes no arguments",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                    }
                    try self.expect(.r_paren);
                    try self.lowerer.emitImport("sa_std/btree_map.sa");
                    const dest = try self.newTemp();
                    try self.retagTemp(dest, "Map");
                    try self.lowerer.emit("    {s} = call @sa_btree_map_new()\n", .{dest});
                    return dest;
                }
                if (std.mem.eql(u8, type_name, "Set")) {
                    // `new Set<T>()`: same shape as `new Map()` (optional
                    // type args, no value args), backed by btree_set.
                    if (self.current.tag == .less) {
                        try self.advance();
                        var depth: usize = 1;
                        while (depth > 0 and self.current.tag != .eof) {
                            if (self.current.tag == .less) depth += 1;
                            if (self.current.tag == .greater) depth -= 1;
                            try self.advance();
                        }
                    }
                    try self.expect(.l_paren);
                    if (self.current.tag != .r_paren) {
                        return self.refuseAt(
                            "error: new 'Set' with arguments: Set() takes no arguments",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                    }
                    try self.expect(.r_paren);
                    try self.lowerer.emitImport("sa_std/btree_set.sa");
                    const dest = try self.newTemp();
                    try self.retagTemp(dest, "Set");
                    try self.lowerer.emit("    {s} = call @sa_btree_set_new()\n", .{dest});
                    return dest;
                }
                if (std.mem.eql(u8, type_name, "Array")) {
                    var elem_type: []const u8 = "i32";
                    if (self.current.tag == .less) {
                        try self.advance();
                        const elem_tok = self.current;
                        try self.expect(.identifier);
                        elem_type = self.tokenText(elem_tok);
                        while (try self.accept(.comma)) {
                            const skip_tok = self.current;
                            try self.expect(.identifier);
                            _ = self.tokenText(skip_tok);
                        }
                        try self.expect(.greater);
                    }
                    try self.expect(.l_paren);
                    // Empty `new Array()` is a zero-length slice.
                    if (self.current.tag == .r_paren) {
                        try self.expect(.r_paren);
                        const dest = try self.newTemp();
                        try self.emitArrayAllocLit(dest, elem_type, 0);
                        return dest;
                    }
                    // Dynamic length (`new Array(size)`); literals keep the
                    // unrolled path inside the shared emitter.
                    if (self.current.tag != .number) {
                        const n_reg = try self.parseExpression();
                        if (self.current.tag != .r_paren) {
                            return self.refuseAt(
                                "error: new 'Array' takes a single length argument",
                                .{},
                                error.ConstructorsNotSupported,
                            );
                        }
                        try self.expect(.r_paren);
                        const dest = try self.newTemp();
                        try self.emitArrayAllocReg(dest, elem_type, n_reg, true);
                        return dest;
                    }
                    const len_tok = self.current;
                    try self.advance();
                    const len_text = self.tokenText(len_tok);
                    const len_val = std.fmt.parseInt(i64, len_text, 10) catch {
                        return self.refuseAt(
                            "error: new 'Array' length must be an integer literal",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                    };
                    if (len_val < 0) {
                        return self.refuseAt(
                            "error: new 'Array' length must be non-negative",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                    }
                    if (self.current.tag != .r_paren) {
                        return self.refuseAt(
                            "error: new 'Array' takes a single length argument",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                    }
                    try self.expect(.r_paren);
                    const count = @as(u32, @intCast(len_val));
                    const dest = try self.newTemp();
                    try self.emitArrayAllocLit(dest, elem_type, count);
                    return dest;
                }
                if (std.mem.eql(u8, type_name, "Error") or std.mem.eql(u8, type_name, "TypeError") or std.mem.eql(u8, type_name, "RangeError") or std.mem.eql(u8, type_name, "SyntaxError") or std.mem.eql(u8, type_name, "ReferenceError")) {
                    // `new Error(msg)` and siblings (`TypeError`/`RangeError`/...
                    // used pervasively as Talgo input guards): SA has no
                    // exception objects; the message materialises as a string
                    // slice and `throw` panics with it. Non-string payloads
                    // fall back to an empty message.
                    try self.expect(.l_paren);
                    var slice = try self.materializeStringChunk("");
                    if (self.current.tag != .r_paren) {
                        const m = try self.parseExpression();
                        if (m.len >= 2 and (m[0] == '"' or m[0] == '\'')) {
                            slice = try self.materializeStringChunk(m[1 .. m.len - 1]);
                        } else if (self.scope_manager.lookup(m)) |mv| {
                            if (std.mem.eql(u8, mv.type_name, "string")) slice = m;
                        }
                        while (try self.accept(.comma)) {
                            _ = try self.parseExpression();
                        }
                    }
                    try self.expect(.r_paren);
                    return slice;
                }
                // Skip optional `C<T>` type args at the expression site
                // (`new Stack<T>()`): construction is monomorphic here.
                if (self.current.tag == .less) {
                    try self.advance();
                    var depth: usize = 1;
                    while (depth > 0 and self.current.tag != .eof) {
                        if (self.current.tag == .less) depth += 1;
                        if (self.current.tag == .greater) depth -= 1;
                        try self.advance();
                    }
                }
                const layout = self.layout_table.find(type_name) orelse {
                    std.debug.print("error:{d}:{d}: new of unknown type '{s}': only declared interfaces can be default-constructed\n", .{
                        new_tok.line,
                        new_tok.col,
                        type_name,
                    });
                    return error.UnknownInterface;
                };
                try self.expect(.l_paren);
                var ctor_args = std.ArrayList([]const u8).init(self.allocator);
                defer ctor_args.deinit();
                while (self.current.tag != .r_paren and self.current.tag != .eof) {
                    const a = try self.parseExpression();
                    try ctor_args.append(try self.argReg(a));
                    _ = try self.accept(.comma);
                }
                try self.expect(.r_paren);
                const dest = try self.newTemp();
                if (self.scope_manager.lookup(dest)) |tv| {
                    self.allocator.free(tv.type_name);
                    tv.type_name = try self.allocator.dupe(u8, type_name);
                }
                try self.lowerer.emit("    {s} = alloc {d}\n", .{ dest, layout.size });
                for (layout.fields.items) |f| {
                    if (std.mem.eql(u8, f.type_name, "Map") or std.mem.eql(u8, f.type_name, "Record")) {
                        // Map/Record fields always hold btree handles: a
                        // zeroed slot would be a null map (`children = {}`
                        // has no ctor to run in). Fresh btree per `new`; a
                        // ctor body overwrites it when it assigns the field.
                        try self.lowerer.emitImport("sa_std/btree_map.sa");
                        const bt_reg = try self.newTemp();
                        try self.lowerer.emit("    {s} = call @sa_btree_map_new()\n", .{bt_reg});
                        try self.lowerer.emit("    store {s} + {d}, {s} as ptr\n", .{ dest, f.offset, bt_reg });
                    } else {
                        try self.lowerer.emit("    store {s} + {d}, 0 as {s}\n", .{ dest, f.offset, saTypeOf(f.type_name) });
                    }
                }
                // Trait downgrade: `new C(args)` = alloc + zero-init + `@C_ctor`.
                // No explicit ctor keeps the old zero-init behavior. An
                // inherited (aliased) ctor dispatches to the owner's body.
                const ctor_key = try self.methodKey(type_name, "ctor");
                if (self.class_methods.contains(ctor_key)) {
                    const ctor_owner = self.method_emit_owner.get(ctor_key) orelse type_name;
                    const ctor_emit = try std.fmt.allocPrint(self.allocator, "{s}_ctor", .{ctor_owner});
                    try self.lowerer.emit("    call @{s}({s}", .{ ctor_emit, dest });
                    for (ctor_args.items) |a| {
                        try self.lowerer.emit(", {s}", .{a});
                    }
                    // `new TreeNode(data)` vs `(data, left?, right?)`: pad
                    // missing trailing optional params with `0` (undefined).
                    // SA-ASM callees have fixed arity, so the padding keeps the
                    // call well-formed; the ctor stores zeroes for them.
                    if (self.class_methods.get(ctor_key)) |csig| {
                        if (csig.params) |cparams| {
                            if (ctor_args.items.len <= cparams.len) {
                                var pad_ok = true;
                                for (cparams[ctor_args.items.len..]) |mp| {
                                    if (!mp.optional) {
                                        pad_ok = false;
                                        break;
                                    }
                                }
                                if (pad_ok) {
                                    for (cparams[ctor_args.items.len..]) |_| {
                                        try self.lowerer.emit(", 0", .{});
                                    }
                                }
                            }
                        }
                    }
                    try self.lowerer.emit(")\n", .{});
                } else if (ctor_args.items.len > 0) {
                    std.debug.print("error:{d}:{d}: new '{s}' with arguments: no constructor declared\n", .{
                        new_tok.line,
                        new_tok.col,
                        type_name,
                    });
                    return error.ConstructorsNotSupported;
                }
                return dest;
            },
            .l_brace => {
                // Object literal in expression position (`{ value: item } as
                // Node<T>`): collect `name: expr` entries, then require an
                // `as T` annotation carrying the struct layout and build it.
                // A missing annotation stays loud (there is no contextual
                // type inside expressions).
                const brace_tok = self.current;
                try self.advance();
                const Entry = struct { name: []const u8, val: []const u8 };
                var entries = std.ArrayList(Entry).init(self.allocator);
                defer entries.deinit();
                while (self.current.tag != .r_brace and self.current.tag != .eof) {
                    const fn_tok = self.current;
                    try self.expect(.identifier);
                    const fname = self.tokenText(fn_tok);
                    try self.expect(.colon);
                    const fval = try self.parseExpression();
                    try entries.append(.{ .name = fname, .val = fval });
                    _ = try self.accept(.comma);
                    _ = try self.accept(.semicolon);
                }
                try self.expect(.r_brace);
                if (self.current.tag != .keyword_as) {
                    std.debug.print("error:{d}:{d}: object literal needs `as T` in expression position (maps/structs need a layout)\n", .{
                        brace_tok.line, brace_tok.col,
                    });
                    return error.TypeAnnotationRequiredForObjectLiteral;
                }
                try self.advance(); // as
                const lit_type = try self.parseTypeName();
                const layout = self.layout_table.find(lit_type) orelse {
                    std.debug.print("error:{d}:{d}: struct literal of unknown interface '{s}'\n", .{
                        brace_tok.line, brace_tok.col, lit_type,
                    });
                    return error.UnknownInterface;
                };
                const dest = try self.newTemp();
                if (self.scope_manager.lookup(dest)) |tv| {
                    self.allocator.free(tv.type_name);
                    tv.type_name = try self.allocator.dupe(u8, lit_type);
                }
                try self.lowerer.emit("    {s} = alloc {d}\n", .{ dest, layout.size });
                for (layout.fields.items) |f| {
                    try self.lowerer.emit("    store {s} + {d}, 0 as {s}\n", .{ dest, f.offset, saTypeOf(f.type_name) });
                }
                for (entries.items) |e| {
                    for (layout.fields.items) |f| {
                        if (std.mem.eql(u8, f.name, e.name)) {
                            try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ dest, f.offset, e.val, saTypeOf(f.type_name) });
                            break;
                        }
                    }
                }
                return dest;
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

        // Generic call form `Array<T>(n)`: the `<T>` arrives as `less`
        // before the call paren and would otherwise parse as a comparison
        // (`slt Array, number`). Stash the element type for the `Array(n)`
        // branch below and keep `left` for the loop. A user-declared
        // `Array` keeps the comparison path.
        if (tag == .less and std.mem.eql(u8, left, "Array") and self.scope_manager.lookup(left) == null and self.arrow_aliases.get(left) == null) {
            try self.advance(); // <
            const et = self.current;
            try self.expect(.identifier);
            self.array_call_elem = self.tokenText(et);
            while (try self.accept(.comma)) {
                const st = self.current;
                try self.expect(.identifier);
                _ = self.tokenText(st);
            }
            try self.expect(.greater);
            return left;
        }

        // Bit shifts: `<<` `>>` `>>>` (integer-only; floats refused loudly).
        if (tag == .less_less or tag == .greater_greater or tag == .greater_greater_greater) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);
            try self.rejectFutureOperand(left);
            try self.rejectFutureOperand(right);
            if (self.isFloatOperand(left) or self.isFloatOperand(right)) {
                return self.refuseAt(
                    "error: bit shifts are not supported on floats",
                    .{},
                    error.FloatShiftNotSupported,
                );
            }
            const temp_name = try self.newTemp();
            const sa_op: []const u8 = if (tag == .less_less) "shl" else if (tag == .greater_greater) "ashr" else "lshr";
            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Bitwise: `&` `|` `^` (integer-only; floats refused loudly).
        // SA-ASM spells them `and`/`or`/`xor` (the same mnemonics the
        // logical lowering uses; bitwise and logical coincide on 0/1).
        if (tag == .ampersand or tag == .pipe or tag == .caret) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);
            try self.rejectFutureOperand(left);
            try self.rejectFutureOperand(right);
            if (self.isFloatOperand(left) or self.isFloatOperand(right)) {
                return self.refuseAt(
                    "error: bitwise operators are not supported on floats",
                    .{},
                    error.FloatShiftNotSupported,
                );
            }
            const temp_name = try self.newTemp();
            const sa_op: []const u8 = if (tag == .ampersand) "and" else if (tag == .pipe) "or" else "xor";
            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Arithmetic: + - * / %
        // Type-directed like sa_plugin_sla's planScalarBinaryOp: if either
        // side is float (f32/f64 var or float literal), emit fadd/fsub/fmul
        // /fdiv; otherwise keep the integer forms. `%` stays integer-only.
        if (tag == .plus or tag == .minus or tag == .star or tag == .slash or tag == .percent) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);
            try self.rejectFutureOperand(left);
            try self.rejectFutureOperand(right);

            const temp_name = try self.newTemp();

            const use_float = self.isFloatOperand(left) or self.isFloatOperand(right);
            // SA-ASM has no float remainder (`frem` does not exist), so a
            // float `%` is refused loudly instead of emitting a bogus `srem`.
            if (tag == .percent and use_float) {
                return self.refuseAt(
                    "error: float remainder is not supported: '%' only lowers for integers",
                    .{},
                    error.FloatRemainderNotSupported,
                );
            }
            const sa_op = switch (tag) {
                .plus => if (use_float) "fadd" else "add",
                .minus => if (use_float) "fsub" else "sub",
                .star => if (use_float) "fmul" else "mul",
                .slash => if (use_float) "fdiv" else "div",
                // SA-ASM spells the signed comparison/remainder forms
                // `slt`/`sle`/`sgt`/`sge`/`srem`. Plain `lt`/`le`/`gt`/`ge`/
                // `mod` are not mnemonics, so the assembler rejected them.
                .percent => "srem",
                else => unreachable,
            };

            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            if (use_float and tag != .percent) {
                try self.retagTemp(temp_name, "f64");
            }
            return temp_name;
        }

        // Comparison: == != < > <= >=
        // Float sides use fcmp_* (SLA planScalarBinaryOp shape), ints keep
        // eq/ne/slt/sgt/sle/sge.
        if (tag == .equal_equal or tag == .bang_equal or tag == .less or tag == .greater or tag == .less_equal or tag == .greater_equal) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);
            try self.rejectFutureOperand(left);
            try self.rejectFutureOperand(right);

            // String-literal content folding (covers `typeof x === 'number'`):
            // SA has no runtime string `eq`, so comparing two quoted literals
            // by pointer would miscompile. Fold `==`/`!=` on quoted literals
            // by content instead; ordering comparisons on strings stay loud.
            if ((tag == .equal_equal or tag == .bang_equal) and left.len >= 2 and right.len >= 2 and (left[0] == '"' or left[0] == '\'') and (right[0] == '"' or right[0] == '\'')) {
                const lc = left[1 .. left.len - 1];
                const rc = right[1 .. right.len - 1];
                const same = std.mem.eql(u8, lc, rc);
                const truthy = if (tag == .equal_equal) same else !same;
                return if (truthy) "1" else "0";
            }

            const temp_name = try self.newTemp();

            const use_float = self.isFloatOperand(left) or self.isFloatOperand(right);
            const sa_op = if (use_float) switch (tag) {
                .equal_equal => "fcmp_eq",
                .bang_equal => "fcmp_ne",
                .less => "fcmp_lt",
                .greater => "fcmp_gt",
                .less_equal => "fcmp_le",
                .greater_equal => "fcmp_ge",
                else => unreachable,
            } else switch (tag) {
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
            try self.rejectFutureOperand(left);
            try self.rejectFutureOperand(right);

            const temp_name = try self.newTemp();

            const sa_op: []const u8 = if (tag == .amp_amp) "and" else "or";
            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Member access: obj.field
        if (tag == .dot) {
            try self.advance();
            const member_tok = self.current;
            // `from` lexes as a keyword (imports) but is a valid member
            // name (`Array.from`); accept it alongside identifiers.
            if (self.current.tag == .keyword_from) {
                try self.advance();
            } else {
                try self.expect(.identifier);
            }
            const member_name = self.tokenText(member_tok);

            if (self.current.tag == .l_paren) {
                // Method call: obj.method(args)
                // A real class method named `length` (Stack.length())
                // shadows the string/array `.length()` spelling below: route
                // such calls to the normal method dispatch instead. (An
                // if/else-if chain never falls through, so this must gate
                // the branch condition, not the branch body.)
                var length_shadowed = false;
                if (std.mem.eql(u8, member_name, "length")) {
                    if (self.scope_manager.lookup(left)) |slv| {
                        if (self.layout_table.find(slv.type_name) != null) {
                            var kit = self.class_methods.keyIterator();
                            while (kit.next()) |k| {
                                const want_dot = std.mem.indexOf(u8, k.*, ".");
                                if (want_dot) |di| {
                                    if (std.mem.eql(u8, k.*[0..di], slv.type_name) and
                                        std.mem.eql(u8, k.*[di + 1 ..], member_name))
                                    {
                                        length_shadowed = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
                if (std.mem.eql(u8, member_name, "slice") and self.isStringOperand(left)) {
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
                } else if (std.mem.eql(u8, member_name, "length") and !length_shadowed) {
                    // `s.length()`: the method-call spelling of the string
                    // length. The load is the whole implementation; the
                    // parens must still be consumed, otherwise the leftover
                    // `()` parses as a call of the temp (`call @t_N()`).
                    const temp_name = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 8 as u32\n", .{ temp_name, left });
                    try self.expect(.l_paren);
                    if (self.current.tag != .r_paren) {
                        return self.refuseAt(
                            "error: length() takes no arguments",
                            .{},
                            error.LengthTakesNoArguments,
                        );
                    }
                    try self.expect(.r_paren);
                    return temp_name;
                } else if (self.isMapVar(left)) {
                    return try self.lowerMapMethodCall(left, member_name);
                } else if (self.isSetVar(left)) {
                    return try self.lowerSetMethodCall(left, member_name);
                } else if (std.mem.eql(u8, left, "Array") and std.mem.eql(u8, member_name, "from") and self.scope_manager.lookup(left) == null) {
                    // `Array.from({length: n}, mapper?)`: static construction
                    // helper, not a slice method. A user-declared `Array`
                    // keeps the normal method path.
                    return try self.lowerArrayFrom();
                } else if (std.mem.eql(u8, left, "Number") and std.mem.eql(u8, member_name, "isInteger") and self.scope_manager.lookup(left) == null) {                    // `Number.isInteger(x)`: subset numbers are i32, so an
                    // i32 operand is trivially integral (fold to 1). A float
                    // operand needs a runtime integral check SA cannot express
                    // without float-int conversions, so refuse loudly (JEV:
                    // fold-i32 / refuse-f64). Unknown (literal/untyped) sides
                    // fold to 1 like i32: integer literals are integral.
                    try self.expect(.l_paren);
                    const inum = try self.parseExpression();
                    try self.expect(.r_paren);
                    if (self.scope_manager.lookup(inum)) |iv| {
                        if (isFloatTypeName(iv.type_name)) {
                            _ = try self.refuseAt(
                                "error: Number.isInteger on floats is not supported",
                                .{},
                                error.NumberIsIntegerFloat,
                            );
                            return error.NumberIsIntegerFloat;
                        }
                    } else if (isFloatLiteral(inum)) {
                        _ = try self.refuseAt(
                            "error: Number.isInteger on floats is not supported",
                            .{},
                            error.NumberIsIntegerFloat,
                        );
                        return error.NumberIsIntegerFloat;
                    }
                    return "1";
                } else if (std.mem.eql(u8, left, "Math") and self.scope_manager.lookup(left) == null) {
                    // `Math.floor(e)` / `Math.round(e)`: the subset's numbers
                    // are i32, and the floor/round of an integer is itself, so
                    // integer args lower as a copy. `Math.min(a, b, ...)` /
                    // `Math.max(...)` fold pairwise through a branch+slot
                    // join (integers only). Float args stay loud; other
                    // `Math.*` stay loud (they previously miscompiled to
                    // empty output silently).
                    if (std.mem.eql(u8, member_name, "min") or std.mem.eql(u8, member_name, "max")) {
                        return try self.lowerMathMinMax(member_name);
                    }
                    if (!std.mem.eql(u8, member_name, "floor") and !std.mem.eql(u8, member_name, "round") and !std.mem.eql(u8, member_name, "sqrt")) {
                        _ = try self.refuseAt(
                            "error: Math.{s} is not supported",
                            .{member_name},
                            error.MathNotSupported,
                        );
                        return error.MathNotSupported;
                    }
                    try self.expect(.l_paren);
                    const fnum = try self.parseExpression();
                    if (self.current.tag != .r_paren) {
                        _ = try self.refuseAt(
                            "error: Math.{s} takes a single argument",
                            .{member_name},
                            error.MathNotSupported,
                        );
                        return error.MathNotSupported;
                    }
                    try self.expect(.r_paren);
                    if (std.mem.eql(u8, member_name, "sqrt")) {
                        return try self.lowerMathSqrt(fnum);
                    }
                    if (self.scope_manager.lookup(fnum)) |fv| {
                        if (std.mem.eql(u8, fv.type_name, "f64")) {
                            _ = try self.refuseAt(
                                "error: Math.{s} on floats is not supported",
                                .{member_name},
                                error.MathNotSupported,
                            );
                            return error.MathNotSupported;
                        }
                    }
                    const fout = try self.newTemp();
                    try self.lowerer.emit("    {s} = add {s}, 0\n", .{ fout, fnum });
                    return fout;
                } else if (std.mem.eql(u8, member_name, "charCodeAt")) {
                    // `s.charCodeAt(i)`: byte load from the string slice.
                    try self.expect(.l_paren);
                    const idx = try self.parseExpression();
                    try self.expect(.r_paren);
                    return try self.lowerStringCharCodeAt(left, idx);
                } else if (std.mem.eql(u8, member_name, "charAt")) {
                    // `s.charAt(i)`: single-character string (not a byte).
                    try self.expect(.l_paren);
                    const idx = try self.parseExpression();
                    try self.expect(.r_paren);
                    return try self.lowerStringCharAt(left, idx);
                } else if (std.mem.eql(u8, member_name, "toString")) {
                    // `(expr).toString()`: decimal stringify for integers
                    // (mirrors `String(x)`), identity for strings. A radix
                    // argument stays loud.
                    try self.expect(.l_paren);
                    if (self.current.tag != .r_paren) {
                        return self.refuseAt(
                            "error: toString(radix) is not supported",
                            .{},
                            error.ConstructorsNotSupported,
                        );
                    }
                    try self.expect(.r_paren);
                    return try self.lowerStringConv(left);
                } else if (self.isArrayVar(left)) {
                    return try self.lowerArrayMethodCall(left, member_name);
                } else if (self.isArrowParamName(left) and self.isArrayMethodName(member_name)) {
                    // Unannotated arrow params default to `i32`, hiding array
                    // elements (`row` in `mat.map((row) => row.map(...))`).
                    // Route array-method calls on them to the slice lowering
                    // (scalar-element assumption; struct elements would
                    // miscompile, so that shape stays out of scope).
                    return try self.lowerArrayMethodCall(left, member_name);
                } else if (self.fnFieldOffset(left, member_name)) |off| {
                    // `this.compare(a, b)`: indirect call through a stored
                    // code pointer (placed before the class-method lookup so
                    // a field does not fall into UnknownMethod recovery).
                    return try self.lowerFnFieldCall(left, off);
                } else if (self.scope_manager.lookup(left)) |lv| blk: {
                    const key = try self.methodKey(lv.type_name, member_name);
                    if (!self.class_methods.contains(key)) break :blk;
                    return try self.lowerClassMethodCall(left, member_name);
                } else {
                    return error.UnknownMethod;
                }
            } else {
                // Property access
                const v = self.scope_manager.lookup(left) orelse {
                    // `Number.MAX_VALUE` / `MAX_SAFE_INTEGER`: the subset's
                    // numbers are i32, so the float huge-value folds to i32 max
                    // (Talgo uses it as "no limit"). Returned as literal text,
                    // the same form a numeric literal takes as an operand.
                    if (std.mem.eql(u8, left, "Number")) {
                        if (std.mem.eql(u8, member_name, "MAX_VALUE") or
                            std.mem.eql(u8, member_name, "MAX_SAFE_INTEGER")) return "2147483647";
                        if (std.mem.eql(u8, member_name, "MIN_SAFE_INTEGER")) return "-2147483648";
                    }
                    std.debug.print("error:{d}:{d}: property access on undefined variable '{s}'\n", .{
                        member_tok.line, member_tok.col, left,
                    });
                    return error.UndefinedVariable;
                };

                // `s.length`: the real TypeScript spelling. The builtin
                // `string` layout only knows `ptr`/`len`, so alias the length
                // field here instead of failing with UnknownField.
                if (std.mem.eql(u8, v.type_name, "string") and std.mem.eql(u8, member_name, "length")) {
                    const temp_name = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 8 as u32\n", .{ temp_name, left });
                    return temp_name;
                }

                // Array `.length`: `T[]` declares as its element base type
                // (`number[]` -> `number`), which has no registered layout.
                // Arrays lower to `{ptr, len}` slices with the length at +8,
                // the same slot for-of reads (as u64), so serve it directly
                // instead of failing with TypeIsNotAnInterface. Structs with
                // real layouts keep the field path below; a missing field
                // there stays a loud UnknownField.
                if (std.mem.eql(u8, member_name, "length") and self.layout_table.find(v.type_name) == null) {
                    const temp_name = try self.newTemp();
                    try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ temp_name, left });
                    return temp_name;
                }

                // Native `Map` size property: `m.size` (JS spelling; the
                // method form `m.size()` is handled in the call branch).
                if (self.isMapVar(left) and std.mem.eql(u8, member_name, "size")) {
                    try self.lowerer.emitImport("sa_std/btree_map.sa");
                    const temp_name = try self.newTemp();
                    try self.lowerer.emit("    {s} = call @sa_btree_map_len(&{s})\n", .{ temp_name, left });
                    return temp_name;
                }

                // Native `Set` size property: `s.size`.
                if (self.isSetVar(left) and std.mem.eql(u8, member_name, "size")) {
                    try self.lowerer.emitImport("sa_std/btree_set.sa");
                    const temp_name = try self.newTemp();
                    try self.lowerer.emit("    {s} = call @sa_btree_set_len(&{s})\n", .{ temp_name, left });
                    return temp_name;
                }

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
                // `s.length` never reaches here: it is aliased to the `len`
                // field above, since that is the real TypeScript spelling.
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

            // `m[k]` on a Map-typed base reads through the btree
            // (`if (!node.children[char])`, `node = node.children[char]`).
            if (self.isMapVar(left)) {
                const mks = try self.mapKeySlice(index);
                const mget = try self.newTemp();
                try self.lowerer.emitImport("sa_std/btree_map.sa");
                try self.lowerer.emit("    {s} = call @sa_btree_map_get(&{s}, &{s})\n", .{ mget, left, mks });
                return mget;
            }
            // `left` is a slice, so the element base is the data pointer stored
            // in the header at +0, not the header itself.
            // Element-aware stride: slices of structs/pointers step 8 bytes
            // (`MapEntry[][]` -> `MapEntry[]` -> `MapEntry`), scalars step 4.
            // The old hardcoded `mul 4` / `load as i32` read object slices
            // shifted and tagged every element `i32`, so `entry.key`
            // failed and aborted the whole method (next method then parsed
            // as an expression: `unexpected token colon`).
            var elem_type: []const u8 = "i32";
            if (self.scope_manager.lookup(left)) |lv| {
                // `any` receivers index as slice headers (ptr-sized
                // elements): `matC[i]` on an `any` matrix must step 8 bytes,
                // not the scalar fallback's 4 (wild pointers otherwise).
                // Scalar `any` values must not be indexed at all.
                if (std.mem.eql(u8, lv.type_name, "any")) {
                    elem_type = "ptr";
                } else {
                    elem_type = elementTypeOf(lv.type_name);
                }
            }
            var e_size: u32 = 4;
            var e_align: u32 = 4;
            try getTypeSizeAndAlign(elem_type, &e_size, &e_align);
            const sa_elem = saTypeOf(elem_type);
            const base_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ base_temp, left });

            const off_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = mul {s}, {d}\n", .{ off_temp, index, e_size });

            const addr_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, base_temp, off_temp });

            const val_temp = try self.newTemp();
            try self.lowerer.emit("    {s} = load {s} + 0 as {s}\n", .{ val_temp, addr_temp, sa_elem });
            if (self.scope_manager.lookup(val_temp)) |tv| {
                self.allocator.free(tv.type_name);
                tv.type_name = try self.allocator.dupe(u8, elem_type);
            }
            return val_temp;
        }

        // Postfix increment/decrement: i++ / i--
        // Lowers to `t = add i, 1` + `i = t`. The value delivered to the
        // enclosing expression is a copy: the post-increment value must stay
        // usable (`a[i++]`), while the moved-into-target temp is consumed.
        // Returning the moved temp itself trips UseAfterMove at the use.
        if (tag == .plus_plus or tag == .minus_minus) {
            try self.advance();
            // Snapshot the old value first: postfix delivers the
            // pre-increment value to the enclosing expression (`a[i++]`
            // indexes the old slot). Reads route through move-forwarding
            // (the operand may have died in an earlier move).
            const out = try self.newTemp();
            try self.lowerer.emit("    {s} = add {s}, 0\n", .{ out, left });
            const temp_name = try self.newTemp();
            const sa_op: []const u8 = if (tag == .plus_plus) "add" else "sub";
            try self.lowerer.emit("    {s} = {s} {s}, 1\n", .{ temp_name, sa_op, left });
            // Rebinding a live register is RegisterRedefinition, so the old
            // value must die first. Owned values go through the usual walk;
            // plain scalars (`!i32` is legal, params do it on exit) die here.
            // The snapshot above already preserves the pre-increment value.
            try self.releaseOwnedIfLive(left);
            if (self.scope_manager.lookup(left)) |llv| {
                if (!llv.is_heap_allocated and !llv.is_consumed and !llv.is_released) {
                    try self.lowerer.emit("    !{s}\n", .{left});
                    llv.is_released = true;
                }
            }
            try self.lowerer.emit("    {s} = {s}\n", .{ left, temp_name });
            self.scope_manager.markConsumed(temp_name);
            self.markRebound(left);
            // Inside a capture buffer (for-increment clauses, whose value is
            // discarded) the copy's definition lands after the loop body
            // while its scope record claims an earlier block, breaking the
            // exit walk on untaken paths: keep the old consumed shape there.
            if (self.lowerer.capture != null) {
                self.scope_manager.markConsumed(out);
            }
            return out;
        }

        // `x as T`: a type assertion is a no-op at runtime (every value is
        // already its lowered form). Consume the annotation and keep `left`,
        // so `this.stack.pop() as T` and `v as number` lower as `v`.
        if (tag == .keyword_as) {
            try self.advance();
            _ = try self.parseTypeName();
            return left;
        }

        // Function call: name(args)
        if (tag == .l_paren) {
            try self.advance();
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                const arg = try self.parseExpression();
                try args.append(try self.argReg(arg));
                _ = try self.accept(.comma);
            }
            try self.expect(.r_paren);

            const temp_name = try self.newTemp();

            // A call to an async function yields a ready-future handle, not
            // a plain value: retag the temp so `await` unwraps it and plain
            // uses refuse it loudly.
            if (self.async_fns.get(left)) |inner| {
                const future_t = try futureTypeName(self.allocator, inner);
                defer self.allocator.free(future_t);
                if (self.scope_manager.lookup(temp_name)) |tv| {
                    self.allocator.free(tv.type_name);
                    tv.type_name = try self.allocator.dupe(u8, future_t);
                }
            }

            // A future handle must be awaited before it is passed on: the
            // callee would otherwise receive a pointer where it expects a
            // plain value, with no diagnostic at the SA level.
            for (args.items) |arg| {
                try self.rejectFutureOperand(arg);
            }

            // Check if this is a stdlib function
            if (self.lookupStdlib(left)) |entry| {
                try self.emitStdlibCall(temp_name, entry, args);
            } else if (self.wit_syms.get(left) != null) {
                try self.rejectWitCall(left);
            } else if (self.wasm_syms.get(left) != null and self.declared_externs.get(left) == null) {
                // Arity-matched header first, then the plain call path below.
                try self.lowerer.emitExtern(left, args.items.len);
                try self.lowerer.emit("    {s} = call @{s}(", .{ temp_name, left });
                var first = true;
                for (args.items) |arg| {
                    if (self.arrow_aliases.get(arg)) |aarg| {
                        if (!first) try self.lowerer.emit(", ", .{});
                        try self.lowerer.emit("{s}, {s}", .{ aarg.cb, aarg.ctx });
                        first = false;
                    } else {
                        if (!first) try self.lowerer.emit(", ", .{});
                        try self.lowerer.emit("{s}", .{arg});
                        first = false;
                    }
                }
                if (self.last_arrow_ctx) |ctx_arg| {
                    if (!first) try self.lowerer.emit(", ", .{});
                    try self.lowerer.emit("{s}", .{ctx_arg});
                    self.last_arrow_ctx = null;
                }
                try self.lowerer.emit(")\n", .{});
            } else if (std.mem.eql(u8, left, "alloc") and args.items.len == 1) {
                // Heap allocation is a primitive instruction, not a function:
                // `alloc(N)` must emit `t = alloc N`, because there is no
                // `@alloc` symbol to call and the assembler rejects it with
                // "callee is not declared".
                try self.lowerer.emit("    {s} = alloc {s}\n", .{ temp_name, args.items[0] });
            } else if ((std.mem.eql(u8, left, "String") or std.mem.eql(u8, left, "Number")) and args.items.len == 1) {
                // `String(x)` / `Number(x)` conversions: identity for
                // already-strings, decimal stringify for integers,
                // pass-through for generics (assumed string at runtime).
                // `Number(s)` on a string is future work; integers pass
                // through since the subset's numbers already are integers.
                if (std.mem.eql(u8, left, "String")) {
                    const s = try self.lowerStringConv(args.items[0]);
                    if (std.mem.eql(u8, s, args.items[0])) {
                        // Identity: reuse the operand directly; the spare
                        // temp was never defined, so just mark it consumed
                        // instead of emitting a move that would consume a
                        // live variable (e.g. a `key: K` parameter).
                        self.scope_manager.markConsumed(temp_name);
                        return s;
                    }
                    try self.lowerer.emit("    {s} = {s}\n", .{ temp_name, s });
                    self.scope_manager.markConsumed(s);
                } else {
                    // `Number(x)`: the subset's numbers already are integers.
                    try self.lowerer.emit("    {s} = add {s}, 0\n", .{ temp_name, args.items[0] });
                }
            } else if (std.mem.eql(u8, left, "parseInt") and self.scope_manager.lookup(left) == null and self.arrow_aliases.get(left) == null) {
                // `parseInt(s[, radix])`: decimal string parse. A numeric
                // argument is the identity (already an integer). Only radix
                // 10 (or omitted) lowers; anything else stays loud. Parsing
                // stops at the first non-digit (JS semantics); a leading
                // `-` negates.
                if (args.items.len == 0 or args.items.len > 2) {
                    return self.refuseAt(
                        "error: parseInt takes one or two arguments",
                        .{},
                        error.ConstructorsNotSupported,
                    );
                }
                if (args.items.len == 2 and !std.mem.eql(u8, args.items[1], "10")) {
                    return self.refuseAt(
                        "error: parseInt only supports radix 10",
                        .{},
                        error.ConstructorsNotSupported,
                    );
                }
                const sarg = args.items[0];
                if (self.scope_manager.lookup(sarg)) |sv| {
                    if (!std.mem.eql(u8, sv.type_name, "string")) {
                        // Numeric already: identity copy (stays usable after).
                        try self.lowerer.emit("    {s} = add {s}, 0\n", .{ temp_name, sarg });
                        return temp_name;
                    }
                } else {
                    var is_num = sarg.len > 0 and (sarg[0] >= '0' and sarg[0] <= '9');
                    if (sarg.len > 0 and (sarg[0] == '-' or sarg[0] == '+')) is_num = sarg.len > 1;
                    if (is_num) {
                        try self.lowerer.emit("    {s} = {s}\n", .{ temp_name, sarg });
                        return temp_name;
                    }
                    return self.refuseAt(
                        "error: parseInt argument must be a string or number",
                        .{},
                        error.ConstructorsNotSupported,
                    );
                }
                return try self.lowerParseInt(temp_name, sarg);
            } else if (std.mem.eql(u8, left, "Array") and self.scope_manager.lookup(left) == null and self.arrow_aliases.get(left) == null) {
                // `Array(n)` call form (no `new`): identical to construction.
                // A user-declared `Array` keeps the normal call path. The
                // `Array<T>` prefix stashes the element type above.
                const arr_elem = self.array_call_elem orelse "i32";
                self.array_call_elem = null;
                if (args.items.len == 0) {
                    try self.emitArrayAllocLit(temp_name, arr_elem, 0);
                } else if (args.items.len == 1) {
                    const a0 = args.items[0];
                    const lit = std.fmt.parseInt(i64, a0, 10) catch null;
                    if (lit) |lv| {
                        if (lv < 0) {
                            return self.refuseAt(
                                "error: new 'Array' length must be non-negative",
                                .{},
                                error.ConstructorsNotSupported,
                            );
                        }
                        try self.emitArrayAllocLit(temp_name, arr_elem, @as(u32, @intCast(lv)));
                    } else {
                        try self.emitArrayAllocReg(temp_name, arr_elem, a0, true);
                    }
                } else {
                    return self.refuseAt(
                        "error: new 'Array' takes a single length argument",
                        .{},
                        error.ConstructorsNotSupported,
                    );
                }
                return temp_name;
            } else if (self.arrow_aliases.get(left)) |alias| {
                // Value call through an arrow alias: `let r = f(41)` lowers
                // straight to the callback with the alias context last
                // (borrowed; see the statement-level alias path for why `^`
                // is wrong here).
                if (alias.plain) {
                    // Plain named function from a top-level arrow: direct
                    // call with just the args, no context register.
                    for (args.items) |arg| {
                        if (self.arrow_aliases.get(arg)) |aarg| {
                            if (aarg.plain) {
                                std.debug.print("error:{d}:{d}: plain function '{s}' cannot be passed as a callback value (it takes no context)\n", .{
                                    self.current.line,
                                    self.current.col,
                                    arg,
                                });
                                return error.PlainFunctionAsValue;
                            }
                        }
                    }
                    try self.lowerer.emit("    {s} = call @{s}(", .{ temp_name, alias.cb[1..] });
                    var first = true;
                    for (args.items) |arg| {
                        if (self.arrow_aliases.get(arg)) |aarg| {
                            if (!first) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}, {s}", .{ aarg.cb, aarg.ctx });
                            first = false;
                        } else {
                            if (!first) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}", .{arg});
                            first = false;
                        }
                    }
                    if (self.last_arrow_ctx) |ctx_arg| {
                        if (!first) try self.lowerer.emit(", ", .{});
                        try self.lowerer.emit("{s}", .{ctx_arg});
                        self.last_arrow_ctx = null;
                    }
                    try self.lowerer.emit(")\n", .{});
                    if (self.fn_ret.get(left)) |rt| {
                        try self.retagTemp(temp_name, rt);
                    }
                    return temp_name;
                }
                var expanded = std.ArrayList([]const u8).init(self.allocator);
                defer expanded.deinit();
                for (args.items) |arg| {
                    if (self.arrow_aliases.get(arg)) |aarg| {
                        try expanded.append(aarg.cb);
                        try expanded.append(aarg.ctx);
                    } else {
                        try expanded.append(arg);
                    }
                }
                if (alias.arity > 0) {
                    if (args.items.len < alias.required) {
                        _ = try self.refuseAt(
                            "error: too few arguments in call",
                            .{},
                            error.TooFewArguments,
                        );
                        return error.TooFewArguments;
                    }
                    var need_pad: u8 = alias.arity - @as(u8, @intCast(@min(args.items.len, alias.arity)));
                    while (need_pad > 0) : (need_pad -= 1) {
                        try expanded.append("0");
                    }
                }
                const borrow_ctx_v = if (alias.ctx.len > 0 and alias.ctx[0] == '^') alias.ctx[1..] else alias.ctx;
                try self.lowerer.emit("    {s} = call @{s}(", .{ temp_name, alias.cb[1..] });
                for (expanded.items, 0..) |arg, idx| {
                    if (idx > 0) try self.lowerer.emit(", ", .{});
                    try self.lowerer.emit("{s}", .{arg});
                }
                if (expanded.items.len > 0) try self.lowerer.emit(", ", .{});
                try self.lowerer.emit("{s}", .{borrow_ctx_v});
                if (self.last_arrow_ctx) |ctx_arg| {
                    try self.lowerer.emit(", {s}", .{ctx_arg});
                    self.last_arrow_ctx = null;
                }
                try self.lowerer.emit(")\n", .{});
                // Same self-call rule as the statement path above: the
                // callback's own `ctx` outlives the call.
                if (!alias.self_call) try self.lowerer.emit("    !{s}\n", .{borrow_ctx_v});
            } else {
                try self.lowerer.emit("    {s} = call @{s}(", .{ temp_name, left });
                // Same convention as the statement-level call path: `^ctx`
                // follows the callback (first arg), not the tail.
                if (self.last_arrow_ctx) |ctx_arg| {
                    if (args.items.len == 0) {
                        try self.lowerer.emit("{s}", .{ctx_arg});
                    } else {
                        for (args.items, 0..) |arg, idx| {
                            if (idx > 0) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}", .{arg});
                            if (idx == 0) {
                                try self.lowerer.emit(", {s}", .{ctx_arg});
                            }
                        }
                    }
                    self.last_arrow_ctx = null;
                } else {
                    var first = true;
                    for (args.items) |arg| {
                        if (self.arrow_aliases.get(arg)) |aarg| {
                            if (!first) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}, {s}", .{ aarg.cb, aarg.ctx });
                            first = false;
                        } else {
                            if (!first) try self.lowerer.emit(", ", .{});
                            try self.lowerer.emit("{s}", .{arg});
                            first = false;
                        }
                    }
                }
                try self.lowerer.emit(")\n", .{});
            }
            // Retag the result from the callee's declared return type so
            // downstream indexing sees the real layout (`const c = f()` on
            // an array-returning function must not default to `i32`).
            if (self.fn_ret.get(left)) |rt| {
                try self.retagTemp(temp_name, rt);
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
    bit_or = 3,
    bit_xor = 4,
    bit_and = 5,
    comparison = 6,    // == != < > <= >=
    sum = 7,           // + -
    product = 8,       // * / %
    prefix = 9,        // - !
    call = 10,         // . [] ()
};

fn getPrecedence(tag: lexer_mod.Token.Tag) Precedence {
    return switch (tag) {
        .pipe_pipe => .@"or",
        .amp_amp => .@"and",
        .pipe => .bit_or,
        .caret => .bit_xor,
        .ampersand => .bit_and,
        .equal_equal, .bang_equal, .less, .greater, .less_equal, .greater_equal => .comparison,
        .plus, .minus => .sum,
        .star, .slash, .percent => .product,
        .less_less, .greater_greater, .greater_greater_greater => .sum,
        .plus_plus, .minus_minus => .call,
        // `x as T` binds like a postfix operator (member-call level).
        .keyword_as => .call,
        .dot, .l_paren, .l_bracket => .call,
        else => .lowest,
    };
}
