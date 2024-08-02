const std = @import("std");
const Bytecode = @import("ByteCode.zig");

pub const Val = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    symbol: []const u8,
    bytecode: *const Bytecode,

    pub fn initBoolean(b: bool) Val {
        return .{ .boolean = b };
    }

    pub fn initInt(v: i64) Val {
        return .{ .int = v };
    }

    pub fn initFloat(v: f64) Val {
        return .{ .float = v };
    }

    pub fn initString(allocator: std.mem.Allocator, s: []const u8) !Val {
        return .{ .string = try allocator.dupe(u8, s) };
    }

    pub fn initSymbol(allocator: std.mem.Allocator, s: []const u8) !Val {
        return .{ .symbol = try allocator.dupe(u8, s) };
    }

    pub fn requiresHeap(self: Val) bool {
        switch (self.*) {
            .string => return true,
            .symbol => return true,
            .bytecode => return true,
            else => return false,
        }
    }

    pub fn deinit(self: *Val, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .symbol => |s| allocator.free(s),
            .bytecode => |bc| @constCast(bc).deinit(),
            else => std.debug.assert(!self.requiresHeap()),
        }
    }

    pub fn clone(self: Val, allocator: std.mem.Allocator) !Val {
        switch (self) {
            .string => |s| return Val.initString(allocator, s),
            .symbol => |s| return Val.initSymbol(allocator, s),
            else => return self,
        }
    }

    pub fn isTruthy(self: Val) !bool {
        switch (self) {
            .boolean => |b| return b,
            else => return error.TypeError,
        }
    }

    pub fn asByteCode(self: Val) !*const Bytecode {
        switch (self) {
            .bytecode => |bc| return bc,
            else => return error.TypeError,
        }
    }
};

test "val size is ok" {
    try std.testing.expectEqual(3 * @sizeOf(usize), @sizeOf(Val));
}

test "can create new string" {
    const test_string = "test-string";
    var v = try Val.initString(std.testing.allocator, test_string);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(Val{ .string = "test-string" }, v);
}
