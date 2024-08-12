const std = @import("std");
const ByteCode = @import("ByteCode.zig");
const Vm = @import("Vm.zig");

pub const Val = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    symbol: []const u8,
    list: []Val,
    bytecode: *ByteCode,
    native_fn: NativeFn,

    pub const NativeFn = struct {
        pub const Error = error{
            ArrityError,
            TypeError,
            RuntimeError,
        };

        impl: *const fn (*Vm, []const Val) Error!Val,
    };

    pub const empty_list: Val = Val{ .list = &[0]Val{} };

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
