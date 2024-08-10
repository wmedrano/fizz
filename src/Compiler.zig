const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;
const Compiler = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

memory_manager: *MemoryManager,

/// Create a new ByteCode from the Ir.
pub fn compile(self: *Compiler, ir: *const Ir) !Val {
    var irs = [1]*const Ir{ir};
    const bc = try self.compileImpl(&irs);
    return .{ .bytecode = bc };
}

fn compileImpl(self: *Compiler, irs: []const *const Ir) Allocator.Error!*ByteCode {
    const bc = try self.memory_manager.allocateByteCode();
    for (irs) |ir| try self.addIr(bc, ir);
    return bc;
}

fn addIr(self: *Compiler, bc: *ByteCode, ir: *const Ir) Allocator.Error!void {
    switch (ir.*) {
        .constant => |c| {
            try bc.instructions.append(
                self.memory_manager.allocator,
                .{ .push_const = try c.toVal(self.memory_manager) },
            );
        },
        .deref => |s| {
            try bc.instructions.append(
                self.memory_manager.allocator,
                .{ .deref = try self.memory_manager.allocator.dupe(u8, s) },
            );
        },
        .get_arg => |n| {
            try bc.instructions.append(
                self.memory_manager.allocator,
                .{ .get_arg = n },
            );
        },
        .function_call => |f| {
            try self.addIr(bc, f.function);
            for (f.args) |arg| try self.addIr(bc, arg);
            try bc.instructions.append(
                self.memory_manager.allocator,
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
                self.memory_manager.allocator,
                .{ .jump_if = false_bc.instructions.items.len + 1 },
            );
            try bc.instructions.appendSlice(self.memory_manager.allocator, false_bc.instructions.items);
            false_bc.instructions.items.len = 0;
            try bc.instructions.append(
                self.memory_manager.allocator,
                .{ .jump = true_bc.instructions.items.len },
            );
            try bc.instructions.appendSlice(self.memory_manager.allocator, true_bc.instructions.items);
            true_bc.instructions.items.len = 0;
        },
        .lambda => |l| {
            const lambda_bc = try self.compileImpl(l.exprs);
            try lambda_bc.instructions.append(self.memory_manager.allocator, .ret);
            try bc.instructions.append(
                self.memory_manager.allocator,
                .{ .push_const = .{ .bytecode = lambda_bc } },
            );
        },
        .ret => |r| {
            for (r.exprs) |e| try self.addIr(bc, e);
            try bc.instructions.append(self.memory_manager.allocator, .ret);
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
    var memory_manager = MemoryManager.init(std.testing.allocator);
    defer memory_manager.deinit();
    var compiler = Compiler{ .memory_manager = &memory_manager };
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
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
    var memory_manager = MemoryManager.init(std.testing.allocator);
    defer memory_manager.deinit();
    var compiler = Compiler{ .memory_manager = &memory_manager };
    const actual = try compiler.compile(&ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
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
