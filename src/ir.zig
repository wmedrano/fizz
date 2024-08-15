const std = @import("std");
const Val = @import("val.zig").Val;
const Ast = @import("Ast.zig");
const MemoryManager = @import("MemoryManager.zig");

/// Holds the intermediate representation. This is somewhere between the AST and bytecode in level
/// of complexity.
pub const Ir = union(enum) {
    /// A single constant value.
    constant: Const,
    /// A define statement.
    define: struct {
        name: []const u8,
        expr: *Ir,
    },
    /// Import a module from a path.
    import_module: struct {
        path: []const u8,
    },
    /// Dereference an identifier.
    deref: []const u8,
    /// A function call.
    function_call: struct {
        /// The function to call.
        function: *Ir,
        /// The arguments to the function.
        args: []*Ir,
    },
    /// Construct an if expression.
    if_expr: struct {
        /// The predicate that will be evaluated.
        predicate: *Ir,
        /// The block to return on true.
        true_expr: *Ir,
        /// The block to return on false or null if Val.void should be returned.
        false_expr: ?*Ir,
    },
    /// Defines a lambda.
    lambda: struct {
        name: []const u8,
        args: [][]const u8,
        exprs: []*Ir,
    },
    ret: struct {
        exprs: []*Ir,
    },

    pub const Tag = @typeInfo(Ir).Union.tag_type.?;
    pub const Error = std.mem.Allocator.Error || error{ NotImplemented, SyntaxError };

    const Const = union(enum) {
        none,
        symbol: []const u8,
        string: []const u8,
        boolean: bool,
        int: i64,
        float: f64,

        pub fn toVal(self: Const, memory_manager: *MemoryManager) !Val {
            switch (self) {
                .none => return .none,
                .symbol => |s| return try memory_manager.allocateSymbolVal(s),
                .string => |s| return try memory_manager.allocateStringVal(s),
                .boolean => |b| return .{ .boolean = b },
                .int => |i| return .{ .int = i },
                .float => |f| return .{ .float = f },
            }
        }
    };

    /// Initialize an Ir from an AST.
    pub fn init(allocator: std.mem.Allocator, ast: []const Ast.Node) !*Ir {
        var builder = IrBuilder{
            .allocator = allocator,
            .arg_to_idx = .{},
        };
        const exprs = try allocator.alloc(*Ir, ast.len);
        errdefer allocator.free(exprs);
        for (0..ast.len, ast) |idx, node| {
            exprs[idx] = try builder.build("_", &node);
            errdefer exprs[idx].deinit(allocator);
        }
        const ret = try allocator.create(Ir);
        ret.* = Ir{
            .ret = .{
                .exprs = exprs,
            },
        };
        return ret;
    }

    /// Initialize an Ir from a string expression.
    pub fn initStrExpr(allocator: std.mem.Allocator, expr: []const u8) !*Ir {
        var asts = try Ast.initWithStr(allocator, expr);
        defer asts.deinit();
        return init(allocator, asts.asts);
    }

    /// Populate define_set with all symbols that are defined.
    pub fn definedVals(self: *const Ir, defined_vals: *std.StringHashMap(void)) !void {
        switch (self.*) {
            .define => |def| try defined_vals.put(def.name, {}),
            .ret => |r| for (r.exprs) |e| try e.definedVals(defined_vals),
            else => {},
        }
    }

    /// Deallocate Ir and all related memory.
    pub fn deinit(self: *Ir, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .constant => {},
            .define => |def| def.expr.deinit(allocator),
            .import_module => {},
            .deref => {},
            .function_call => |*f| {
                f.function.deinit(allocator);
                for (f.args) |a| a.deinit(allocator);
                allocator.free(f.args);
            },
            .if_expr => |*expr| {
                expr.predicate.deinit(allocator);
                expr.true_expr.deinit(allocator);
                if (expr.false_expr) |e| e.deinit(allocator);
            },
            .lambda => |l| {
                allocator.free(l.args);
                for (l.exprs) |e| e.deinit(allocator);
                allocator.free(l.exprs);
            },
            .ret => |ret| {
                for (ret.exprs) |e| e.deinit(allocator);
                allocator.free(ret.exprs);
            },
        }
        allocator.destroy(self);
    }

    pub fn format(self: *const Ir, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.*) {
            .constant => |c| try writer.print("constant({any}) ", .{c}),
            .define => |d| try writer.print("define({s}, {any}) ", .{ d.name, d.expr }),
            .import_module => |i| try writer.print("import({s})", .{i.path}),
            .deref => |d| try writer.print("deref({s}) ", .{d}),
            .function_call => |f| try writer.print("funcall({any}, {any}) ", .{ f.function, f.args }),
            .if_expr => |e| try writer.print("if({any}, {any}, {any}) ", .{ e.predicate, e.true_expr, e.false_expr }),
            .lambda => |l| try writer.print("lambda({any}) ", .{l.exprs}),
            .ret => |r| try writer.print("ret({any}) ", .{r.exprs}),
        }
        try writer.print("\n", .{});
    }
};

