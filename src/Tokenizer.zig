const Tokenizer = @This();
const std = @import("std");

/// The entire string that will be tokenized.
contents: []const u8,
/// The starting index of the next token to parse.
idx: usize,

/// Holds a token. This contains its classification and its string contents.
pub const Token = struct {
    /// Contains all the types of tokens.
    pub const Type = enum {
        /// A whitespace token. Consists of any sequence of ' ', '\t', and '\n'.
        whitespace,
        /// Corresponds to the '(' character.
        openParen,
        /// Corresponds to the ')' character.
        closeParen,
        /// Any identifier. This includes number literals, but not string literals.
        identifier,
        /// A string literal. The contents of the Token will contain the start and end quotes.
        string,

        /// Guess the type of s by looking at the first character.
        pub fn guessType(s: []const u8) Type {
            if (s.len == 1) {
                return switch (s[0]) {
                    ' ' => return .whitespace,
                    '\t' => return .whitespace,
                    '\n' => return .whitespace,
                    '(' => return .openParen,
                    ')' => return .closeParen,
                    '"' => return .string,
                    else => return .identifier,
                };
            }
            return .identifier;
        }
    };

    /// The type of the token.
    typ: Type,
    /// The string contents of the token.
    contents: []const u8,
};

/// Create a tokenizer over contents.
pub fn init(contents: []const u8) Tokenizer {
    return Tokenizer{
        .contents = contents,
        .idx = 0,
    };
}

/// Start parsing the input stream from the beginning.
pub fn reset(self: *Tokenizer) void {
    self.idx = 0;
}

/// Peek at the next token without advancing the iterator.
pub fn peek(self: *Tokenizer) ?Token {
    if (self.idx == self.contents.len) {
        return null;
    }
    const start = self.idx;
    var end = start;
    var token_type = Token.Type.whitespace;
    while (end < self.contents.len) {
        const codepoint_length = std.unicode.utf8ByteSequenceLength(self.contents[0]) catch break;
        const codepoint = self.contents[end .. end + codepoint_length];
        if (start == end) {
            token_type = Token.Type.guessType(codepoint);
        } else {
            const new_token_type = Token.Type.guessType(codepoint);
            switch (token_type) {
                .openParen => break,
                .closeParen => break,
                .string => if (new_token_type == Token.Type.string) {
                    end += codepoint_length;
                    break;
                },
                .whitespace => if (new_token_type != Token.Type.whitespace) {
                    break;
                },
                .identifier => if (new_token_type != Token.Type.identifier) {
                    break;
                },
            }
        }
        end += codepoint_length;
    }
    return .{
        .typ = token_type,
        .contents = self.contents[start..end],
    };
}

/// Get the next token.
pub fn next(self: *Tokenizer) ?Token {
    const next_val = self.peek() orelse return null;
    self.idx += next_val.contents.len;
    return next_val;
}

/// Collect all the tokens into an AraryList. This is typically only used for unit testing.
pub fn collectAll(self: *Tokenizer, alloc: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(Token) {
    var ret = std.ArrayList(Token).init(alloc);
    errdefer ret.deinit();
    while (self.next()) |token| {
        try ret.append(token);
    }
    return ret;
}

test "parse expression" {
    var tokenizer = Tokenizer.init("  (parse-expression-1  234)");
    const result = try tokenizer.collectAll(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqualDeep(&[_]Token{
        .{ .typ = .whitespace, .contents = "  " },
        .{ .typ = .openParen, .contents = "(" },
        .{ .typ = .identifier, .contents = "parse-expression-1" },
        .{ .typ = .whitespace, .contents = "  " },
        .{ .typ = .identifier, .contents = "234" },
        .{ .typ = .closeParen, .contents = ")" },
    }, result.items);
}

test "parse with duplicate tokens" {
    var tokenizer = Tokenizer.init("  \t\n(())\"\"");
    const result = try tokenizer.collectAll(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqualDeep(&[_]Token{
        .{ .typ = .whitespace, .contents = "  \t\n" },
        .{ .typ = .openParen, .contents = "(" },
        .{ .typ = .openParen, .contents = "(" },
        .{ .typ = .closeParen, .contents = ")" },
        .{ .typ = .closeParen, .contents = ")" },
        .{ .typ = .string, .contents = "\"\"" },
    }, result.items);
}

test "parse string" {
    var tokenizer = Tokenizer.init("(\"(this is a string)\")");
    const result = try tokenizer.collectAll(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqualDeep(&[_]Token{
        .{ .typ = .openParen, .contents = "(" },
        .{ .typ = .string, .contents = "\"(this is a string)\"" },
        .{ .typ = .closeParen, .contents = ")" },
    }, result.items);
}

test "empty expression" {
    var tokenizer = Tokenizer.init("");
    const result = try tokenizer.collectAll(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqualDeep(&[_]Token{}, result.items);
}
