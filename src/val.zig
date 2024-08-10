const std = @import("std");
const ByteCode = @import("ByteCode.zig");
const Vm = @import("vm.zig").Vm;

pub const Val = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    symbol: []const u8,
    bytecode: *ByteCode,
    native_fn: NativeFn,

    pub const NativeFn = struct {
        pub const Error = error{
            TypeError,
            RuntimeError,
        };

        impl: *const fn (*Vm, []const Val) Error!Val,
    };

    pub fn requiresHeap(self: Val) bool {
        switch (self) {
            .string => return true,
            .symbol => return true,
            .bytecode => return true,
            else => return false,
        }
    }

    pub fn asBool(self: Val) !bool {
        switch (self) {
            .boolean => |b| return b,
            else => return error.TypeError,
        }
    }

    pub fn asByteCode(self: Val) !*ByteCode {
        switch (self) {
            .bytecode => |bc| return bc,
            else => return error.TypeError,
        }
    }
};

test "val size is ok" {
    try std.testing.expectEqual(3 * @sizeOf(usize), @sizeOf(Val));
}
