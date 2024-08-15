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

    const Tag = std.meta.Tag(Val);

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

    pub fn eq(self: Val, other: Val) bool {
        return std.meta.eql(self, other);
    }

    pub fn hash(self: Val) void {
        var hasher = std.hash.Wyhash.init(0);
        self.hashImpl(&hasher);
        return hasher.final();
    }

    fn hashImpl(self: Val, hasher: *std.hash.Wyhash) void {
        hasher.update(&[1]u8{@as(Tag, self)});
        switch (self) {
            .none => {},
            .boolean => |b| hasher.update(&[_]u8{if (b) 1 else 0}),
            .int => |i| hasher.update(std.mem.asBytes(&i)),
            .float => |f| hasher.update(std.mem.asBytes(&f)),
            .string => |s| hasher.update(s),
            .symbol => |s| hasher.update(s),
            .list => |lst| for (lst) |lstv| lstv.hashImpl(hasher),
            .bytecode => |bc| hasher.update(std.mem.asBytes(&bc)),
            .native_fn => |nf| hasher.update(std.mem.asBytes(&nf.impl)),
        }
    }
};

test "val size is ok" {
    try std.testing.expectEqual(3 * @sizeOf(usize), @sizeOf(Val));
}

test "val eq" {
    try std.testing.expect((Val{ .int = 10 }).eq(Val{ .int = 10 }));

    const list_a = Val{
        .list = @constCast(&[_]Val{
            .{ .int = 1 },
            .{ .int = 2 },
        }),
    };
    const list_b = Val{
        .list = @constCast(&[_]Val{
            .{ .int = 1 },
            .{ .int = 2 },
        }),
    };
    try std.testing.expect(list_a.eq(list_b));
}
