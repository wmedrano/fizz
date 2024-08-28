const Ast = @This();
const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const ErrorCollector = @import("datastructures/ErrorCollector.zig");

/// The Allocator that was used to allocate the ASTs.
allocator: std.mem.Allocator,
/// The nodes under the AST.
asts: []const Node,

const SyntaxError = error{
    /// An unclosed parenthesis. Example: (this-is-not-closed
    UnclosedParenthesis,
    /// There was a close parenthesis with no open parenthesis. Example: this-is-not-closed)
    UnmatchedCloseParenthesis,
    /// Ran out of memory while parsing the syntax.
    OutOfMemory,
};

/// Creates a new Ast. Some fields may reference data from the tokenizer. Other items will use
/// allocator to allocate memory.
pub fn init(allocator: std.mem.Allocator, errors: *ErrorCollector, t: *Tokenizer) SyntaxError!Ast {
    const asts = try Ast.initImpl(allocator, errors, t, false);
    return .{
        .allocator = allocator,
        .asts = asts,
    };
}

/// Create a new Ast with src as the source code. The created ASTs may reference bytes
/// from the src string.
pub fn initWithStr(allocator: std.mem.Allocator, errors: *ErrorCollector, src: []const u8) SyntaxError!Ast {
    var t = Tokenizer.init(src);
    return Ast.init(allocator, errors, &t);
}

/// Deallocate all ASTs within the collection.
pub fn deinit(self: Ast) void {
    deinitNodeSlice(self.allocator, self.asts);
}

fn deinitNodeSlice(allocator: std.mem.Allocator, ast: []const Node) void {
    for (ast) |*a| {
        switch (a.*) {
            .leaf => {},
            .tree => |tree| {
                deinitNodeSlice(allocator, tree);
            },
        }
    }
    allocator.free(ast);
}

fn initImpl(allocator: std.mem.Allocator, errors: *ErrorCollector, t: *Tokenizer, want_close: bool) SyntaxError![]Node {
    var result = std.ArrayList(Node).init(allocator);
    defer result.deinit();
    errdefer for (result.items) |r| {
        switch (r) {
            .tree => |tr| allocator.free(tr),
            .leaf => {},
        }
    };
    var has_close = false;
    while (t.next()) |token| {
        switch (token.typ) {
            .whitespace => continue,
            .openParen => {
                const sub_asts = try Ast.initImpl(allocator, errors, t, true);
                try result.append(.{ .tree = sub_asts });
            },
            .closeParen => {
                if (!want_close) {
                    try errors.addError(.{ .msg = "Unmatched close parenthesis" });
                    return SyntaxError.UnmatchedCloseParenthesis;
                }
                has_close = true;
                break;
            },
            .identifier => {
                try result.append(.{ .leaf = Node.Leaf.fromIdentifier(token.contents) });
            },
            .string => {
                const s = token.contents[1 .. token.contents.len - 1];
                const string = Node.Leaf{ .string = s };
                try result.append(.{ .leaf = string });
            },
        }
    }
    if (want_close and !has_close) {
        try errors.addError(.{ .msg = "Unclosed parenthesis" });
        return SyntaxError.UnclosedParenthesis;
    }
    return try result.toOwnedSlice();
}

/// Contains an Abstract Syntax Tree. It itself can be a leaf node, or a tree containing any number
/// of subtrees or leaf nodes.
pub const Node = union(enum) {
    /// A single leaf node. This is usually a literal or reference to a variable/constant.
    leaf: Leaf,
    /// A tree. Typically a tree denotes a function call where the first item denotes the function
    /// and the proceeding items are the arguments.
    tree: []const Node,

    pub const Leaf = union(enum) {
        /// A keyword.
        keyword: enum {
            // "if"
            if_expr,
            // "lambda"
            lambda,
            // "define"
            define,
            // "import"
            import,
        },
        /// A reference to a variable or constant. The name is stored as a string.
        identifier: []const u8,
        /// A string literal. The contents (without the literal quotes) are stored as a string.
        string: []const u8,
        /// A boolean literal.
        boolean: bool,
        /// An integer literal. The contents are parsed as an i64.
        int: i64,
        /// A float literal. The contents are parsed as an f64.
        float: f64,

        /// Pretty print the AST.
        pub fn format(self: *const Leaf, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            switch (self.*) {
                .keyword => |k| switch (k) {
                    .if_expr => try writer.print("if", .{}),
                    .lambda => try writer.print("lambda", .{}),
                    .define => try writer.print("define", .{}),
                    .import => try writer.print("import", .{}),
                },
                .identifier => |s| try writer.print("identifier({s})", .{s}),
                .string => |s| try writer.print("string({s})", .{s}),
                .boolean => |b| try writer.print("{any}", .{b}),
                .int => |n| try writer.print("int({})", .{n}),
                .float => |n| try writer.print("float({})", .{n}),
            }
        }

        // Parse a leaf from an identifier. If the identifier matches a number, then it is parsed into
        // an int or float Leaf.
        pub fn fromIdentifier(ident: []const u8) Leaf {
            if (std.mem.eql(u8, "true", ident)) {
                return .{ .boolean = true };
            }
            if (std.mem.eql(u8, "false", ident)) {
                return .{ .boolean = false };
            }
            if (std.mem.eql(u8, "if", ident)) {
                return .{ .keyword = .if_expr };
            }
            if (std.mem.eql(u8, "lambda", ident)) {
                return .{ .keyword = .lambda };
            }
            if (std.mem.eql(u8, "define", ident)) {
                return .{ .keyword = .define };
            }
            if (std.mem.eql(u8, "import", ident)) {
                return .{ .keyword = .import };
            }
            if (std.fmt.parseInt(i64, ident, 10)) |i| {
                return .{ .int = i };
            } else |_| {}
            if (std.fmt.parseFloat(f64, ident)) |f| {
                return .{ .float = f };
            } else |_| {}
            return .{ .identifier = ident };
        }
    };

    /// Pretty print the AST.
    pub fn format(self: *const Node, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return self.formatImpl(0, writer);
    }

    fn formatImpl(self: *const Node, indent: u8, writer: anytype) !void {
        switch (self.*) {
            .leaf => |l| {
                for (0..indent) |_| {
                    try writer.print("  ", .{});
                }
                try writer.print("{any}\n", .{l});
            },
            .tree => |elements| {
                for (0.., elements) |idx, e| {
                    const new_indent = if (idx == 0) indent else indent + 1;
                    try e.formatImpl(new_indent, writer);
                }
            },
        }
    }
};

