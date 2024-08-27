const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;
const Compiler = @This();
const Environment = @import("Environment.zig");
const Module = @import("Module.zig");
const ScopeManager = @import("compiler/ScopeManager.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

const Error = std.mem.Allocator.Error || error{ CompilerBug, BadSyntax };

/// The virtual machine to compile for.
env: *Environment,

/// Manage variable scopes.
scopes: ScopeManager,

/// The module that the code is under.
module: *Module,
/// If a module is being compiled. This enables special behavior such as:
///   - Define statements set values within the module.
is_module: bool = false,
/// The values that are defined in `module`.
module_defined_vals: std.StringHashMap(void),

/// Initialize a compiler for a function that lives inside `module`.
pub fn initFunction(allocator: std.mem.Allocator, env: *Environment, module: *Module, args: []const []const u8) !Compiler {
    var module_defined_vals = std.StringHashMap(void).init(allocator);
    var module_definitions = module.values.keyIterator();
    while (module_definitions.next()) |def| try module_defined_vals.put(def.*, {});
    const scopes = try ScopeManager.initWithArgs(allocator, args);
    return .{
        .env = env,
        .scopes = scopes,
        .module = module,
        .is_module = false,
        .module_defined_vals = module_defined_vals,
    };
}

/// Initialize a compiler for a module definition.
pub fn initModule(allocator: std.mem.Allocator, env: *Environment, module: *Module) !Compiler {
    var module_defined_vals = std.StringHashMap(void).init(allocator);
    var module_definitions = module.values.keyIterator();
    while (module_definitions.next()) |def| try module_defined_vals.put(def.*, {});
    return .{
        .env = env,
        .scopes = try ScopeManager.init(allocator),
        .module = module,
        .is_module = true,
        .module_defined_vals = module_defined_vals,
    };
}

/// Deinitialize the compiler.
pub fn deinit(self: *Compiler) void {
    self.module_defined_vals.deinit();
    self.scopes.deinit();
}

/// Create a new ByteCode from the Ir.
pub fn compile(self: *Compiler, ir: *const Ir) !Val {
    var irs = [1]*const Ir{ir};
    if (self.is_module) {
        try ir.populateDefinedVals(&self.module_defined_vals);
    }
    const bc = try self.compileImpl(&irs);
    if (bc.instructions.items.len == 0 or bc.instructions.items[bc.instructions.items.len - 1].tag() != .ret) {
        try bc.instructions.append(self.env.allocator(), .ret);
    }
    return .{ .bytecode = bc };
}

fn compileImpl(self: *Compiler, irs: []const *const Ir) Error!*ByteCode {
    const bc = try self.env.memory_manager.allocateByteCode(self.module);
    bc.arg_count = self.scopes.scopes.items[0].symbols.items.len;
    for (irs) |ir| try self.addIr(bc, ir);
    bc.locals_count = self.scopes.next_idx - bc.arg_count;
    return bc;
}

/// Returns true if `ir` pushes onto the stack.
fn pushesToStack(_: *const Compiler, ir: *const Ir) bool {
    return switch (ir.*) {
        .define => false,
        .ret => false,
        .import_module => false,
        else => true,
    };
}

/// Compile instructions to `bc` from `ir`.
fn addIr(self: *Compiler, bc: *ByteCode, ir: *const Ir) Error!void {
    const is_module = self.is_module;
    // Modules consist of the form: Ir{ .ret = <exprs> } where top level <exprs> may call `define`
    // to `define` something at the module level.
    if (@as(Ir.Tag, ir.*) != Ir.Tag.ret) {
        self.is_module = false;
    }
    defer self.is_module = is_module;
    switch (ir.*) {
        .constant => |c| {
            try bc.instructions.append(
                self.env.allocator(),
                .{ .push_const = try c.toVal(&self.env.memory_manager) },
            );
        },
        .define => |def| {
            if (is_module) {
                try bc.instructions.append(
                    self.env.allocator(),
                    .{ .push_const = self.env.global_module.getVal("*define*") orelse @panic("builtin *define* not available") },
                );
                try bc.instructions.append(
                    self.env.allocator(),
                    .{ .push_const = try self.env.memory_manager.allocateSymbolVal(def.name) },
                );
                try self.addIr(bc, def.expr);
                try bc.instructions.appendSlice(
                    self.env.allocator(),
                    // A pop is needed as pushesToStack returns false for define.
                    &[_]ByteCode.Instruction{ .{ .eval = 3 }, .pop },
                );
            } else {
                const local_idx = try self.scopes.addVariable(def.name);
                try self.addIr(bc, def.expr);
                try bc.instructions.append(
                    self.env.allocator(),
                    .{ .move = local_idx },
                );
            }
        },
        .import_module => |m| {
            if (!is_module) {
                return Error.BadSyntax;
            }
            try bc.instructions.append(
                self.env.allocator(),
                .{ .import_module = try self.env.allocator().dupe(u8, m.path) },
            );
        },
        .deref => |s| {
            if (self.scopes.variableIdx(s)) |var_idx| {
                try bc.instructions.append(self.env.allocator(), .{ .get_arg = var_idx });
            } else {
                const sym = try self.env.allocator().dupe(u8, s);
                const parsed_sym = Module.parseModuleAndSymbol(sym);
                if (self.module_defined_vals.contains(s) or parsed_sym.module_alias != null) {
                    try bc.instructions.append(self.env.allocator(), .{ .deref_local = sym });
                } else {
                    try bc.instructions.append(self.env.allocator(), .{ .deref_global = sym });
                }
            }
        },
        .function_call => |f| {
            try self.addIr(bc, f.function);
            var eval_count: usize = 1;
            for (f.args) |arg| {
                if (self.pushesToStack(arg)) eval_count += 1;
                try self.addIr(bc, arg);
            }
            try bc.instructions.append(
                self.env.allocator(),
                .{ .eval = eval_count },
            );
        },
        .if_expr => |expr| {
            if (!self.pushesToStack(expr.predicate)) return Error.BadSyntax;
            if (!self.pushesToStack(expr.true_expr)) return Error.BadSyntax;
            if (expr.false_expr) |fe| if (!self.pushesToStack(fe)) return Error.BadSyntax;
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
                self.env.allocator(),
                .{ .jump_if = false_bc.instructions.items.len + 1 },
            );
            try bc.instructions.appendSlice(self.env.allocator(), false_bc.instructions.items);
            false_bc.instructions.items.len = 0;
            try bc.instructions.append(
                self.env.allocator(),
                .{ .jump = true_bc.instructions.items.len },
            );
            try bc.instructions.appendSlice(self.env.allocator(), true_bc.instructions.items);
            true_bc.instructions.items.len = 0;
        },
        .lambda => |l| {
            const old_scopes = self.scopes;
            defer self.scopes = old_scopes;
            self.scopes = try ScopeManager.initWithArgs(self.scopes.allocator, l.args);
            defer self.scopes.deinit();
            const lambda_bc = try self.compileImpl(l.exprs);
            try lambda_bc.instructions.append(self.env.allocator(), .ret);
            try bc.instructions.append(
                self.env.allocator(),
                .{ .push_const = .{ .bytecode = lambda_bc } },
            );
        },
        .ret => |r| {
            for (r.exprs) |e| try self.addIr(bc, e);
            try bc.instructions.append(self.env.allocator(), .ret);
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
    var env = try Environment.init(std.testing.allocator);
    defer env.deinit();
    var compiler = try Compiler.initModule(std.testing.allocator, &env, try env.getOrCreateModule(.{}));
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
            .module = env.getModule(Module.Builder.default_name).?,
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
    var env = try Environment.init(std.testing.allocator);
    defer env.deinit();
    var compiler = try Compiler.initModule(std.testing.allocator, &env, try env.getOrCreateModule(.{}));
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
            .module = env.getModule(Module.Builder.default_name).?,
        }),
    }, actual);
}

