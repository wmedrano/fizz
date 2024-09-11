const ByteCode = @This();
const Symbol = Val.Symbol;
const Val = @import("val.zig").Val;
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

name: []const u8,
arg_count: usize,
locals_count: usize,
instructions: std.ArrayListUnmanaged(Instruction),

pub fn deinit(self: *ByteCode, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    for (self.instructions.items) |i| {
        switch (i) {
            else => {},
        }
    }
    self.instructions.deinit(allocator);
    allocator.destroy(self);
}

/// Pretty print the AST.
pub fn format(
    self: *const ByteCode,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print(
        "{{ .name = {s}, .arg_count = {d}, .locals_count = {d}, .instructions =\n",
        .{ self.name, self.arg_count, self.locals_count },
    );
    for (self.instructions.items, 0..self.instructions.items.len) |instruction, idx| {
        try writer.print("  {d}: {any}\n", .{ idx, instruction });
    }
}

const ByteCodeValuesIter = struct {
    instructions: []const ByteCode.Instruction,

    pub fn next(self: *ByteCodeValuesIter) ?Val {
        while (self.instructions.len > 0) {
            const instruction = self.instructions[0];
            self.instructions.ptr += 1;
            self.instructions.len -= 1;
            switch (instruction) {
                .push_const => |v| return v,
                .deref_global => {},
                .get_arg => {},
                .define => {},
                .move => {},
                .eval => {},
                .jump => {},
                .jump_if => {},
                .ret => {},
            }
        }
        return null;
    }
};

/// Returns an iterater over all values referenced by the bytecode.
pub fn iterateVals(self: *const ByteCode) ByteCodeValuesIter {
    return .{
        .instructions = self.instructions.items,
    };
}

/// Contains a single instruction that can be run by the Vm.
pub const Instruction = union(enum) {
    /// Push a constant onto the stack.
    push_const: Val,
    /// Dereference a global symbol.
    deref_global: Symbol,
    /// Get the nth value (0-based index) from the base of the current function call stack.
    get_arg: usize,
    /// Define a symbol on the current module.
    define: Symbol,
    /// Move the top value of the stack into the given index.
    move: usize,
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

    /// The enum associated with the instruction.
    const Tag = std.meta.Tag(Instruction);

    /// Get the tag associated with the instruction.
    pub fn tag(self: *const Instruction) Tag {
        return @as(Instruction.Tag, self.*);
    }

    /// Pretty print the AST.
    pub fn format(
        self: *const Instruction,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self.*) {
            .push_const => |v| try writer.print("push_const({any})", .{v}),
            .deref_global => |sym| try writer.print("deref_global({d})", .{sym.id}),
            .get_arg => |n| try writer.print("get_arg({d})", .{n}),
            .move => |n| try writer.print("move({d})", .{n}),
            .eval => |n| try writer.print("eval({d})", .{n}),
            .jump => |n| try writer.print("jump({d})", .{n}),
            .jump_if => |n| try writer.print("jump_if({d})", .{n}),
            .ret => try writer.print("ret()", .{}),
            .define => |sym| try writer.print("define({d})", .{sym.id}),
        }
    }
};

test "instruction is small" {
    try std.testing.expectEqual(@sizeOf(usize) * 4, @sizeOf(Instruction));
}
