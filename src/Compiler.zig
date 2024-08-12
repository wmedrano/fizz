const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;
const Compiler = @This();
const Vm = @import("vm.zig").Vm;

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The virtual machine to compile for.
vm: *Vm,
/// The arguments that are in scope.
args: [][]const u8 = &.{},

/// Create a new ByteCode from the Ir.
pub fn compile(self: *Compiler, ir: *const Ir) !Val {
    var irs = [1]*const Ir{ir};
    const bc = try self.compileImpl(&irs);
    return .{ .bytecode = bc };
}

fn compileImpl(self: *Compiler, irs: []const *const Ir) Allocator.Error!*ByteCode {
    const bc = try self.vm.memory_manager.allocateByteCode();
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

fn addIr(self: *Compiler, bc: *ByteCode, ir: *const Ir) Allocator.Error!void {
    switch (ir.*) {
        .constant => |c| {
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .push_const = try c.toVal(&self.vm.memory_manager) },
            );
        },
        .define => |def| {
            try bc.instructions.append(
                self.vm.memory_manager.allocator,
                .{ .push_const = self.vm.getVal("%define") orelse @panic("builtin %define not available") },
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
        .deref => |s| {
            if (self.argIdx(s)) |arg_idx| {
                try bc.instructions.append(self.vm.memory_manager.allocator, .{ .get_arg = arg_idx });
            } else {
                try bc.instructions.append(
                    self.vm.memory_manager.allocator,
                    .{ .deref = try self.vm.memory_manager.allocator.dupe(u8, s) },
                );
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
    var compiler = Compiler{ .vm = &vm };
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .arg_count = 0,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = .{ .boolean = true } },
                    .{ .jump_if = 2 },
                    .{ .push_const = .{ .int = 2 } },
                    .{ .jump = 1 },
                    .{ .push_const = .{ .int = 1 } },
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
    var compiler = Compiler{ .vm = &vm };
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .arg_count = 0,
            .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
                .items = @constCast(&[_]ByteCode.Instruction{
                    .{ .push_const = .{ .boolean = true } },
                    .{ .jump_if = 2 },
                    .{ .push_const = .none },
                    .{ .jump = 1 },
                    .{ .push_const = .{ .int = 1 } },
                }),
                .capacity = actual.bytecode.instructions.capacity,
            },
        }),
    }, actual);
}
