const std = @import("std");

pub fn EmptyIter(comptime T: type) type {
    return struct {
        const Self = @This();
        pub inline fn next(_: *const Self) ?T {
            return null;
        }
    };
}

pub fn SlicesIter(comptime T: type) type {
    return struct {
        const Self = @This();
        slice: []const T = &[0]T{},

        pub fn init(slice: []const T) Self {
            return .{ .slice = slice };
        }

        pub fn next(self: *Self) ?T {
            if (self.slice.len == 0) {
                return null;
            }
            const ret = self.slice[0];
            self.slice.ptr += 1;
            self.slice.len -= 1;
            return ret;
        }
    };
}

test "iterate slices produces all slices" {
    const array = [_]usize{ 1, 2, 3 };
    var iter = SlicesIter(usize).init(&array);
    try std.testing.expectEqual(1, iter.next());
    try std.testing.expectEqual(2, iter.next());
    try std.testing.expectEqual(3, iter.next());
    try std.testing.expectEqual(null, iter.next());
    try std.testing.expectEqual(null, iter.next());
}

test "default iterator produces no values" {
    var iter = SlicesIter(usize){};
    try std.testing.expectEqual(null, iter.next());
    try std.testing.expectEqual(null, iter.next());
}
