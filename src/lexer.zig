const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: u32,
    len: u32,
    line: u32,
    col: u32,

    pub const Tag = enum {
        eof,
        identifier,
        keyword_let,
        keyword_const,
        keyword_function,
        keyword_interface,
        keyword_if,
        keyword_else,
        keyword_while,
        keyword_return,
        keyword_import,
        keyword_from,
        keyword_declare,
        keyword_as,
        keyword_for,
        keyword_switch,
        keyword_case,
        keyword_break,
        keyword_continue,
        keyword_type,
        keyword_enum,
        keyword_async,
        keyword_await,
        keyword_try,
        keyword_catch,
        keyword_throw,
        keyword_class,
        keyword_extends,
        keyword_new,
        keyword_typeof,
        keyword_void,
        keyword_null,
        keyword_undefined,
        keyword_true,
        keyword_false,
        equal,
        equal_equal,
        bang,
        bang_equal,
        plus,
        plus_plus,
        minus,
        minus_minus,
        star,
        slash,
        percent,
        amp_amp,
        pipe_pipe,
        less,
        less_equal,
        greater,
        greater_equal,
        l_bracket,
        r_bracket,
        l_brace,
        r_brace,
        l_paren,
        r_paren,
        semicolon,
        dot,
        comma,
        colon,
        question,
        arrow, // =>
        ellipsis, // ...
        at, // @
        ampersand, // & (address-of in SA)
        caret, // ^ (move in SA)
        number,
        string,
        template_start, // `...${
        template_mid,   // }...${
        template_end,   // }...`
        invalid,
    };
};

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    col: u32 = 1,
    // Template literal tracking
    template_depth: u32 = 0,

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) {
            return .{ .tag = .eof, .start = self.pos, .len = 0, .line = self.line, .col = self.col };
        }

        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        const c = self.source[self.pos];
        self.pos += 1;
        self.col += 1;

        switch (c) {
            '{' => return .{ .tag = .l_brace, .start = start, .len = 1, .line = start_line, .col = start_col },
            '}' => return .{ .tag = .r_brace, .start = start, .len = 1, .line = start_line, .col = start_col },
            '[' => return .{ .tag = .l_bracket, .start = start, .len = 1, .line = start_line, .col = start_col },
            ']' => return .{ .tag = .r_bracket, .start = start, .len = 1, .line = start_line, .col = start_col },
            '(' => return .{ .tag = .l_paren, .start = start, .len = 1, .line = start_line, .col = start_col },
            ')' => return .{ .tag = .r_paren, .start = start, .len = 1, .line = start_line, .col = start_col },
            ';' => return .{ .tag = .semicolon, .start = start, .len = 1, .line = start_line, .col = start_col },
            '.' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and self.source[self.pos + 1] == '.') {
                    self.pos += 2;
                    self.col += 2;
                    return .{ .tag = .ellipsis, .start = start, .len = 3, .line = start_line, .col = start_col };
                }
                return .{ .tag = .dot, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            ',' => return .{ .tag = .comma, .start = start, .len = 1, .line = start_line, .col = start_col },
            ':' => return .{ .tag = .colon, .start = start, .len = 1, .line = start_line, .col = start_col },
            '?' => return .{ .tag = .question, .start = start, .len = 1, .line = start_line, .col = start_col },
            '@' => return .{ .tag = .at, .start = start, .len = 1, .line = start_line, .col = start_col },
            '&' => {
                if (self.pos < self.source.len and self.source[self.pos] == '&') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .amp_amp, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .ampersand, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '^' => return .{ .tag = .caret, .start = start, .len = 1, .line = start_line, .col = start_col },
            '=' => {
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .arrow, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .equal_equal, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .equal, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '!' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .bang_equal, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .bang, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '+' => {
                if (self.pos < self.source.len and self.source[self.pos] == '+') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .plus_plus, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .plus, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '-' => {
                if (self.pos < self.source.len and self.source[self.pos] == '-') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .minus_minus, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .minus, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '*' => return .{ .tag = .star, .start = start, .len = 1, .line = start_line, .col = start_col },
            '/' => return .{ .tag = .slash, .start = start, .len = 1, .line = start_line, .col = start_col },
            '%' => return .{ .tag = .percent, .start = start, .len = 1, .line = start_line, .col = start_col },
            '<' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .less_equal, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .less, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '>' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .greater_equal, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .greater, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '|' => {
                if (self.pos < self.source.len and self.source[self.pos] == '|') {
                    self.pos += 1;
                    self.col += 1;
                    return .{ .tag = .pipe_pipe, .start = start, .len = 2, .line = start_line, .col = start_col };
                }
                return .{ .tag = .invalid, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
            '`' => {
                // Template literal start
                self.template_depth += 1;
                // Scan until first ${
                while (self.pos < self.source.len) {
                    const tc = self.source[self.pos];
                    if (tc == '$' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                        const len = self.pos - start;
                        self.pos += 2;
                        self.col += 2;
                        return .{ .tag = .template_start, .start = start, .len = @intCast(len), .line = start_line, .col = start_col };
                    }
                    self.pos += 1;
                    if (tc == '\n') {
                        self.line += 1;
                        self.col = 1;
                    } else {
                        self.col += 1;
                    }
                }
                // Reached EOF inside template — close as template_end
                self.template_depth -|= 1;
                return .{ .tag = .template_end, .start = start, .len = self.pos - start, .line = start_line, .col = start_col };
            },
            '"', '\'' => {
                const quote = c;
                while (self.pos < self.source.len) {
                    const next_c = self.source[self.pos];
                    self.pos += 1;
                    self.col += 1;
                    if (next_c == quote) {
                        break;
                    }
                    if (next_c == '\\' and self.pos < self.source.len) {
                        self.pos += 1;
                        self.col += 1;
                    }
                    if (next_c == '\n') {
                        self.line += 1;
                        self.col = 1;
                    }
                }
                return .{ .tag = .string, .start = start, .len = self.pos - start, .line = start_line, .col = start_col };
            },
            else => {
                if (std.ascii.isDigit(c)) {
                    var has_dot = false;
                    while (self.pos < self.source.len) {
                        const next_c = self.source[self.pos];
                        if (next_c == '.') {
                            if (has_dot) break;
                            has_dot = true;
                            self.pos += 1;
                            self.col += 1;
                        } else if (std.ascii.isDigit(next_c)) {
                            self.pos += 1;
                            self.col += 1;
                        } else {
                            break;
                        }
                    }
                    return .{ .tag = .number, .start = start, .len = self.pos - start, .line = start_line, .col = start_col };
                }

                if (std.ascii.isAlphabetic(c) or c == '_') {
                    while (self.pos < self.source.len) {
                        const next_c = self.source[self.pos];
                        if (std.ascii.isAlphanumeric(next_c) or next_c == '_') {
                            self.pos += 1;
                            self.col += 1;
                        } else {
                            break;
                        }
                    }
                    const text = self.source[start..self.pos];
                    const tag = getKeywordTag(text);
                    return .{ .tag = tag, .start = start, .len = self.pos - start, .line = start_line, .col = start_col };
                }

                return .{ .tag = .invalid, .start = start, .len = 1, .line = start_line, .col = start_col };
            },
        }
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                self.col = 1;
            } else if (c == ' ' or c == '\t' or c == '\r') {
                // Fast path: skip runs of spaces/tabs using SIMD-like batch processing
                const remaining = self.source[self.pos..];
                var batch_end: u32 = 0;
                // Process 16 bytes at a time
                while (batch_end + 16 <= remaining.len) {
                    const batch: @Vector(16, u8) = remaining[batch_end..][0..16].*;
                    const spaces: @Vector(16, u8) = @splat(' ');
                    const tabs: @Vector(16, u8) = @splat('\t');
                    const crs: @Vector(16, u8) = @splat('\r');
                    const is_space = batch == spaces;
                    const is_tab = batch == tabs;
                    const is_cr = batch == crs;
                    // Combine with bitwise OR on integer representation
                    const ws_u16 = @as(u16, @bitCast(is_space)) | @as(u16, @bitCast(is_tab)) | @as(u16, @bitCast(is_cr));
                    // Count consecutive whitespace bytes
                    const mask = ws_u16;
                    if (mask != 0xFFFF) {
                        // Found a non-whitespace byte
                        batch_end += @intCast(@ctz(~mask));
                        break;
                    }
                    batch_end += 16;
                }
                // Handle remaining bytes
                while (batch_end < remaining.len and (remaining[batch_end] == ' ' or remaining[batch_end] == '\t' or remaining[batch_end] == '\r')) {
                    batch_end += 1;
                }
                self.pos += batch_end;
                self.col += batch_end;
            } else if (c == '/' and self.pos + 1 < self.source.len) {
                const next_c = self.source[self.pos + 1];
                if (next_c == '/') {
                    self.pos += 2;
                    self.col += 2;
                    // Fast scan for newline using SIMD batch
                    const remaining = self.source[self.pos..];
                    var batch_end: u32 = 0;
                    while (batch_end + 16 <= remaining.len) {
                        const batch: @Vector(16, u8) = remaining[batch_end..][0..16].*;
                        const newlines: @Vector(16, u8) = @splat('\n');
                        const has_nl = batch == newlines;
                        const mask = @as(u16, @bitCast(has_nl));
                        if (mask != 0) {
                            batch_end += @intCast(@ctz(mask));
                            break;
                        }
                        batch_end += 16;
                    }
                    self.pos += batch_end;
                    self.col += batch_end;
                } else if (next_c == '*') {
                    self.pos += 2;
                    self.col += 2;
                    while (self.pos + 1 < self.source.len) : (self.pos += 1) {
                        if (self.source[self.pos] == '\n') {
                            self.line += 1;
                            self.col = 1;
                        } else if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                            self.pos += 2;
                            self.col += 2;
                            break;
                        } else {
                            self.col += 1;
                        }
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    /// Handle closing brace inside template literal: }...` or }...${
    pub fn nextTemplateChunk(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) {
            return .{ .tag = .eof, .start = self.pos, .len = 0, .line = self.line, .col = self.col };
        }

        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;

        while (self.pos < self.source.len) {
            const tc = self.source[self.pos];
            if (tc == '`') {
                // End of template
                self.template_depth -|= 1;
                const len = self.pos - start;
                self.pos += 1;
                self.col += 1;
                return .{ .tag = .template_end, .start = start, .len = @intCast(len), .line = start_line, .col = start_col };
            }
            if (tc == '$' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                const len = self.pos - start;
                self.pos += 2;
                self.col += 2;
                return .{ .tag = .template_mid, .start = start, .len = @intCast(len), .line = start_line, .col = start_col };
            }
            self.pos += 1;
            if (tc == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }

        return .{ .tag = .template_end, .start = start, .len = self.pos - start, .line = start_line, .col = start_col };
    }
};

fn getKeywordTag(text: []const u8) Token.Tag {
    if (std.mem.eql(u8, text, "let")) return .keyword_let;
    if (std.mem.eql(u8, text, "const")) return .keyword_const;
    if (std.mem.eql(u8, text, "function")) return .keyword_function;
    if (std.mem.eql(u8, text, "interface")) return .keyword_interface;
    if (std.mem.eql(u8, text, "if")) return .keyword_if;
    if (std.mem.eql(u8, text, "else")) return .keyword_else;
    if (std.mem.eql(u8, text, "while")) return .keyword_while;
    if (std.mem.eql(u8, text, "return")) return .keyword_return;
    if (std.mem.eql(u8, text, "import")) return .keyword_import;
    if (std.mem.eql(u8, text, "from")) return .keyword_from;
    if (std.mem.eql(u8, text, "declare")) return .keyword_declare;
    if (std.mem.eql(u8, text, "as")) return .keyword_as;
    if (std.mem.eql(u8, text, "for")) return .keyword_for;
    if (std.mem.eql(u8, text, "switch")) return .keyword_switch;
    if (std.mem.eql(u8, text, "case")) return .keyword_case;
    if (std.mem.eql(u8, text, "break")) return .keyword_break;
    if (std.mem.eql(u8, text, "continue")) return .keyword_continue;
    if (std.mem.eql(u8, text, "type")) return .keyword_type;
    if (std.mem.eql(u8, text, "enum")) return .keyword_enum;
    if (std.mem.eql(u8, text, "async")) return .keyword_async;
    if (std.mem.eql(u8, text, "await")) return .keyword_await;
    if (std.mem.eql(u8, text, "try")) return .keyword_try;
    if (std.mem.eql(u8, text, "catch")) return .keyword_catch;
    if (std.mem.eql(u8, text, "throw")) return .keyword_throw;
    if (std.mem.eql(u8, text, "class")) return .keyword_class;
    if (std.mem.eql(u8, text, "extends")) return .keyword_extends;
    if (std.mem.eql(u8, text, "new")) return .keyword_new;
    if (std.mem.eql(u8, text, "typeof")) return .keyword_typeof;
    if (std.mem.eql(u8, text, "void")) return .keyword_void;
    if (std.mem.eql(u8, text, "null")) return .keyword_null;
    if (std.mem.eql(u8, text, "undefined")) return .keyword_undefined;
    if (std.mem.eql(u8, text, "true")) return .keyword_true;
    if (std.mem.eql(u8, text, "false")) return .keyword_false;
    return .identifier;
}
