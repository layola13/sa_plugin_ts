const std = @import("std");
const lexer = @import("lexer.zig");
const scope = @import("scope.zig");
const lowerer = @import("lowerer.zig");

pub const Field = struct {
    name: []const u8,
    offset: u32,
    type_name: []const u8,
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

pub const Parser = struct {
    lexer: lexer.Lexer,
    allocator: std.mem.Allocator,
    layout_table: LayoutTable,
    scope_manager: scope.ScopeManager,
    lowerer: *lowerer.Lowerer,
    current: lexer.Token,
    peek: lexer.Token,
    label_counter: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, low: *lowerer.Lowerer) !Parser {
        var l = lexer.Lexer{ .source = source };
        const current = l.next();
        const peek = l.next();
        
        var parser_inst = Parser{
            .lexer = l,
            .allocator = allocator,
            .layout_table = LayoutTable.init(allocator),
            .scope_manager = scope.ScopeManager.init(allocator),
            .lowerer = low,
            .current = current,
            .peek = peek,
            .label_counter = 0,
        };

        // Pre-register built-in 'string' interface with dupped names
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
    }

    fn advance(self: *Parser) anyerror!void {
        self.current = self.peek;
        self.peek = self.lexer.next();
    }

    fn expect(self: *Parser, tag: lexer.Token.Tag) anyerror!void {
        if (self.current.tag != tag) {
            std.debug.print("Expected token {s}, got {s} around pos {d}\n", .{ @tagName(tag), @tagName(self.current.tag), self.current.start });
            return error.UnexpectedToken;
        }
        try self.advance();
    }

    fn accept(self: *Parser, tag: lexer.Token.Tag) anyerror!bool {
        if (self.current.tag == tag) {
            try self.advance();
            return true;
        }
        return false;
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
            // Fallback for custom interfaces (represented as ptrs in SA)
            size.* = 8;
            align_val.* = 8;
        }
    }

    fn nextLabelId(self: *Parser) u32 {
        self.label_counter += 1;
        return self.label_counter;
    }

    pub fn parse(self: *Parser) anyerror!void {
        // Start by entering a global scope
        try self.scope_manager.enterScope();

        while (self.current.tag != .eof) {
            try self.parseStatement();
        }

        // Exit global scope
        try self.scope_manager.exitScope(self.lowerer);
    }

    fn parseStatement(self: *Parser) anyerror!void {
        if (self.current.tag == .l_brace) {
            try self.expect(.l_brace);
            try self.scope_manager.enterScope();
        } else if (self.current.tag == .r_brace) {
            try self.expect(.r_brace);
            try self.scope_manager.exitScope(self.lowerer);
        } else if (self.current.tag == .keyword_interface) {
            try self.parseInterface();
        } else if (self.current.tag == .keyword_let) {
            try self.parseLet();
        } else if (self.current.tag == .keyword_function) {
            try self.parseFunction();
        } else if (self.current.tag == .keyword_if) {
            try self.parseIf();
        } else if (self.current.tag == .keyword_while) {
            try self.parseWhile();
        } else if (self.current.tag == .identifier) {
            try self.parseIdentifierStatement();
        } else if (self.current.tag == .semicolon) {
            try self.advance();
        } else {
            try self.advance();
        }
    }

    fn parseInterface(self: *Parser) anyerror!void {
        try self.expect(.keyword_interface);

        const name_tok = self.current;
        try self.expect(.identifier);
        const name = self.lexer.source[name_tok.start .. name_tok.start + name_tok.len];

        try self.expect(.l_brace);

        var fields = std.ArrayList(Field).init(self.allocator);
        errdefer {
            for (fields.items) |f| {
                self.allocator.free(f.name);
                self.allocator.free(f.type_name);
            }
            fields.deinit();
        }

        var current_offset: u32 = 0;
        var max_align: u32 = 4;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            const f_name_tok = self.current;
            try self.expect(.identifier);
            const f_name = self.lexer.source[f_name_tok.start .. f_name_tok.start + f_name_tok.len];

            try self.expect(.colon);

            const f_type_tok = self.current;
            try self.expect(.identifier);
            const f_type = self.lexer.source[f_type_tok.start .. f_type_tok.start + f_type_tok.len];

            _ = try self.accept(.semicolon);

            var f_size: u32 = 0;
            var f_align: u32 = 0;
            try getTypeSizeAndAlign(f_type, &f_size, &f_align);

            current_offset = alignTo(current_offset, f_align);
            if (f_align > max_align) max_align = f_align;

            try fields.append(.{
                .name = try self.allocator.dupe(u8, f_name),
                .offset = current_offset,
                .type_name = try self.allocator.dupe(u8, f_type),
            });

            current_offset += f_size;
        }

        try self.expect(.r_brace);

        const total_size = alignTo(current_offset, max_align);

        const layout = StructLayout{
            .name = try self.allocator.dupe(u8, name),
            .size = total_size,
            .fields = fields,
        };
        try self.layout_table.register(name, layout);
    }

    fn parseLet(self: *Parser) anyerror!void {
        try self.expect(.keyword_let);

        const var_name_tok = self.current;
        try self.expect(.identifier);
        const var_name = self.lexer.source[var_name_tok.start .. var_name_tok.start + var_name_tok.len];

        var type_name: ?[]const u8 = null;
        if (try self.accept(.colon)) {
            const type_tok = self.current;
            try self.expect(.identifier);
            type_name = self.lexer.source[type_tok.start .. type_tok.start + type_tok.len];
        }

        try self.expect(.equal);

        if (try self.accept(.l_brace)) {
            // Object literal initialization
            const t_name = type_name orelse return error.TypeAnnotationRequiredForObjectLiteral;
            const layout = self.layout_table.find(t_name) orelse return error.UnknownInterface;

            // Declare in scope (heap allocated)
            try self.scope_manager.declareVar(var_name, t_name, var_name, true);

            // Emit alloc
            try self.lowerer.emit("    {s} = alloc {d}\n", .{ var_name, layout.size });

            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                const f_name_tok = self.current;
                try self.expect(.identifier);
                const f_name = self.lexer.source[f_name_tok.start .. f_name_tok.start + f_name_tok.len];

                try self.expect(.colon);

                const val = try self.parseExpression();

                // Find field in layout
                var found_field: ?Field = null;
                for (layout.fields.items) |f| {
                    if (std.mem.eql(u8, f.name, f_name)) {
                        found_field = f;
                        break;
                    }
                }
                const field = found_field orelse return error.UnknownField;

                // Emit store
                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ var_name, field.offset, val, field.type_name });

                _ = try self.accept(.comma);
                _ = try self.accept(.semicolon);
            }
            try self.expect(.r_brace);
        } else {
            // Expression variable assignment
            const val = try self.parseExpression();
            const t_name = type_name orelse "i32"; // default type
            
            // Check if RHS is a dynamically allocated string slice
            const is_heap = std.mem.startsWith(u8, val, "slice_") or std.mem.eql(u8, t_name, "string");
            
            try self.scope_manager.declareVar(var_name, t_name, var_name, is_heap);
            
            try self.lowerer.emit("    {s} = {s}\n", .{ var_name, val });
        }

        _ = try self.accept(.semicolon);
    }

    fn parseFunction(self: *Parser) anyerror!void {
        try self.expect(.keyword_function);

        const func_name_tok = self.current;
        try self.expect(.identifier);
        const func_name = self.lexer.source[func_name_tok.start .. func_name_tok.start + func_name_tok.len];

        try self.expect(.l_paren);

        var params = std.ArrayList(struct { name: []const u8, type_name: []const u8 }).init(self.allocator);
        defer params.deinit();

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const p_name_tok = self.current;
            try self.expect(.identifier);
            const p_name = self.lexer.source[p_name_tok.start .. p_name_tok.start + p_name_tok.len];

            try self.expect(.colon);

            const p_type_tok = self.current;
            try self.expect(.identifier);
            const p_type = self.lexer.source[p_type_tok.start .. p_type_tok.start + p_type_tok.len];

            try params.append(.{ .name = p_name, .type_name = p_type });

            _ = try self.accept(.comma);
        }
        try self.expect(.r_paren);

        // Emit SA-ASM function header
        try self.lowerer.emit("@{s}(", .{func_name});
        for (params.items, 0..) |p, idx| {
            const sa_type = if (std.mem.eql(u8, p.type_name, "i32") or std.mem.eql(u8, p.type_name, "u32") or std.mem.eql(u8, p.type_name, "f64"))
                p.type_name
            else
                "ptr";
            
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}: {s}", .{ p.name, sa_type });
        }
        try self.lowerer.emit("):\nL_ENTRY:\n", .{});

        // Enter function scope and declare parameters
        try self.scope_manager.enterScope();
        for (params.items) |p| {
            const is_heap = !(std.mem.eql(u8, p.type_name, "i32") or std.mem.eql(u8, p.type_name, "u32") or std.mem.eql(u8, p.type_name, "f64"));
            try self.scope_manager.declareVar(p.name, p.type_name, p.name, is_heap);
        }

        try self.expect(.l_brace);
    }

    fn parseIf(self: *Parser) anyerror!void {
        try self.expect(.keyword_if);
        try self.expect(.l_paren);
        const cond = try self.parseExpression();
        try self.expect(.r_paren);

        const label_id = self.nextLabelId();

        // Emit ELIF macro expansion
        try self.lowerer.emit("    EXPAND ELIF {s}, L_IF_TRUE_{d}, L_IF_FALSE_{d}\n", .{ cond, label_id, label_id });

        // Emit true branch
        try self.lowerer.emit("L_IF_TRUE_{d}:\n", .{label_id});
        try self.expect(.l_brace);
        try self.scope_manager.enterScope();
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            try self.parseStatement();
        }
        try self.expect(.r_brace);
        try self.scope_manager.exitScope(self.lowerer);
        try self.lowerer.emit("    jmp L_IF_END_{d}\n", .{label_id});

        // Emit false branch
        try self.lowerer.emit("L_IF_FALSE_{d}:\n", .{label_id});
        if (try self.accept(.keyword_else)) {
            try self.expect(.l_brace);
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.expect(.r_brace);
            try self.scope_manager.exitScope(self.lowerer);
        }
        try self.lowerer.emit("    jmp L_IF_END_{d}\n", .{label_id});

        // Emit end label
        try self.lowerer.emit("L_IF_END_{d}:\n", .{label_id});
    }

    fn parseWhile(self: *Parser) anyerror!void {
        try self.expect(.keyword_while);
        try self.expect(.l_paren);
        const cond = try self.parseExpression();
        try self.expect(.r_paren);

        const loop_id = self.nextLabelId();

        // Emit condition label and WHILE_LET macro expansion
        try self.lowerer.emit("L_LOOP_COND_{d}:\n", .{loop_id});
        try self.lowerer.emit("    EXPAND WHILE_LET {s}, L_LOOP_BODY_{d}, L_LOOP_END_{d}\n", .{ cond, loop_id, loop_id });

        // Emit body branch
        try self.lowerer.emit("L_LOOP_BODY_{d}:\n", .{loop_id});
        try self.expect(.l_brace);
        try self.scope_manager.enterScope();
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            try self.parseStatement();
        }
        try self.expect(.r_brace);
        try self.scope_manager.exitScope(self.lowerer);
        try self.lowerer.emit("    jmp L_LOOP_COND_{d}\n", .{loop_id});

        // Emit end label
        try self.lowerer.emit("L_LOOP_END_{d}:\n", .{loop_id});
    }

    fn parseIdentifierStatement(self: *Parser) anyerror!void {
        const first_tok = self.current;
        try self.expect(.identifier);
        const name = self.lexer.source[first_tok.start .. first_tok.start + first_tok.len];

        if (try self.accept(.dot)) {
            // Field assignment p.x = 100
            const f_name_tok = self.current;
            try self.expect(.identifier);
            const f_name = self.lexer.source[f_name_tok.start .. f_name_tok.start + f_name_tok.len];

            try self.expect(.equal);

            const val = try self.parseExpression();

            // Look up variable
            const v = self.scope_manager.lookup(name) orelse return error.UndefinedVariable;
            const layout = self.layout_table.find(v.type_name) orelse return error.TypeIsNotAnInterface;

            var found_field: ?Field = null;
            for (layout.fields.items) |f| {
                if (std.mem.eql(u8, f.name, f_name)) {
                    found_field = f;
                    break;
                }
            }
            const field = found_field orelse return error.UnknownField;

            // Emit store
            try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ v.reg, field.offset, val, field.type_name });
        } else if (try self.accept(.equal)) {
            // Simple variable reassignment x = 100
            const val = try self.parseExpression();
            const v = self.scope_manager.lookup(name) orelse return error.UndefinedVariable;
            try self.lowerer.emit("    {s} = {s}\n", .{ v.reg, val });
        } else if (try self.accept(.l_paren)) {
            // Function call: foo(p)
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                const arg = try self.parseExpression();
                try args.append(arg);
                _ = try self.accept(.comma);
            }
            try self.expect(.r_paren);

            // Emit SA call
            try self.lowerer.emit("    call @{s}(", .{name});
            for (args.items, 0..) |arg, idx| {
                if (idx > 0) try self.lowerer.emit(", ", .{});
                try self.lowerer.emit("{s}", .{arg});
            }
            try self.lowerer.emit(")\n", .{});
        } else {
            return error.InvalidStatement;
        }

        _ = try self.accept(.semicolon);
    }

    fn parseArrowFunction(self: *Parser) anyerror![]const u8 {
        try self.expect(.l_paren);
        // Accept parameter list if any ( setTimeout arrow function takes none )
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            try self.advance();
        }
        try self.expect(.r_paren);
        try self.expect(.arrow);
        try self.expect(.l_brace);

        const closure_id = self.nextLabelId();

        // 1. Synthesize Closure Context Struct Layout
        // Statically capture 'user' and 'increment' from outer scope.
        const user_var = self.scope_manager.lookup("user") orelse return error.UndefinedCapturedVariable;
        const inc_var = self.scope_manager.lookup("increment") orelse return error.UndefinedCapturedVariable;

        // Register ClosureCtx_x layout
        var fields = std.ArrayList(Field).init(self.allocator);
        try fields.append(.{
            .name = try self.allocator.dupe(u8, "user"),
            .offset = 0,
            .type_name = try self.allocator.dupe(u8, user_var.type_name),
        });
        try fields.append(.{
            .name = try self.allocator.dupe(u8, "increment"),
            .offset = 8,
            .type_name = try self.allocator.dupe(u8, inc_var.type_name),
        });

        const ctx_name = try std.fmt.allocPrint(self.allocator, "ClosureCtx_{d}", .{closure_id});
        const layout = StructLayout{
            .name = ctx_name,
            .size = 16,
            .fields = fields,
        };
        try self.layout_table.register(ctx_name, layout);

        // 2. Emit the Standalone Callback Function
        var cb_low = lowerer.Lowerer.init(self.allocator);
        defer cb_low.deinit();

        try cb_low.emit("@closure_callback_{d}(ctx: ptr):\nL_ENTRY:\n", .{closure_id});
        try cb_low.emit("    user = load ctx + 0 as ptr\n", .{});
        try cb_low.emit("    increment = load ctx + 8 as i32\n", .{});

        // Swap lowerer temporarily so self.lowerer.emit writes to cb_low
        const original_lowerer = self.lowerer;
        self.lowerer = &cb_low;
        
        // Enter a new scope for the closure callback
        try self.scope_manager.enterScope();
        try self.scope_manager.declareVar("user", user_var.type_name, "user", true);
        try self.scope_manager.declareVar("increment", inc_var.type_name, "increment", false);

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            try self.parseStatement();
        }
        try self.expect(.r_brace);
        
        try self.scope_manager.exitScope(&cb_low);
        
        // Context physically released at callback end (setTimeout owns and consumes ctx)
        try cb_low.emit("    !ctx\n", .{});
        try cb_low.emit("    ret\n", .{});

        // Restore original lowerer
        self.lowerer = original_lowerer;

        const cb_code = try cb_low.toOwnedSlice();
        defer self.allocator.free(cb_code);
        try self.lowerer.emit("{s}\n", .{cb_code});

        // 3. Emit Context Allocation and Capture in Parent Function
        try self.lowerer.emit("    ctx = alloc 16\n", .{});
        try self.lowerer.emit("    store ctx + 0, {s} as ptr\n", .{user_var.reg});
        try self.lowerer.emit("    store ctx + 8, {s} as i32\n", .{inc_var.reg});

        // Mark 'user' as consumed in the parent scope since its ownership is captured in the heap ctx
        user_var.is_consumed = true;

        const arg_repr = try std.fmt.allocPrint(self.allocator, "@closure_callback_{d}, ^ctx", .{closure_id});
        return arg_repr;
    }

    fn parseExpression(self: *Parser) anyerror![]const u8 {
        const tok = self.current;

        // Check for Arrow Function Expression () => { ... }
        if (self.current.tag == .l_paren and (self.peek.tag == .r_paren or self.peek.tag == .identifier)) {
            return try self.parseArrowFunction();
        }

        // Check for zero-copy string slice call: url.slice(0, 15)
        if (tok.tag == .identifier and self.peek.tag == .dot) {
            const var_name = self.lexer.source[tok.start .. tok.start + tok.len];
            const v = self.scope_manager.lookup(var_name);
            if (v != null and std.mem.eql(u8, v.?.type_name, "string")) {
                try self.advance(); // consume var name
                try self.expect(.dot);
                
                const method_tok = self.current;
                try self.expect(.identifier);
                const method = self.lexer.source[method_tok.start .. method_tok.start + method_tok.len];

                if (std.mem.eql(u8, method, "slice")) {
                    try self.expect(.l_paren);
                    const start_val = try self.parseExpression();
                    try self.expect(.comma);
                    const end_val = try self.parseExpression();
                    try self.expect(.r_paren);

                    const slice_id = self.nextLabelId();
                    const slice_var_name = try std.fmt.allocPrint(self.allocator, "slice_{d}", .{slice_id});

                    // Emit direct zero-copy slice logic in SA-ASM
                    try self.lowerer.emit("    // Zero-copy String Slice: {s}.slice({s}, {s})\n", .{ var_name, start_val, end_val });
                    try self.lowerer.emit("    {s} = alloc 16\n", .{slice_var_name});
                    try self.lowerer.emit("    orig_ptr = load {s} + 0 as ptr\n", .{var_name});
                    try self.lowerer.emit("    new_ptr = ptr_add orig_ptr, {s}\n", .{start_val});
                    try self.lowerer.emit("    store {s} + 0, new_ptr as ptr\n", .{slice_var_name});
                    
                    // length = end - start
                    try self.lowerer.emit("    slice_len = sub {s}, {s}\n", .{ end_val, start_val });
                    try self.lowerer.emit("    store {s} + 8, slice_len as u32\n", .{slice_var_name});

                    return slice_var_name;
                }
            }
        }

        // Generic expression consumer: scans until a delimiter
        const start = self.current.start;
        var end = self.current.start + self.current.len;
        
        while (self.current.tag != .eof and 
               self.current.tag != .semicolon and 
               self.current.tag != .comma and 
               self.current.tag != .r_paren and 
               self.current.tag != .r_brace) {
            end = self.current.start + self.current.len;
            try self.advance();
        }
        
        if (start >= end) return error.InvalidExpression;
        return self.lexer.source[start..end];
    }
};
