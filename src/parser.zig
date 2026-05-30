const std = @import("std");
const lexer_mod = @import("lexer.zig");
const scope_mod = @import("scope.zig");
const lowerer_mod = @import("lowerer.zig");

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
                try self.scope_manager.exitScope(self.lowerer);
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
                try self.lowerer.emit("    break\n", .{});
            },
            .keyword_continue => {
                try self.advance();
                _ = try self.accept(.semicolon);
                try self.lowerer.emit("    continue\n", .{});
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

            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                const f_name_tok = self.current;
                try self.expect(.identifier);
                const f_name = self.tokenText(f_name_tok);

                try self.expect(.colon);

                const val = try self.parseExpression();

                var found_field: ?Field = null;
                for (layout.fields.items) |f| {
                    if (std.mem.eql(u8, f.name, f_name)) {
                        found_field = f;
                        break;
                    }
                }
                const field = found_field orelse return error.UnknownField;

                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ var_name, field.offset, val, field.type_name });

                _ = try self.accept(.comma);
                _ = try self.accept(.semicolon);
            }
            try self.expect(.r_brace);
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

            const arr_size = @as(u32, @intCast(values.items.len)) * elem_size;
            try self.scope_manager.declareVar(var_name, elem_type, var_name, true);

            try self.lowerer.emit("    {s} = alloc {d}\n", .{ var_name, arr_size });

            for (values.items, 0..) |val, idx| {
                const off = @as(u32, @intCast(idx)) * elem_size;
                try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ var_name, off, val, elem_type });
            }
        } else {
            const val = try self.parseExpression();
            const t_name = type_name orelse "i32";

            const is_heap = std.mem.startsWith(u8, val, "slice_") or std.mem.eql(u8, t_name, "string");

            try self.scope_manager.declareVar(var_name, t_name, var_name, is_heap);

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

        // Optional return type
        _ = try self.accept(.colon);

        try self.lowerer.emit("@{s}(", .{func_name});
        for (params.items, 0..) |p, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}: {s}", .{ p.name, p.type_name });
        }
        try self.lowerer.emit("):\n", .{});

        try self.scope_manager.enterScope();

        // Declare params in scope
        for (params.items) |p| {
            const is_ptr = !std.mem.eql(u8, p.type_name, "i32") and !std.mem.eql(u8, p.type_name, "u32") and !std.mem.eql(u8, p.type_name, "f64");
            try self.scope_manager.declareVar(p.name, p.type_name, p.name, is_ptr);
        }

        // Parse body
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance(); // consume }
        }

        try self.scope_manager.exitScope(self.lowerer);
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

        try self.lowerer.emit("    jz {s}, {s}\n", .{ cond, else_label });

        // Then branch
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance();
        } else {
            try self.parseStatement();
        }

        try self.lowerer.emit("    jmp {s}\n", .{end_label});
        try self.lowerer.emit("{s}:\n", .{else_label});

        if (self.current.tag == .keyword_else) {
            try self.advance();
            if (self.current.tag == .keyword_if) {
                try self.parseIf();
            } else if (self.current.tag == .l_brace) {
                try self.advance();
                try self.scope_manager.enterScope();
                while (self.current.tag != .r_brace and self.current.tag != .eof) {
                    try self.parseStatement();
                }
                try self.scope_manager.exitScope(self.lowerer);
                try self.advance();
            } else {
                try self.parseStatement();
            }
        }

        try self.lowerer.emit("{s}:\n", .{end_label});
    }

    fn parseWhile(self: *Parser) anyerror!void {
        try self.expect(.keyword_while);
        try self.expect(.l_paren);

        const label_id = self.nextLabelId();
        const loop_label = try std.fmt.allocPrint(self.allocator, "L_while_{d}", .{label_id});
        const end_label = try std.fmt.allocPrint(self.allocator, "L_endwhile_{d}", .{label_id});

        try self.lowerer.emit("{s}:\n", .{loop_label});
        const cond = try self.parseExpression();
        try self.expect(.r_paren);

        try self.lowerer.emit("    jz {s}, {s}\n", .{ cond, end_label });

        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance();
        } else {
            try self.parseStatement();
        }

        try self.lowerer.emit("    jmp {s}\n", .{loop_label});
        try self.lowerer.emit("{s}:\n", .{end_label});
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

                // Emit for-of loop: iterate over iterable
                // Load length from iterable + 8 (string/slice layout)
                const len_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len_temp, iterable });

                const idx_var = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = 0\n", .{idx_var});

                try self.lowerer.emit("{s}:\n", .{loop_label});

                // Check idx < len
                const cmp_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = lt {s}, {s}\n", .{ cmp_temp, idx_var, len_temp });
                try self.lowerer.emit("    jz {s}, {s}\n", .{ cmp_temp, end_label });

                // Load element: iterable[idx]
                const ptr_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ptr_temp, iterable });
                const off_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = mul {s}, 4\n", .{ off_temp, idx_var });
                const addr_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, ptr_temp, off_temp });
                try self.lowerer.emit("    {s} = load {s} as i32\n", .{ iter_name, addr_temp });

                try self.scope_manager.enterScope();
                try self.scope_manager.declareVar(iter_name, "i32", iter_name, false);

                // Body
                if (self.current.tag == .l_brace) {
                    try self.advance();
                    try self.scope_manager.enterScope();
                    while (self.current.tag != .r_brace and self.current.tag != .eof) {
                        try self.parseStatement();
                    }
                    try self.scope_manager.exitScope(self.lowerer);
                    try self.advance();
                } else {
                    try self.parseStatement();
                }

                try self.scope_manager.exitScope(self.lowerer);

                // Increment idx
                const inc_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = add {s}, 1\n", .{ inc_temp, idx_var });
                try self.lowerer.emit("    {s} = {s}\n", .{ idx_var, inc_temp });

                try self.lowerer.emit("    jmp {s}\n", .{loop_label});
                try self.lowerer.emit("{s}:\n", .{end_label});
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

        try self.lowerer.emit("{s}:\n", .{loop_label});

        // Parse condition
        var cond: ?[]const u8 = null;
        if (self.current.tag != .semicolon) {
            cond = try self.parseExpression();
        }
        try self.expect(.semicolon);

        // Parse increment (we'll emit it at end of loop body)
        var inc_expr: ?[]const u8 = null;
        if (self.current.tag != .r_paren) {
            inc_expr = try self.parseExpression();
        }
        try self.expect(.r_paren);

        if (cond) |c| {
            try self.lowerer.emit("    jz {s}, {s}\n", .{ c, end_label });
        }

        // Body
        if (self.current.tag == .l_brace) {
            try self.advance();
            try self.scope_manager.enterScope();
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }
            try self.scope_manager.exitScope(self.lowerer);
            try self.advance();
        } else {
            try self.parseStatement();
        }

        // Increment
        if (inc_expr) |_| {
            // inc_expr was already emitted as temp registers, just need the assignment effect
        }

        try self.lowerer.emit("    jmp {s}\n", .{loop_label});
        try self.lowerer.emit("{s}:\n", .{end_label});
    }

    fn parseSwitch(self: *Parser) anyerror!void {
        try self.expect(.keyword_switch);
        try self.expect(.l_paren);
        const scrutinee = try self.parseExpression();
        try self.expect(.r_paren);

        const label_id = self.nextLabelId();
        const end_label = try std.fmt.allocPrint(self.allocator, "L_endswitch_{d}", .{label_id});

        try self.expect(.l_brace);

        var case_idx: u32 = 0;
        while (self.current.tag == .keyword_case) {
            try self.advance(); // case
            const case_val = try self.parseExpression();
            try self.expect(.colon);

            const case_label = try std.fmt.allocPrint(self.allocator, "L_case_{d}_{d}", .{ label_id, case_idx });
            const next_label = try std.fmt.allocPrint(self.allocator, "L_case_{d}_{d}", .{ label_id, case_idx + 1 });

            // Compare and jump
            const cmp_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
            try self.lowerer.emit("    {s} = eq {s}, {s}\n", .{ cmp_temp, scrutinee, case_val });
            try self.lowerer.emit("    jz {s}, {s}\n", .{ cmp_temp, next_label });
            try self.lowerer.emit("{s}:\n", .{case_label});

            while (self.current.tag != .keyword_case and self.current.tag != .r_brace and self.current.tag != .eof) {
                try self.parseStatement();
            }

            try self.lowerer.emit("    jmp {s}\n", .{end_label});
            case_idx += 1;
        }

        // default
        if (self.current.tag == .identifier) {
            const id = self.currentText();
            if (std.mem.eql(u8, id, "default")) {
                try self.advance();
                try self.expect(.colon);
                while (self.current.tag != .r_brace and self.current.tag != .eof) {
                    try self.parseStatement();
                }
            }
        }

        try self.expect(.r_brace);
        try self.lowerer.emit("{s}:\n", .{end_label});
    }

    // ==========================================
    // Return
    // ==========================================

    fn parseReturn(self: *Parser) anyerror!void {
        try self.expect(.keyword_return);
        if (self.current.tag != .semicolon and self.current.tag != .r_brace and self.current.tag != .eof) {
            const val = try self.parseExpression();
            try self.lowerer.emit("    return {s}\n", .{val});
        } else {
            try self.lowerer.emit("    return\n", .{});
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

        try self.lowerer.emit("    jmp {s}\n", .{end_label});
        try self.lowerer.emit("{s}:\n", .{catch_label});

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

        try self.lowerer.emit("{s}:\n", .{end_label});
    }

    fn parseThrow(self: *Parser) anyerror!void {
        try self.expect(.keyword_throw);
        const val = try self.parseExpression();
        _ = try self.accept(.semicolon);
        try self.lowerer.emit("    throw {s}\n", .{val});
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
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_read_file", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "writeFile")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_write_file", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "open")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_open", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "create")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_create", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "close")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_close", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "read")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_read", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "write")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_file_write", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "remove")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_remove_file", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "mkdir")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_fs_make_dir", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                }
            }
            try self.lowerer.emit("    // Stdlib: fs module imported\n", .{});
        } else if (std.mem.eql(u8, path, "net")) {
            // Standard library: network module
            for (symbols.items) |sym| {
                if (std.mem.eql(u8, sym, "tcpConnect")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_connect", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpListen")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_listener_bind", .string_args = "1" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpAccept")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_listener_accept", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpRead")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_stream_read", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpWrite")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_stream_write", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                } else if (std.mem.eql(u8, sym, "tcpClose")) {
                    try self.stdlib.append(.{ .name = sym, .sa_primitive = "sa_net_tcp_stream_close", .string_args = "" });
                    try self.scope_manager.declareVar(sym, "fn", sym, false);
                }
            }
            try self.lowerer.emit("    // Stdlib: net module imported\n", .{});
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




    fn parseTemplateLiteral(self: *Parser) anyerror![]const u8 {
        // template_start token contains the text before first ${
        // The token text includes the backtick, so strip it
        const first_tok_text = self.currentText();
        // Skip the leading backtick if present
        var first_text = first_tok_text;
        if (first_text.len > 0 and first_text[0] == '`') {
            first_text = first_text[1..];
        }

        // Switch lexer to template chunk mode
        self.template_lexer_mode = true;

        // Start building the result
        var result: []const u8 = undefined;
        var has_result = false;

        if (first_text.len > 0) {
            // Emit string constant for first text chunk
            const temp_id = self.nextLabelId();
            const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
            try self.lowerer.emit("    {s} = \"{s}\"\n", .{ temp_name, first_text });
            result = temp_name;
            has_result = true;
        }

        // Advance past template_start to get to the expression
        try self.advance(); // this uses nextTemplateChunk for peek

        // Now current is template_start consumed, peek is whatever nextTemplateChunk returned
        // Actually, after advance(), current = old peek (first expression token), peek = nextTemplateChunk result
        // We need to parse expressions and template chunks alternately

        while (self.current.tag != .template_end and self.current.tag != .eof) {
            // Parse the expression inside ${...}
            // The current token is the first token of the expression
            const expr_val = try self.parseExpression();

            if (has_result) {
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
                try self.lowerer.emit("    {s} = concat {s}, {s}\n", .{ temp_name, result, expr_val });
                result = temp_name;
            } else {
                result = expr_val;
                has_result = true;
            }

            // After the expression, the lexer should have produced template_mid or template_end
            // via nextTemplateChunk. The } that closes ${...} is consumed by the template chunk scanner.
            // current should now be template_mid or template_end.

            if (self.current.tag == .template_mid) {
                // Get the text between } and next ${
                const mid_text = self.currentText();
                if (mid_text.len > 0) {
                    const temp_id = self.nextLabelId();
                    const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
                    try self.lowerer.emit("    {s} = \"{s}\"\n", .{ temp_name, mid_text });
                    const concat_id = self.nextLabelId();
                    const concat_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{concat_id});
                    try self.lowerer.emit("    {s} = concat {s}, {s}\n", .{ concat_name, result, temp_name });
                    result = concat_name;
                }
                try self.advance(); // move to next expression
            }
            // If template_end, the loop condition will handle it
        }

        // Handle template_end - get the final text
        if (self.current.tag == .template_end) {
            const end_text = self.currentText();
            // Strip trailing backtick
            var final_text = end_text;
            if (final_text.len > 0 and final_text[final_text.len - 1] == '`') {
                final_text = final_text[0 .. final_text.len - 1];
            }
            if (final_text.len > 0) {
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
                try self.lowerer.emit("    {s} = \"{s}\"\n", .{ temp_name, final_text });
                if (has_result) {
                    const concat_id = self.nextLabelId();
                    const concat_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{concat_id});
                    try self.lowerer.emit("    {s} = concat {s}, {s}\n", .{ concat_name, result, temp_name });
                    result = concat_name;
                } else {
                    result = temp_name;
                    has_result = true;
                }
            }
            // Switch back to normal lexer mode and consume template_end
            self.template_lexer_mode = false;
            try self.advance();
        }

        if (!has_result) return "\"\"";
        return result;
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
                    // String literal: create a temporary string struct
                    const str_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                    const str_len = if (arg.len >= 2) arg.len - 2 else 0;
                    try self.lowerer.emit("    {s} = alloc 16\n", .{str_temp});
                    // Store pointer to string data (simplified: use the literal directly)
                    try self.lowerer.emit("    store {s} + 0, {s} as ptr\n", .{ str_temp, arg });
                    try self.lowerer.emit("    store {s} + 8, {d} as u64\n", .{ str_temp, str_len });
                    const ptr_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ptr_temp, str_temp });
                    const len_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                    try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len_temp, str_temp });
                    try transformed.append(ptr_temp);
                    try transformed.append(len_temp);
                } else {
                    // Variable: expand string struct to (ptr, len) pair
                    const ptr_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                    try self.lowerer.emit("    {s} = load {s} + 0 as ptr\n", .{ ptr_temp, arg });
                    const len_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                    try self.lowerer.emit("    {s} = load {s} + 8 as u64\n", .{ len_temp, arg });
                    try transformed.append(ptr_temp);
                    try transformed.append(len_temp);
                }
            } else {
                try transformed.append(arg);
            }
        }

        if (result_dest) |dest| {
            try self.lowerer.emit("    {s} = call @{s}(", .{ dest, entry.sa_primitive });
        } else {
            try self.lowerer.emit("    call @{s}(", .{entry.sa_primitive});
        }
        for (transformed.items, 0..) |arg, idx| {
            if (idx > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}", .{arg});
        }
        // Append arrow closure context if present
        if (self.last_arrow_ctx) |ctx_arg| {
            if (transformed.items.len > 0) try self.lowerer.emit(", ", .{});
            try self.lowerer.emit("{s}", .{ctx_arg});
            self.last_arrow_ctx = null;
        }
        try self.lowerer.emit(")\n", .{});
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
                    try self.lowerer.emit("    store {s} + {d}, {s} as {s}\n", .{ left_name, field.offset, val, field.type_name });
                    return;
                } else {
                    // Load intermediate
                    const temp_id = self.nextLabelId();
                    const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
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
                // Compute offset: index * 4 (default i32)
                const off_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = mul {s}, 4\n", .{ off_temp, index });
                const addr_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
                try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, name, off_temp });
                try self.lowerer.emit("    store {s}, {s} as i32\n", .{ addr_temp, val });
            }
        } else if (self.current.tag == .equal) {
            // Simple assignment: x = expr
            try self.advance();
            const val = try self.parseExpression();
            _ = try self.accept(.semicolon);
            try self.lowerer.emit("    {s} = {s}\n", .{ name, val });
        } else if (self.current.tag == .plus_plus) {
            try self.advance();
            _ = try self.accept(.semicolon);
            const temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
            try self.lowerer.emit("    {s} = add {s}, 1\n", .{ temp, name });
            try self.lowerer.emit("    {s} = {s}\n", .{ name, temp });
        } else if (self.current.tag == .minus_minus) {
            try self.advance();
            _ = try self.accept(.semicolon);
            const temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
            try self.lowerer.emit("    {s} = sub {s}, 1\n", .{ temp, name });
            try self.lowerer.emit("    {s} = {s}\n", .{ name, temp });
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
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
                try self.lowerer.emit("    {s} = neg {s}\n", .{ temp_name, operand });
                return temp_name;
            },
            .bang => {
                try self.advance();
                const operand = try self.parseExpressionWithPrecedence(.product);
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
                try self.lowerer.emit("    {s} = not {s}\n", .{ temp_name, operand });
                return temp_name;
            },
            .ampersand => {
                // Address-of: &var
                try self.advance();
                const tok = self.current;
                try self.expect(.identifier);
                const name = self.tokenText(tok);
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
                try self.lowerer.emit("    {s} = &{s}\n", .{ temp_name, name });
                return temp_name;
            },
            .caret => {
                // Move: ^var
                try self.advance();
                const tok = self.current;
                try self.expect(.identifier);
                const name = self.tokenText(tok);
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
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
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
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
                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
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

            const temp_id = self.nextLabelId();
            const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});

            const sa_op = switch (tag) {
                .plus => "add",
                .minus => "sub",
                .star => "mul",
                .slash => "div",
                .percent => "mod",
                else => unreachable,
            };

            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Comparison: == != < > <= >=
        if (tag == .equal_equal or tag == .bang_equal or tag == .less or tag == .greater or tag == .less_equal or tag == .greater_equal) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);

            const temp_id = self.nextLabelId();
            const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});

            const sa_op = switch (tag) {
                .equal_equal => "eq",
                .bang_equal => "ne",
                .less => "lt",
                .greater => "gt",
                .less_equal => "le",
                .greater_equal => "ge",
                else => unreachable,
            };

            try self.lowerer.emit("    {s} = {s} {s}, {s}\n", .{ temp_name, sa_op, left, right });
            return temp_name;
        }

        // Logical: && ||
        if (tag == .amp_amp or tag == .pipe_pipe) {
            try self.advance();
            const right = try self.parseExpressionWithPrecedence(precedence);

            const temp_id = self.nextLabelId();
            const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});

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
                    const temp_id = self.nextLabelId();
                    const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
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

                const temp_id = self.nextLabelId();
                const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});

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

            const off_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
            try self.lowerer.emit("    {s} = mul {s}, 4\n", .{ off_temp, index });

            const addr_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
            try self.lowerer.emit("    {s} = add {s}, {s}\n", .{ addr_temp, left, off_temp });

            const val_temp = try std.fmt.allocPrint(self.allocator, "t_{d}", .{self.nextLabelId()});
            try self.lowerer.emit("    {s} = load {s} as i32\n", .{ val_temp, addr_temp });
            return val_temp;
        }

        // Postfix increment/decrement: i++ / i--
        if (tag == .plus_plus or tag == .minus_minus) {
            try self.advance();
            const temp_id = self.nextLabelId();
            const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});
            const sa_op: []const u8 = if (tag == .plus_plus) "add" else "sub";
            try self.lowerer.emit("    {s} = {s} {s}, 1\n", .{ temp_name, sa_op, left });
            try self.lowerer.emit("    {s} = {s}\n", .{ left, temp_name });
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

            const temp_id = self.nextLabelId();
            const temp_name = try std.fmt.allocPrint(self.allocator, "t_{d}", .{temp_id});

            // Check if this is a stdlib function
            if (self.lookupStdlib(left)) |entry| {
                try self.emitStdlibCall(temp_name, entry, args);
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
