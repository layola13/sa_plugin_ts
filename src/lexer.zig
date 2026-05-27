const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: u32,
    len: u32,

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
        equal,
        plus,
        minus,
        star,
        slash,
        l_brace,
        r_brace,
        l_paren,
        r_paren,
        semicolon,
        dot,
        comma,
        colon,
        arrow, // =>
        number,
        string,
        invalid,
    };
};

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) {
            return .{ .tag = .eof, .start = self.pos, .len = 0 };
        }

        const start = self.pos;
        const c = self.source[self.pos];
        self.pos += 1;

        switch (c) {
            '{' => return .{ .tag = .l_brace, .start = start, .len = 1 },
            '}' => return .{ .tag = .r_brace, .start = start, .len = 1 },
            '(' => return .{ .tag = .l_paren, .start = start, .len = 1 },
            ')' => return .{ .tag = .r_paren, .start = start, .len = 1 },
            ';' => return .{ .tag = .semicolon, .start = start, .len = 1 },
            '.' => return .{ .tag = .dot, .start = start, .len = 1 },
            ',' => return .{ .tag = .comma, .start = start, .len = 1 },
            ':' => return .{ .tag = .colon, .start = start, .len = 1 },
            '=' => {
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return .{ .tag = .arrow, .start = start, .len = 2 };
                }
                return .{ .tag = .equal, .start = start, .len = 1 };
            },
            '+' => return .{ .tag = .plus, .start = start, .len = 1 },
            '-' => return .{ .tag = .minus, .start = start, .len = 1 },
            '*' => return .{ .tag = .star, .start = start, .len = 1 },
            '/' => return .{ .tag = .slash, .start = start, .len = 1 },
            '"', '\'' => {
                const quote = c;
                while (self.pos < self.source.len) {
                    const next_c = self.source[self.pos];
                    self.pos += 1;
                    if (next_c == quote) {
                        break;
                    }
                    if (next_c == '\\' and self.pos < self.source.len) {
                        self.pos += 1; // skip escaped character
                    }
                }
                return .{ .tag = .string, .start = start, .len = self.pos - start };
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
                        } else if (std.ascii.isDigit(next_c)) {
                            self.pos += 1;
                        } else {
                            break;
                        }
                    }
                    return .{ .tag = .number, .start = start, .len = self.pos - start };
                }

                if (std.ascii.isAlphabetic(c) or c == '_') {
                    while (self.pos < self.source.len) {
                        const next_c = self.source[self.pos];
                        if (std.ascii.isAlphanumeric(next_c) or next_c == '_') {
                            self.pos += 1;
                        } else {
                            break;
                        }
                    }
                    const text = self.source[start..self.pos];
                    const tag = getKeywordTag(text);
                    return .{ .tag = tag, .start = start, .len = self.pos - start };
                }

                return .{ .tag = .invalid, .start = start, .len = 1 };
            },
        }
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.source.len) {
                const next_c = self.source[self.pos + 1];
                if (next_c == '/') {
                    self.pos += 2;
                    while (self.pos < self.source.len) : (self.pos += 1) {
                        if (self.source[self.pos] == '\n') {
                            self.pos += 1;
                            break;
                        }
                    }
                } else if (next_c == '*') {
                    self.pos += 2;
                    while (self.pos + 1 < self.source.len) : (self.pos += 1) {
                        if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                            self.pos += 2;
                            break;
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
};

fn getKeywordTag(text: []const u8) Token.Tag {
    if (std.mem.eql(u8, text, "let")) return .keyword_let;
    if (std.mem.eql(u8, text, "const")) return .keyword_const;
    if (std.mem.eql(u8, text, "function")) return .keyword_function;
    if (std.mem.eql(u8, text, "interface")) return .keyword_interface;
    if (std.mem.eql(u8, text, "if")) return .keyword_if;
    if (std.mem.eql(u8, text, "else")) return .keyword_else;
    if (std.mem.eql(u8, text, "while")) return .keyword_while;
    return .identifier;
}
