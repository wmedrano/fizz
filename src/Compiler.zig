const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;
const Compiler = @This();
const Vm = @import("Vm.zig");
const Module = @import("Module.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

const Error = std.mem.Allocator.Error || error{BadSyntax};

/// The virtual machine to compile for.
vm: *Vm,
/// The arguments that are in scope.
args: [][]const u8,
/// The module that the code is under.
module: *Module,
/// If a module is being compiled. This enables special behavior such as:
///   - Define statements set values within the module.
is_module: bool = false,
/// The values that are defined by the Ir. This is populated when calling compile and is only valid
/// when is_module is true.
defined_vals: std.StringHashMap(void),

/// Initialize a compiler for a function that lives inside `module`.
pub fn initFunction(allocator: std.mem.Allocator, vm: *Vm, module: *Module, args: [][]const u8) !Compiler {
    var defined_vals = std.StringHashMap(void).init(allocator);
    var module_definitions = module.values.keyIterator();
    while (module_definitions.next()) |def| try defined_vals.put(def.*, {});
    return .{
        .vm = vm,
        .args = args,
        .module = module,
        .is_module = false,
        .defined_vals = defined_vals,
    };
}

/// Initialize a compiler for a module definition.
pub fn initModule(allocator: std.mem.Allocator, vm: *Vm, module: *Module) !Compiler {
    var defined_vals = std.StringHashMap(void).init(allocator);
    var module_definitions = module.values.keyIterator();
    while (module_definitions.next()) |def| try defined_vals.put(def.*, {});
    return .{
        .vm = vm,
        .args = &.{},
        .module = module,
        .is_module = true,
        .defined_vals = defined_vals,
    };
}

/// Deinitialize the compiler.
pub fn deinit(self: *Compiler) void {
    self.defined_vals.deinit();
}

/// Create a new ByteCode from the Ir.
pub fn compile(self: *Compiler, ir: *const Ir) !Val {
    var irs = [1]*const Ir{ir};
    if (self.is_module) {
        try ir.definedVals(&self.defined_vals);
    }
    const bc = try self.compileImpl(&irs);
    if (bc.instructions.items.len == 0 or bc.instructions.items[bc.instructions.items.len - 1].tag() != .ret) {
        try bc.instructions.append(self.vm.memory_manager.allocator, .ret);
    }
    return .{ .bytecode = bc };
}

fn compileImpl(self: *Compiler, irs: []const *const Ir) Error!*ByteCode {
    const bc = try self.vm.memory_manager.allocateByteCode(self.module);
    bc.arg_count = self.args.len;
    for (irs) |ir| try self.addIr(bc, ir);
    return bc;
}

fn argIdx(self: *const Compiler, arg_name: []const u8) ?usize {
    for (0..self.args.len, self.args) |idx, arg| {
        if (std.mem.eql(u8, arg_name, arg)) return idx;
    }
    return null;
}

fn addIr(self: *Compiler, bc: *ByteCode, ir: *const Ir) Error!void {
    const is_module = self.is_module;
    if (@as(Ir.Tag, ir.*) != Ir.Tag.ret) {
        self.is_module = false;
    }
    defer self.is_module = is_module;
    switch (ir.*) {
        .constant => |c| {
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .push_const = try c.toVal(&self.vm.memory_manager) },
            );
        },
        .define => |def| {
            if (!is_module) {
                return Error.BadSyntax;
            }
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .push_const = self.vm.global_module.getVal("%define%") orelse @panic("builtin %define% not available") },
            );
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .push_const = try self.vm.memory_manager.allocateSymbolVal(def.name) },
            );
            try self.addIr(bc, def.expr);
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .eval = 3 },
            );
        },
        .import_module => |m| {
            if (!is_module) {
                return Error.BadSyntax;
            }
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .import_module = try self.vm.memory_manager.allocator.dupe(u8, m.path) },
            );
        },
        .deref => |s| {
            if (self.argIdx(s)) |arg_idx| {
                try bc.instructions.append(self.vm.memory_manager.allocator, .{ .get_arg = arg_idx });
            } else {
                const sym = try self.vm.memory_manager.allocator.dupe(u8, s);
                if (self.defined_vals.contains(s)) {
                    try bc.instructions.append(self.vm.memory_manager.allocator, .{ .deref_local = sym });
                } else {
                    try bc.instructions.append(self.vm.memory_manager.allocator, .{ .deref_global = sym });
                }
            }
        },
        .function_call => |f| {
            try self.addIr(bc, f.function);
            for (f.args) |arg| try self.addIr(bc, arg);
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .eval = f.args.len + 1 },
            );
        },
        .if_expr => |expr| {
            try self.addIr(bc, expr.predicate);
            var true_bc = try self.compileImpl((&expr.true_expr)[0..1]);
            var false_bc = if (expr.false_expr) |f|
                try self.compileImpl(
                    (&f)[0..1],
                )
            else
                try self.compileImpl(&[_]*const Ir{&Ir{ .constant = .none }});
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .jump_if = false_bc.instructions.items.len + 1 },
            );
            try bc.instructions.appendSlice(self.vm.memory_manager.allocator, false_bc.instructions.items);
            false_bc.instructions.items.len = 0;
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .jump = true_bc.instructions.items.len },
            );
            try bc.instructions.appendSlice(self.vm.memory_manager.allocator, true_bc.instructions.items);
            true_bc.instructions.items.len = 0;
        },
        .lambda => |l| {
            const old_args = self.args;
            defer self.args = old_args;
            self.args = l.args;
            const lambda_bc = try self.compileImpl(l.exprs);
            try lambda_bc.instructions.append(self.vm.memory_manager.allocator, .ret);
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .push_const = .{ .bytecode = lambda_bc } },
            );
        },
        .ret => |r| {
            for (r.exprs) |e| try self.addIr(bc, e);
            try bc.instructions.append(self.vm.memory_manager.allocator, .ret);
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
    var compiler = try Compiler.initModule(std.testing.allocator, &vm, try vm.getOrCreateModule("%test%"));
    defer compiler.deinit();
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
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
            .module = vm.getModule("%test%").?,
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
    var compiler = try Compiler.initModule(std.testing.allocator, &vm, try vm.getOrCreateModule("%test%"));
    defer compiler.deinit();
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
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
            .module = vm.getModule("%test%").?,
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
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.initModule(std.testing.allocator, &vm, try vm.getOrCreateModule("%test%"));
    defer compiler.deinit();
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .name = "",
            .arg_count = 0,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = vm.global_module.getVal("%define%").? },
                    .{ .push_const = try vm.memory_manager.allocateSymbolVal("pi") },
                    .{ .push_const = .{ .float = 3.14 } },
                    .{ .eval = 3 },
                    .{ .push_const = vm.global_module.getVal("%define%").? },
                    .{ .push_const = try vm.memory_manager.allocateSymbolVal("e") },
                    .{ .push_const = .{ .float = 2.718 } },
                    .{ .eval = 3 },
                    .ret,
                }),
                .capacity = actual.bytecode.instructions.capacity,
            },
            .module = vm.getModule("%test%").?,
        }),
    }, actual);
}

test "define outside of module produces error" {
    const ir = Ir{
        .ret = .{
            .exprs = @constCast(&[_]*Ir{
                @constCast(&Ir{
                    .define = .{
                        .name = "pi",
                        .expr = @constCast(&Ir{ .constant = .{ .float = 3.14 } }),
                    },
                }),
            }),
        },
    };
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.initFunction(std.testing.allocator, &vm, try vm.getOrCreateModule("%test%"), &.{});
    defer compiler.deinit();
    try std.testing.expectError(Error.BadSyntax, compiler.compile(&ir));
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
    var compiler = try Compiler.initModule(std.testing.allocator, &vm, try vm.getOrCreateModule("%test%"));
    defer compiler.deinit();
    try std.testing.expectError(Error.BadSyntax, compiler.compile(&ir));
}