test "module with define expressions" {
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
    var env = try Environment.init(std.testing.allocator);
    defer env.deinit();
    var compiler = try Compiler.initModule(std.testing.allocator, &env, try env.getOrCreateModule(.{}));
    defer compiler.deinit();
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
            .locals_count = 0,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = env.global_module.getVal("*define*").? },
                    .{ .push_const = try env.memory_manager.allocateSymbolVal("pi") },
                    .{ .push_const = .{ .float = 3.14 } },
                    .{ .eval = 3 },
                    .pop,
                    .{ .push_const = env.global_module.getVal("*define*").? },
                    .{ .push_const = try env.memory_manager.allocateSymbolVal("e") },
                    .{ .push_const = .{ .float = 2.718 } },
                    .{ .eval = 3 },
                    .pop,
                    .ret,
                }),
                .capacity = actual.bytecode.instructions.capacity,
            },
            .module = env.getModule(Module.Builder.default_name).?,
        }),
    }, actual);
}

test "define outside of module creates stack local" {
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
    var env = try Environment.init(std.testing.allocator);
    defer env.deinit();
    var compiler = try Compiler.initFunction(std.testing.allocator, &env, try env.getOrCreateModule(.{}), &.{});
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
            .module = env.getModule(Module.Builder.default_name).?,
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
    var vm = try Environment.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.initModule(std.testing.allocator, &vm, try vm.getOrCreateModule(.{}));
    defer compiler.deinit();
    try std.testing.expectError(Error.BadSyntax, compiler.compile(&ir));
}