test "basic expression is parsed" {
    var t = Tokenizer.init("(define + 1 2.1 (string-length \"hello\") (if true 10) (if false 11 12))");
    var errors = ErrorCollector.init(std.testing.allocator);
    defer errors.deinit();
    var ast = try Ast.init(std.testing.allocator, &errors, &t);
    defer ast.deinit();

    try std.testing.expectEqualDeep(Ast{
        .allocator = std.testing.allocator,
        .asts = &[_]Node{
            .{
                .tree = &.{
                    .{ .leaf = .{ .keyword = .define } },
                    .{ .leaf = .{ .identifier = "+" } },
                    .{ .leaf = .{ .int = 1 } },
                    .{ .leaf = .{ .float = 2.1 } },
                    .{ .tree = &.{
                        .{ .leaf = .{ .identifier = "string-length" } },
                        .{ .leaf = .{ .string = "hello" } },
                    } },
                    .{ .tree = &.{
                        .{ .leaf = .{ .keyword = .if_expr } },
                        .{ .leaf = .{ .boolean = true } },
                        .{ .leaf = .{ .int = 10 } },
                    } },
                    .{ .tree = &.{
                        .{ .leaf = .{ .keyword = .if_expr } },
                        .{ .leaf = .{ .boolean = false } },
                        .{ .leaf = .{ .int = 11 } },
                        .{ .leaf = .{ .int = 12 } },
                    } },
                },
            },
        },
    }, ast);
}

test "lambda is parsed" {
    var t = Tokenizer.init("(lambda (a b) (+ a b))");
    var errors = ErrorCollector.init(std.testing.allocator);
    defer errors.deinit();
    var ast = try Ast.init(std.testing.allocator, &errors, &t);
    defer ast.deinit();

    try std.testing.expectEqualDeep(Ast{
        .allocator = std.testing.allocator,
        .asts = &[_]Node{
            .{
                .tree = &.{
                    .{ .leaf = .{ .keyword = .lambda } },
                    .{ .tree = &.{
                        .{ .leaf = .{ .identifier = "a" } },
                        .{ .leaf = .{ .identifier = "b" } },
                    } },
                    .{ .tree = &.{
                        .{ .leaf = .{ .identifier = "+" } },
                        .{ .leaf = .{ .identifier = "a" } },
                        .{ .leaf = .{ .identifier = "b" } },
                    } },
                },
            },
        },
    }, ast);
}

test "multiple expressions can be parsed" {
    var t = Tokenizer.init("1 2.3 four \"five\"");
    var errors = ErrorCollector.init(std.testing.allocator);
    defer errors.deinit();
    var ast = try Ast.init(std.testing.allocator, &errors, &t);
    defer ast.deinit();

    try std.testing.expectEqualDeep(Ast{
        .allocator = std.testing.allocator,
        .asts = &[_]Node{
            .{ .leaf = .{ .int = 1 } },
            .{ .leaf = .{ .float = 2.3 } },
            .{ .leaf = .{ .identifier = "four" } },
            .{ .leaf = .{ .string = "five" } },
        },
    }, ast);
}

test "unmatched closing brace is error" {
    var t = Tokenizer.init("())");
    var errors = ErrorCollector.init(std.testing.allocator);
    defer errors.deinit();
    const ast_or_err = Ast.init(std.testing.allocator, &errors, &t);
    try std.testing.expectError(SyntaxError.UnmatchedCloseParenthesis, ast_or_err);
}

test "unmatched opening brace is error" {
    var t = Tokenizer.init("(()");
    var errors = ErrorCollector.init(std.testing.allocator);
    defer errors.deinit();
    const ast_or_err = Ast.init(std.testing.allocator, &errors, &t);
    try std.testing.expectError(SyntaxError.UnclosedParenthesis, ast_or_err);
}

test "error on second expression is detected" {
    var t = Tokenizer.init("(+ 1 2 3) ))");
    var errors = ErrorCollector.init(std.testing.allocator);
    defer errors.deinit();
    const ast_or_err = Ast.init(std.testing.allocator, &errors, &t);
    try std.testing.expectError(SyntaxError.UnmatchedCloseParenthesis, ast_or_err);
}