const IrBuilder = struct {
    allocator: std.mem.Allocator,
    arg_to_idx: std.StringHashMapUnmanaged(usize),

    const Error = Ir.Error;

    /// Build an Ir from IrBuilder.
    pub fn build(self: *IrBuilder, name: []const u8, ast: *const Ast.Node) !*Ir {
        switch (ast.*) {
            .leaf => return self.buildLeaf(&ast.leaf),
            .tree => |asts| {
                if (asts.len == 0) {
                    return Error.SyntaxError;
                }
                const first = &asts[0];
                const rest = asts[1..];
                switch (first.*) {
                    .leaf => |l| {
                        switch (l) {
                            .keyword => |k| switch (k) {
                                .if_expr => {
                                    switch (rest.len) {
                                        0 | 1 => return Error.SyntaxError,
                                        2 => return self.buildIfExpression(&rest[0], &rest[1], null),
                                        3 => return self.buildIfExpression(&rest[0], &rest[1], &rest[2]),
                                        else => return Error.SyntaxError,
                                    }
                                },
                                .lambda => {
                                    if (rest.len < 2) {
                                        return Error.SyntaxError;
                                    }
                                    return self.buildLambdaExpr(name, &rest[0], rest[1..]);
                                },
                                .define => {
                                    switch (rest.len) {
                                        0 | 1 => return Error.SyntaxError,
                                        2 => return self.buildDefine(&rest[0], &rest[1]),
                                        else => return Error.SyntaxError,
                                    }
                                },
                                .import => {
                                    if (rest.len != 1) return Error.SyntaxError;
                                    return self.buildImportModule(&rest[0]);
                                },
                            },
                            else => return self.buildFunctionCall(first, rest),
                        }
                    },
                    else => return self.buildFunctionCall(first, rest),
                }
            },
        }
    }

    pub fn deinit(self: *IrBuilder) void {
        self.arg_to_idx.deinit(self.allocator);
    }

    /// Build an Ir from a single AST leaf.
    fn buildLeaf(self: *IrBuilder, leaf: *const Ast.Node.Leaf) Error!*Ir {
        const v = switch (leaf.*) {
            .keyword => return Error.SyntaxError,
            .identifier => |ident| return self.buildDeref(ident),
            .string => |s| Ir.Const{ .string = s },
            .boolean => Ir.Const{ .boolean = leaf.boolean },
            .int => Ir.Const{ .int = leaf.int },
            .float => Ir.Const{ .float = leaf.float },
        };
        const ret = try self.allocator.create(Ir);
        errdefer ret.deinit(self.allocator);
        ret.* = .{ .constant = v };
        return ret;
    }

    /// Build a deref on a symbol. This attempts to dereference the symbol from the function
    /// arguments and falls back to the global scope if the variable is not defined..
    fn buildDeref(self: *IrBuilder, symbol: []const u8) Error!*Ir {
        const ret = try self.allocator.create(Ir);
        errdefer ret.deinit(self.allocator);
        ret.* = .{ .deref = symbol };
        return ret;
    }

    fn buildDefine(self: *IrBuilder, sym: *const Ast.Node, def: *const Ast.Node) Error!*Ir {
        const name = switch (sym.*) {
            .tree => return Error.SyntaxError,
            .leaf => |l| switch (l) {
                .identifier => |ident| ident,
                else => return Error.SyntaxError,
            },
        };
        var expr = try self.build(name, def);
        errdefer expr.deinit(self.allocator);
        const ret = try self.allocator.create(Ir);
        errdefer ret.deinit(self.allocator);
        ret.* = .{
            .define = .{
                .name = name,
                .expr = expr,
            },
        };
        return ret;
    }

    fn buildImportModule(self: *IrBuilder, path_expr: *const Ast.Node) Error!*Ir {
        const path = switch (path_expr.*) {
            .tree => return Error.SyntaxError,
            .leaf => |l| switch (l) {
                .string => |ident| ident,
                else => return Error.SyntaxError,
            },
        };
        const ret = try self.allocator.create(Ir);
        errdefer ret.deinit(self.allocator);
        ret.* = .{
            .import_module = .{
                .path = path,
            },
        };
        return ret;
    }

    /// Build an Ir containing a function call.
    fn buildFunctionCall(self: *IrBuilder, func_ast: *const Ast.Node, args_ast: []const Ast.Node) Error!*Ir {
        const function = try self.build("_", func_ast);
        errdefer function.deinit(self.allocator);
        var args = try std.ArrayListUnmanaged(*Ir).initCapacity(self.allocator, args_ast.len);
        errdefer args.deinit(self.allocator);
        errdefer for (args.items) |*a| a.*.deinit(self.allocator);
        for (args_ast) |*a| {
            args.appendAssumeCapacity(try self.build("_", a));
        }
        const ret = try self.allocator.create(Ir);
        ret.* = .{ .function_call = .{
            .function = function,
            .args = try args.toOwnedSlice(self.allocator),
        } };
        return ret;
    }

    /// Build an Ir containing a function call.
    fn buildIfExpression(self: *IrBuilder, pred_expr: *const Ast.Node, true_expr: *const Ast.Node, false_expr: ?*const Ast.Node) Error!*Ir {
        const pred_ir = try self.build("_", pred_expr);
        errdefer pred_ir.deinit(self.allocator);

        const true_ir = try self.build("_", true_expr);
        errdefer true_ir.deinit(self.allocator);

        const false_ir = if (false_expr) |e| try self.build("_", e) else null;
        errdefer if (false_ir) |i| i.deinit(self.allocator);

        const ret = try self.allocator.create(Ir);
        ret.* = .{ .if_expr = .{
            .predicate = pred_ir,
            .true_expr = true_ir,
            .false_expr = false_ir,
        } };
        return ret;
    }

    /// Build an Ir containing a lambda definition.
    fn buildLambdaExpr(self: *IrBuilder, name: []const u8, arguments: *const Ast.Node, body: []const Ast.Node) Error!*Ir {
        if (body.len == 0) {
            return Error.SyntaxError;
        }
        var lambda_builder = IrBuilder{
            .allocator = self.allocator,
            .arg_to_idx = .{},
        };
        defer lambda_builder.deinit();
        switch (arguments.*) {
            .leaf => return Error.SyntaxError,
            .tree => |t| {
                for (0.., t) |arg_idx, arg_name_ast| {
                    switch (arg_name_ast) {
                        .tree => return Error.SyntaxError,
                        .leaf => |l| switch (l) {
                            .identifier => |ident| try lambda_builder.arg_to_idx.put(self.allocator, ident, arg_idx),
                            else => return Error.SyntaxError,
                        },
                    }
                }
            },
        }
        var exprs = try self.allocator.alloc(*Ir, body.len);
        errdefer self.allocator.free(exprs);
        for (0.., body) |i, *b| {
            const expr = try lambda_builder.build("_", b);
            errdefer expr.deinit(self.allocator);
            exprs[i] = expr;
        }

        const ret = try self.allocator.create(Ir);
        ret.* = .{ .lambda = .{
            .name = name,
            .args = try self.allocator.alloc([]const u8, lambda_builder.arg_to_idx.size),
            .exprs = exprs,
        } };
        var args_iter = lambda_builder.arg_to_idx.iterator();
        while (args_iter.next()) |entry| ret.lambda.args[entry.value_ptr.*] = entry.key_ptr.*;
        return ret;
    }
};

