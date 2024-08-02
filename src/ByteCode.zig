const ByteCode = @This();
const Val = @import("val.zig").Val;
const Ir = @import("ir.zig").Ir;
const std = @import("std");
const Allocator = std.mem.Allocator;

allocator: Allocator,
instructions: std.ArrayListUnmanaged(Instruction),
is_heap_allocated: bool,

pub fn init(allocator: Allocator, ir: *const Ir) !*ByteCode {
    const bc = try allocator.create(ByteCode);
    errdefer allocator.destroy(bc);
    var irs = [1]*const Ir{ir};
    bc.* = try initImpl(allocator, &irs, true);
    bc.is_heap_allocated = true;
    return bc;
}

pub fn deinit(self: *ByteCode) void {
    for (self.instructions.items) |*i| i.deinit(self.allocator);
    self.instructions.deinit(self.allocator);
    if (self.is_heap_allocated) {
        self.allocator.destroy(self);
    }
}

fn initImpl(allocator: Allocator, irs: []const *const Ir, append_ret: bool) Allocator.Error!ByteCode {
    var self = ByteCode{
        .allocator = allocator,
        .instructions = std.ArrayListUnmanaged(Instruction){},
        .is_heap_allocated = false,
    };
    errdefer self.deinit();
    for (irs) |ir| try self.initAddIr(ir);
    if (append_ret) try self.instructions.append(self.allocator, .ret);
    return self;
}

fn initAddIr(self: *ByteCode, ir: *const Ir) Allocator.Error!void {
    switch (ir.*) {
        .constant => |c| {
            try self.instructions.append(
                self.allocator,
                .{ .push_const = try c.clone(self.allocator) },
            );
        },
        .deref => |s| {
            try self.instructions.append(
                self.allocator,
                .{ .deref = try self.allocator.dupe(u8, s) },
            );
        },
        .get_arg => |n| {
            try self.instructions.append(
                self.allocator,
                .{ .get_arg = n },
            );
        },
        .function_call => |f| {
            try self.initAddIr(f.function);
            for (f.args) |arg| try self.initAddIr(arg);
            try self.instructions.append(
                self.allocator,
                .{ .eval = f.args.len + 1 },
            );
        },
        .if_expr => |expr| {
            try self.initAddIr(expr.predicate);
            var true_bc = try initImpl(self.allocator, (&expr.true_expr)[0..1], false);
            defer true_bc.deinit();
            var false_bc = if (expr.false_expr) |f|
                try initImpl(self.allocator, (&f)[0..1], false)
            else
                try initImpl(self.allocator, &[_]*const Ir{&Ir{ .constant = .none }}, false);
            defer false_bc.deinit();
            try self.instructions.append(
                self.allocator,
                .{ .jump_if = false_bc.instructions.items.len + 1 },
            );
            try self.instructions.appendSlice(self.allocator, false_bc.instructions.items);
            false_bc.instructions.items.len = 0;
            try self.instructions.append(
                self.allocator,
                .{ .jump = true_bc.instructions.items.len },
            );
            try self.instructions.appendSlice(self.allocator, true_bc.instructions.items);
            true_bc.instructions.items.len = 0;
        },
        .lambda => |l| {
            const lambda_bc = try self.allocator.create(ByteCode);
            errdefer self.allocator.destroy(lambda_bc);
            lambda_bc.* = try initImpl(self.allocator, l.exprs, true);
            try self.instructions.append(
                self.allocator,
                .{ .push_const = .{ .bytecode = lambda_bc } },
            );
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
            .push_const => |*c| c.deinit(allocator),
            .deref => |s| allocator.free(s),
            else => {},
        }
    }
};

test "if expression" {
    const ir = Ir{
        .if_expr = .{
            .predicate = @constCast(&Ir{ .constant = Val.initBoolean(true) }),
            .true_expr = @constCast(&Ir{ .constant = Val.initInt(1) }),
            .false_expr = @constCast(&Ir{ .constant = Val.initInt(2) }),
        },
    };
    var actual = try ByteCode.init(std.testing.allocator, &ir);
    defer actual.deinit();
    try std.testing.expectEqualDeep(&ByteCode{
        .allocator = std.testing.allocator,
        .instructions = std.ArrayListUnmanaged(Instruction){
            .items = @constCast(&[_]Instruction{
                .{ .push_const = Val.initBoolean(true) },
                .{ .jump_if = 2 },
                .{ .push_const = Val.initInt(2) },
                .{ .jump = 1 },
                .{ .push_const = Val.initInt(1) },
                .ret,
            }),
            .capacity = actual.instructions.capacity,
        },
        .is_heap_allocated = true,
    }, actual);
}

test "if expression without false branch returns none" {
    const ir = Ir{
        .if_expr = .{
            .predicate = @constCast(&Ir{ .constant = Val.initBoolean(true) }),
            .true_expr = @constCast(&Ir{ .constant = Val.initInt(1) }),
            .false_expr = null,
        },
    };
    var actual = try ByteCode.init(std.testing.allocator, &ir);
    defer actual.deinit();
    try std.testing.expectEqualDeep(&ByteCode{
        .allocator = std.testing.allocator,
        .instructions = std.ArrayListUnmanaged(Instruction){
            .items = @constCast(&[_]Instruction{
                .{ .push_const = Val.initBoolean(true) },
                .{ .jump_if = 2 },
                .{ .push_const = .none },
                .{ .jump = 1 },
                .{ .push_const = Val.initInt(1) },
                .ret,
            }),
            .capacity = actual.instructions.capacity,
        },
        .is_heap_allocated = true,
    }, actual);
}
