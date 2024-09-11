const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;
const Symbol = Val.Symbol;
const Compiler = @This();
const Env = @import("Env.zig");
const Vm = @import("Vm.zig");
const ScopeManager = @import("datastructures/ScopeManager.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

const Error = std.mem.Allocator.Error || error{ CompilerBug, BadSyntax };

/// The environment for the virtual machine to compile for.
env: *Env,

/// Manage variable scopes.
scopes: ScopeManager,

/// If the compilation is at the top level. This enables special behavior such as:
///   - Define statements set global values.
is_toplevel: bool = false,

/// Initialize a compiler for a function.
pub fn initFunction(allocator: std.mem.Allocator, env: *Env, args: []const []const u8) !Compiler {
    const scopes = try ScopeManager.initWithArgs(allocator, args);
    return .{
        .env = env,
        .scopes = scopes,
        .is_toplevel = false,
    };
}

/// Initialize a compiler for an expression.
pub fn init(allocator: std.mem.Allocator, env: *Env) !Compiler {
    return .{
        .env = env,
        .scopes = try ScopeManager.init(allocator),
        .is_toplevel = true,
    };
}

/// Deinitialize the compiler.
pub fn deinit(self: *Compiler) void {
    self.scopes.deinit();
}

/// Create a new ByteCode from the Ir.
pub fn compile(self: *Compiler, ir: *const Ir) !Val {
    var irs = [1]*const Ir{ir};
    const bc = try self.compileImpl(&irs);
    if (bc.instructions.items.len == 0 or bc.instructions.items[bc.instructions.items.len - 1].tag() != .ret) {
        try bc.instructions.append(self.env.memory_manager.allocator, .ret);
    }
    return .{ .bytecode = bc };
}

fn compileImpl(self: *Compiler, irs: []const *const Ir) Error!*ByteCode {
    const bc = try self.env.memory_manager.allocateByteCode();
    bc.arg_count = self.scopes.scopes.items[0].symbols.items.len;
    for (irs) |ir| try self.addIr(bc, ir);
    bc.locals_count = self.scopes.next_idx - bc.arg_count;
    return bc;
}

const StackAction = enum {
    /// Does nothing to the stack.
    none,
    /// Pushes to the stack.
    push,
    /// Returns from the current stack frame, thereby invalidating the current local stack.
    ret,
};

/// Returns true if `ir` pushes onto the stack.
fn computeStackAction(_: *const Compiler, ir: *const Ir) StackAction {
    return switch (ir.*) {
        .constant => .push,
        .define => .none,
        .deref => .push,
        .function_call => .push,
        .if_expr => .push,
        .lambda => .push,
        .ret => .ret,
    };
}

/// Compile instructions to `bc` from `ir`.
fn addIr(self: *Compiler, bc: *ByteCode, ir: *const Ir) Error!void {
    const is_toplevel = self.is_toplevel;
    // Top level IR consist of the form: Ir{ .ret = <exprs> } where top level <exprs> may call
    // `define` to `define` something at the global level.
    if (@as(Ir.Tag, ir.*) != Ir.Tag.ret) {
        self.is_toplevel = false;
    }
    defer self.is_toplevel = is_toplevel;
    switch (ir.*) {
        .constant => |c| {
            try bc.instructions.append(
                self.env.memory_manager.allocator,
                .{ .push_const = try c.toVal(&self.env.memory_manager) },
            );
        },
        .define => |def| {
            if (self.computeStackAction(def.expr) != .push) return Error.BadSyntax;
            if (is_toplevel) {
                const sym = try self.env.memory_manager.allocateSymbol(def.name);
                try self.addIr(bc, def.expr);
                try bc.instructions.append(
                    self.env.memory_manager.allocator,
                    .{ .define = sym },
                );
            } else {
                const local_idx = try self.scopes.addVariable(def.name);
                try self.addIr(bc, def.expr);
                try bc.instructions.append(
                    self.env.memory_manager.allocator,
                    .{ .move = local_idx },
                );
            }
        },
        .deref => |s| {
            if (self.scopes.variableIdx(s)) |var_idx| {
                try bc.instructions.append(self.env.memory_manager.allocator, .{ .get_arg = var_idx });
            } else {
                const sym = try self.env.memory_manager.allocateSymbol(s);
                try bc.instructions.append(self.env.memory_manager.allocator, .{ .deref_global = sym });
            }
        },
        .function_call => |f| {
            if (self.computeStackAction(f.function) == .none) return Error.BadSyntax;
            try self.addIr(bc, f.function);
            var eval_count: usize = 1;
            for (f.args) |arg| {
                if (self.computeStackAction(arg) == .push) eval_count += 1;
                try self.addIr(bc, arg);
            }
            try bc.instructions.append(
                self.env.memory_manager.allocator,
                .{ .eval = eval_count },
            );
        },
        .if_expr => |expr| {
            if (self.computeStackAction(expr.predicate) == .none) return Error.BadSyntax;
            if (self.computeStackAction(expr.true_expr) == .none) return Error.BadSyntax;
            if (expr.false_expr) |fe| if (self.computeStackAction(fe) == .none) return Error.BadSyntax;
            const scope_count = self.scopes.scopeCount();
            try self.addIr(bc, expr.predicate);
            self.scopes.retainScopes(scope_count) catch return Error.CompilerBug;
            var true_bc = try self.compileImpl((&expr.true_expr)[0..1]);
            self.scopes.retainScopes(scope_count) catch return Error.CompilerBug;
            var false_bc = if (expr.false_expr) |f|
                try self.compileImpl(
                    (&f)[0..1],
                )
            else
                try self.compileImpl(&[_]*const Ir{&Ir{ .constant = .none }});
            self.scopes.retainScopes(scope_count) catch return Error.CompilerBug;
            try bc.instructions.append(
                self.env.memory_manager.allocator,
                .{ .jump_if = false_bc.instructions.items.len + 1 },
            );
            try bc.instructions.appendSlice(self.env.memory_manager.allocator, false_bc.instructions.items);
            false_bc.instructions.items.len = 0;
            try bc.instructions.append(
                self.env.memory_manager.allocator,
                .{ .jump = true_bc.instructions.items.len },
            );
            try bc.instructions.appendSlice(self.env.memory_manager.allocator, true_bc.instructions.items);
            true_bc.instructions.items.len = 0;
        },
        .lambda => |l| {
            const old_scopes = self.scopes;
            defer self.scopes = old_scopes;
            self.scopes = try ScopeManager.initWithArgs(self.scopes.allocator, l.args);
            defer self.scopes.deinit();
            const lambda_bc = try self.compileImpl(l.exprs);
            try lambda_bc.instructions.append(self.env.memory_manager.allocator, .ret);
            try bc.instructions.append(
                self.env.memory_manager.allocator,
                .{ .push_const = .{ .bytecode = lambda_bc } },
            );
        },
        .ret => |r| {
            for (r.exprs) |e| try self.addIr(bc, e);
            try bc.instructions.append(self.env.memory_manager.allocator, .ret);
        },
    }
}

test "if expression" {
    const ir = Ir{
        .if_expr = .{
            .predicate = @constCast(&Ir{ .constant = .{ .boolean = true } }),
            .true_expr = @constCast(&Ir{ .constant = .{ .int = 1 } }),
            .false_expr = @constCast(&Ir{ .constant = .{ .int = 2 } }),
        },
    };
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.init(std.testing.allocator, &vm.env);
    defer compiler.deinit();
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
            .locals_count = 0,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = .{ .boolean = true } },
                    .{ .jump_if = 2 },
                    .{ .push_const = .{ .int = 2 } },
                    .{ .jump = 1 },
                    .{ .push_const = .{ .int = 1 } },
                    .ret,
                }),
                .capacity = actual.bytecode.instructions.capacity,
            },
        }),
    }, actual);
}

