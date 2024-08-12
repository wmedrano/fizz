const ByteCode = @This();
const Val = @import("val.zig").Val;
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

name: []const u8,
arg_count: usize,
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
                .unwrap_list => {},
                .ret => {},
            }
        }
        return null;
    }
};

pub fn deinit(self: *ByteCode, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    for (self.instructions.items) |i| {
        switch (i) {
            .deref => |sym| allocator.free(sym),
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
        "{{ .name = {s}, .arg_count = {d}, .instructions = {any} }}",
        .{ self.name, self.arg_count, self.instructions.items },
    );
}

pub fn iterateVals(self: *const ByteCode) ByteCodeValuesIter {
    return .{
        .instructions = self.instructions.items,
    };
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
    /// Take the last item (must be a list) on the stack and unwrap its contents.
    unwrap_list,
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
    pub fn format(
        self: *const Instruction,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self.*) {
            .push_const => |v| try writer.print("push_const({any})", .{v}),
            .deref => |sym| try writer.print("deref({s})", .{sym}),
            .get_arg => |n| try writer.print("get_arg({d})", .{n}),
            .eval => |n| try writer.print("eval({d})", .{n}),
            .jump => |n| try writer.print("jump({d})", .{n}),
            .jump_if => |n| try writer.print("jump_if({d})", .{n}),
            .unwrap_list => try writer.print("unwrap_list()", .{}),
            .ret => try writer.print("ret()", .{}),
        }
    }
};
