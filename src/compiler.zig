const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Create a new ByteCode from the Ir.
pub fn compile(memory_manager: *MemoryManager, ir: *const Ir) !Val {
    var irs = [1]*const Ir{ir};
    const bc = try compileImpl(memory_manager, &irs);
    return .{ .bytecode = bc };
}

fn compileImpl(memory_manager: *MemoryManager, irs: []const *const Ir) Allocator.Error!*ByteCode {
    var bc = try memory_manager.allocateByteCode();
    const instruction_count = instructionCounts(irs);
    try bc.instructions.ensureTotalCapacity(memory_manager.allocator, instruction_count);
    for (irs) |ir| try addIr(bc, memory_manager, ir);
    return bc;
}

inline fn instructionCounts(irs: []const *const Ir) usize {
    var cnt: usize = 0;
    for (irs) |ir| cnt += instructionCount(ir);
    return cnt;
}

fn instructionCount(ir: *const Ir) usize {
    switch (ir.*) {
        .constant => return 1,
        .deref => return 1,
        .get_arg => return 1,
        .function_call => |f| {
            // 1 is for the eval instruction.
            var cnt = 1 + instructionCount(f.function);
            for (f.args) |arg| cnt += instructionCount(arg);
            return cnt;
        },
        .if_expr => |expr| {
            // 2 for a jump instruction in each the true and false branch.
            var cnt = 2 + instructionCount(expr.predicate) + instructionCount(expr.true_expr);
            if (expr.false_expr) |f| {
                cnt += instructionCount(f);
            } else {
                cnt += 1;
            }
            return cnt;
        },
        .lambda => return 1,
        .ret => |r| {
            var cnt: usize = 1;
            for (r.exprs) |e| cnt += instructionCount(e);
            return cnt;
        },
    }
}

fn addIr(bc: *ByteCode, memory_manager: *MemoryManager, ir: *const Ir) Allocator.Error!void {
    switch (ir.*) {
        .constant => |c| {
            try bc.instructions.append(
                memory_manager.allocator,
                .{ .push_const = try c.toVal(memory_manager) },
            );
        },
        .deref => |s| {
            try bc.instructions.append(
                memory_manager.allocator,
                .{ .deref = try memory_manager.allocator.dupe(u8, s) },
            );
        },
        .get_arg => |n| {
            try bc.instructions.append(
                memory_manager.allocator,
                .{ .get_arg = n },
            );
        },
        .function_call => |f| {
            try addIr(bc, memory_manager, f.function);
            for (f.args) |arg| try addIr(bc, memory_manager, arg);
            try bc.instructions.append(
                memory_manager.allocator,
                .{ .eval = f.args.len + 1 },
            );
        },
        .if_expr => |expr| {
            try addIr(bc, memory_manager, expr.predicate);
            var true_bc = try compileImpl(memory_manager, (&expr.true_expr)[0..1]);
            var false_bc = if (expr.false_expr) |f|
                try compileImpl(
                    memory_manager,
                    (&f)[0..1],
                )
            else
                try compileImpl(memory_manager, &[_]*const Ir{&Ir{ .constant = .none }});
            try bc.instructions.append(
                memory_manager.allocator,
                .{ .jump_if = false_bc.instructions.items.len + 1 },
            );
            try bc.instructions.appendSlice(memory_manager.allocator, false_bc.instructions.items);
            false_bc.instructions.items.len = 0;
            try bc.instructions.append(
                memory_manager.allocator,
                .{ .jump = true_bc.instructions.items.len },
            );
            try bc.instructions.appendSlice(memory_manager.allocator, true_bc.instructions.items);
            true_bc.instructions.items.len = 0;
        },
        .lambda => |l| {
            const lambda_bc = try compileImpl(memory_manager, l.exprs);
            try lambda_bc.instructions.append(memory_manager.allocator, .ret);
            try bc.instructions.append(
                memory_manager.allocator,
                .{ .push_const = .{ .bytecode = lambda_bc } },
            );
        },
        .ret => |r| {
            for (r.exprs) |e| try addIr(bc, memory_manager, e);
            try bc.instructions.append(memory_manager.allocator, .ret);
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
    const actual = try compile(&memory_manager, &ir);
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
    const actual = try compile(&memory_manager, &ir);
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