test "if expression without false branch returns none" {
    const ir = Ir{
        .if_expr = .{
            .predicate = @constCast(&Ir{ .constant = .{ .boolean = true } }),
            .true_expr = @constCast(&Ir{ .constant = .{ .int = 1 } }),
            .false_expr = null,
        },
    };
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.init(std.testing.allocator, &vm.env);
    defer compiler.deinit();
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
            .locals_count = 0,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = .{ .boolean = true } },
                    .{ .jump_if = 2 },
                    .{ .push_const = .none },
                    .{ .jump = 1 },
                    .{ .push_const = .{ .int = 1 } },
                    .ret,
                }),
                .capacity = actual.bytecode.instructions.capacity,
            },
        }),
    }, actual);
}

test "toplevel expression with define expressions" {
    const ir = Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .define = .{
                        .name = "pi",
                        .expr = @constCast(&Ir{ .constant = .{ .float = 3.14 } }),
                    },
                }),
                @constCast(&Ir{
                    .define = .{
                        .name = "e",
                        .expr = @constCast(&Ir{ .constant = .{ .float = 2.718 } }),
                    },
                }),
            }),
        },
    };
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.init(std.testing.allocator, &vm.env);
    defer compiler.deinit();
    const actual = try compiler.compile(&ir);
    const pi_symbol = try vm.env.memory_manager.allocateSymbol("pi");
    const e_symbol = try vm.env.memory_manager.allocateSymbol("e");
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
            .locals_count = 0,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = .{ .float = 3.14 } },
                    .{ .define = pi_symbol },
                    .{ .push_const = .{ .float = 2.718 } },
                    .{ .define = e_symbol },
                    .ret,
                }),
                .capacity = actual.bytecode.instructions.capacity,
            },
        }),
    }, actual);
}

test "define outside of global scope creates stack local" {
    const ir = Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .define = .{
                        .name = "pi",
                        .expr = @constCast(&Ir{ .constant = .{ .float = 3.14 } }),
                    },
                }),
                @constCast(&Ir{
                    .define = .{
                        .name = "2pi",
                        .expr = @constCast(&Ir{ .constant = .{ .float = 6.28 } }),
                    },
                }),
            }),
        },
    };
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.initFunction(std.testing.allocator, &vm.env, &.{});
    defer compiler.deinit();

    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
            .locals_count = 2,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = .{ .float = 3.14 } },
                    .{ .move = 0 },
                    .{ .push_const = .{ .float = 6.28 } },
                    .{ .move = 1 },
                    .ret,
                }),
                .capacity = actual.bytecode.instructions.capacity,
            },
        }),
    }, actual);
}

test "define in bad context produces error" {
    const ir = Ir{
        .if_expr = .{
            .predicate = @constCast(&Ir{
                .define = .{
                    .name = "pi",
                    .expr = @constCast(&Ir{ .constant = .{ .float = 3.14 } }),
                },
            }),
            .true_expr = @constCast(&Ir{ .constant = .{ .int = 1 } }),
            .false_expr = null,
        },
    };
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.init(std.testing.allocator, &vm.env);
    defer compiler.deinit();
    try std.testing.expectError(Error.BadSyntax, compiler.compile(&ir));
}