test "parse constant expression" {
    var actual = try Ir.initStrExpr(std.testing.allocator, "1");
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(
        &Ir{
            .ret = .{
                .exprs = @constCast(&[_]*Ir{
                    @constCast(&Ir{ .constant = .{ .int = 1 } }),
                }),
            },
        },
        actual,
    );
}

test "parse simple expression" {
    var actual = try Ir.initStrExpr(std.testing.allocator, "(+ 1 2)");
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(&Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .function_call = .{
                        .function = @constCast(&Ir{ .deref = "+" }),
                        .args = @constCast(&[_]*Ir{
                            @constCast(&Ir{ .constant = .{ .int = 1 } }),
                            @constCast(&Ir{ .constant = .{ .int = 2 } }),
                        }),
                    },
                }),
            }),
        },
    }, actual);
}

test "parse define statement" {
    var actual = try Ir.initStrExpr(std.testing.allocator, "(define x 12)");
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(&Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .define = .{
                        .name = "x",
                        .expr = @constCast(&Ir{ .constant = .{ .int = 12 } }),
                    },
                }),
            }),
        },
    }, actual);
}

test "parse if expression" {
    var actual = try Ir.initStrExpr(std.testing.allocator, "(if true 1 2)");
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(&Ir{ .ret = .{
        .exprs = @constCast(&[_]*Ir{
            @constCast(&Ir{
                .if_expr = .{
                    .predicate = @constCast(&Ir{ .constant = .{ .boolean = true } }),
                    .true_expr = @constCast(&Ir{ .constant = .{ .int = 1 } }),
                    .false_expr = @constCast(&Ir{ .constant = .{ .int = 2 } }),
                },
            }),
        }),
    } }, actual);
}

