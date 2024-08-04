const ByteCode = @This();
const Val = @import("val.zig").Val;
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

instructions: std.ArrayListUnmanaged(Instruction),

const ByteCodeValuesIter = struct {
    instructions: []const ByteCode.Instruction,

    pub fn next(self: *ByteCodeValuesIter) ?Val {
        while (self.instructions.len > 0) {
            const instruction = self.instructions[0];
            self.instructions.ptr += 1;
            self.instructions.len -= 1;
            switch (instruction) {
                .push_const => |v| return v,
                .deref => {},
                .get_arg => {},
                .eval => {},
                .jump => {},
                .jump_if => {},
                .ret => {},
            }
        }
        return null;
    }
};

pub fn deinit(self: *ByteCode, allocator: std.mem.Allocator) void {
    for (self.instructions.items) |i| {
        switch (i) {
            .deref => |sym| allocator.free(sym),
            else => {},
        }
    }
    self.instructions.deinit(allocator);
    allocator.destroy(self);
}

pub fn iterateVals(self: *const ByteCode) ByteCodeValuesIter {
    return .{
        .instructions = self.instructions.items,
    };
}

/// Create a new ByteCode from the Ir.
pub fn init(memory_manager: *MemoryManager, ir: *const Ir) !Val {
    var irs = [1]*const Ir{ir};
    const bc = try initImpl(memory_manager, &irs);
    return .{ .bytecode = bc };
}

pub fn initStrExpr(allocator: Allocator, expr: []const u8) !Val {
    var ir = try Ir.initStrExpr(allocator, expr);
    defer ir.deinit(allocator);
    return ByteCode.init(allocator, ir);
}

fn initImpl(memory_manager: *MemoryManager, irs: []const *const Ir) Allocator.Error!*ByteCode {
    var self = try memory_manager.allocateByteCode();
    for (irs) |ir| try self.initAddIr(memory_manager, ir);
    return self;
}

fn initAddIr(self: *ByteCode, memory_manager: *MemoryManager, ir: *const Ir) Allocator.Error!void {
    switch (ir.*) {
        .constant => |c| {
            try self.instructions.append(
                memory_manager.allocator,
                .{ .push_const = try c.toVal(memory_manager) },
            );
        },
        .deref => |s| {
            try self.instructions.append(
                memory_manager.allocator,
                .{ .deref = try memory_manager.allocator.dupe(u8, s) },
            );
        },
        .get_arg => |n| {
            try self.instructions.append(
                memory_manager.allocator,
                .{ .get_arg = n },
            );
        },
        .function_call => |f| {
            try self.initAddIr(memory_manager, f.function);
            for (f.args) |arg| try self.initAddIr(memory_manager, arg);
            try self.instructions.append(
                memory_manager.allocator,
                .{ .eval = f.args.len + 1 },
            );
        },
        .if_expr => |expr| {
            try self.initAddIr(memory_manager, expr.predicate);
            var true_bc = try initImpl(memory_manager, (&expr.true_expr)[0..1]);
            var false_bc = if (expr.false_expr) |f|
                try initImpl(
                    memory_manager,
                    (&f)[0..1],
                )
            else
                try initImpl(memory_manager, &[_]*const Ir{&Ir{ .constant = .none }});
            try self.instructions.append(
                memory_manager.allocator,
                .{ .jump_if = false_bc.instructions.items.len + 1 },
            );
            try self.instructions.appendSlice(memory_manager.allocator, false_bc.instructions.items);
            false_bc.instructions.items.len = 0;
            try self.instructions.append(
                memory_manager.allocator,
                .{ .jump = true_bc.instructions.items.len },
            );
            try self.instructions.appendSlice(memory_manager.allocator, true_bc.instructions.items);
            true_bc.instructions.items.len = 0;
        },
        .lambda => |l| {
            const lambda_bc = try initImpl(memory_manager, l.exprs);
            try lambda_bc.instructions.append(memory_manager.allocator, .ret);
            try self.instructions.append(
                memory_manager.allocator,
                .{ .push_const = .{ .bytecode = lambda_bc } },
            );
        },
        .ret => |r| {
            for (r.exprs) |e| try self.initAddIr(memory_manager, e);
            try self.instructions.append(memory_manager.allocator, .ret);
        },
    }
}

/// Contains a single instruction that can be run by the Vm.
pub const Instruction = union(enum) {
    /// Push a constant onto the stack.
    push_const: Val,
    /// Dereference the symbol at push it onto the stack.
    deref: []const u8,
    /// Get the nth value (0-based index) from the base of the current function call stack.
    get_arg: usize,
    /// Evaluate the top n elements of the stack. The deepmost value should be a function.
    eval: usize,
    /// Jump instructions in the bytecode.
    jump: usize,
    /// Jump instructions in the bytecode if the top value of the stack is true.
    jump_if: usize,
    /// Return the top value of the stack. The following should occur:
    ///   1. The top value is the return_value.
    ///   2. All items on the current function stack are popped.
    ///   3. The top value of the previous function stack (which should be the function) is replaced
    ///      with the return_value.
    ret,

    pub fn deinit(self: *Instruction, allocator: Allocator) void {
        switch (self.*) {
            .deref => |s| allocator.free(s),
            else => {},
        }
    }

    /// Pretty print the AST.
    pub fn format(self: *const Instruction, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.*) {
            .push_const => |v| try writer.print("push_const({any})", .{v}),
            .deref => |sym| try writer.print("deref({s})", .{sym}),
            .get_arg => |n| try writer.print("get_arg({d})", .{n}),
            .eval => |n| try writer.print("eval({d})", .{n}),
            .jump => |n| try writer.print("jump({d})", .{n}),
            .jump_if => |n| try writer.print("jump_if({d})", .{n}),
            .ret => try writer.print("ret()", .{}),
        }
    }
};

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
    const actual = try ByteCode.init(&memory_manager, &ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .instructions = std.ArrayListUnmanaged(Instruction){
                .items = @constCast(&[_]Instruction{
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
    const actual = try ByteCode.init(&memory_manager, &ir);
    try std.testing.expectEqualDeep(Val{
        .bytecode = @constCast(&ByteCode{
            .instructions = std.ArrayListUnmanaged(Instruction){
                .items = @constCast(&[_]Instruction{
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
