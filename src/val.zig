const std = @import("std");
const ByteCode = @import("ByteCode.zig");
const Environment = @import("Environment.zig");

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

        impl: *const fn (*Environment, []const Val) Error!Val,
    };

    pub const empty_list: Val = Val{ .list = &[0]Val{} };

    pub fn format(self: Val, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .none => try writer.print("none", .{}),
            .boolean => |v| try writer.print("{any}", .{v}),
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |v| try writer.print("\"{s}\"", .{v}),
            .symbol => |v| try writer.print("'{s}", .{v}),
            .list => |lst| {
                try writer.print("(", .{});
                for (lst, 0..lst.len) |v, idx| {
                    if (idx > 0) try writer.print(" {any}", .{v}) else try writer.print("{any}", .{v});
                }
                try writer.print(")", .{});
            },
            .bytecode => |v| try writer.print("<function {s}>", .{v.name}),
            .native_fn => |v| try writer.print("<function native{*}>", .{v.impl}),
        }
    }

    /// Get the tag for value.
    pub fn tag(self: Val) Tag {
        return @as(Tag, self);
    }

    pub fn asBool(self: Val) !bool {
        switch (self) {
            .boolean => |b| return b,
            else => return error.TypeError,
        }
    }
};

test "val size is ok" {
    try std.testing.expectEqual(3 * @sizeOf(usize), @sizeOf(Val));
}