test "parse if expression with no false branch" {
    var actual = try Ir.initStrExpr(std.testing.allocator, "(if true 1)");
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(&Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .if_expr = .{
                        .predicate = @constCast(&Ir{ .constant = .{ .boolean = true } }),
                        .true_expr = @constCast(&Ir{ .constant = .{ .int = 1 } }),
                        .false_expr = null,
                    },
                }),
            }),
        },
    }, actual);
}

test "parse lambda" {
    var actual = try Ir.initStrExpr(std.testing.allocator, "(lambda (a b) (+ a b) (- a b))");
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(&Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .lambda = .{
                        .name = "_",
                        .args = @constCast(&[_][]const u8{ "a", "b" }),
                        .exprs = @constCast(&[_]*Ir{
                            @constCast(&Ir{
                                .function_call = .{
                                    .function = @constCast(&Ir{ .deref = "+" }),
                                    .args = @constCast(&[_]*Ir{
                                        @constCast(&Ir{ .deref = "a" }),
                                        @constCast(&Ir{ .deref = "b" }),
                                    }),
                                },
                            }),
                            @constCast(&Ir{
                                .function_call = .{
                                    .function = @constCast(&Ir{ .deref = "-" }),
                                    .args = @constCast(&[_]*Ir{
                                        @constCast(&Ir{ .deref = "a" }),
                                        @constCast(&Ir{ .deref = "b" }),
                                    }),
                                },
                            }),
                        }),
                    },
                }),
            }),
        },
    }, actual);
}

test "lambda with no body produces error" {
    try std.testing.expectError(error.SyntaxError, Ir.initStrExpr(std.testing.allocator, "(lambda (a b))"));
}

test "lambda with no arguments produces error" {
    try std.testing.expectError(error.SyntaxError, Ir.initStrExpr(std.testing.allocator, "(lambda)"));
}

test "lambda with improper args produces error" {
    var works = try Ir.initStrExpr(std.testing.allocator, "(lambda () true)");
    works.deinit(std.testing.allocator);
    try std.testing.expectError(error.SyntaxError, Ir.initStrExpr(std.testing.allocator, "(lambda not-a-list true)"));
}

test "define on lambda produces named function" {
    var actual = try Ir.initStrExpr(std.testing.allocator, "(define foo (lambda () (lambda () 10)))");
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(&Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .define = .{ .name = "foo", .expr = @constCast(&Ir{
                        .lambda = .{
                            .name = "foo",
                            .args = &.{},
                            .exprs = @constCast(&[_]*Ir{
                                @constCast(&Ir{
                                    .lambda = .{
                                        .name = "_",
                                        .args = &.{},
                                        .exprs = @constCast(&[_]*Ir{
                                            @constCast(&Ir{ .constant = .{ .int = 10 } }),
                                        }),
                                    },
                                }),
                            }),
                        },
                    }) },
                }),
            }),
        },
    }, actual);
}

test "nested lambda with error produces error" {
    try std.testing.expectError(Ir.Error.SyntaxError, Ir.initStrExpr(std.testing.allocator, "(define foo (lambda () (lambda ())))"));
}

test "definedVals visits all defined values" {
    const ir = &Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .define = .{
                        .name = "foo",
                        .expr = @constCast(&Ir{
                            .constant = .{ .int = 1 },
                        }),
                    },
                }),
                @constCast(&Ir{
                    .define = .{
                        .name = "bar",
                        .expr = @constCast(&Ir{
                            .constant = .{ .int = 2 },
                        }),
                    },
                }),
            }),
        },
    };
    var actual = std.StringHashMap(void).init(std.testing.allocator);
    defer actual.deinit();
    try ir.definedVals(&actual);
    try std.testing.expectEqual(2, actual.count());
    try std.testing.expect(actual.contains("foo"));
    try std.testing.expect(actual.contains("bar"));
}
