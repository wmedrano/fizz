const std = @import("std");
const ByteCode = @import("ByteCode.zig");
const Vm = @import("Vm.zig");
const MemoryManager = @import("MemoryManager.zig");

pub const Val = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    symbol: usize,
    list: []Val,
    structV: *std.AutoHashMapUnmanaged(usize, Val),
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

    pub const Formatter = struct {
        val: Val,
        memory_manager: ?*const MemoryManager,

        pub fn format(self: *const Formatter, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            return self.formatImpl(writer, self.val);
        }

        fn formatImpl(self: *const Formatter, writer: anytype, val: Val) !void {
            switch (val) {
                .none => try writer.writeAll("none"),
                .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
                .int => |i| try std.fmt.format(writer, "{d}", .{i}),
                .float => |f| try std.fmt.format(writer, "{d}", .{f}),
                .string => |s| {
                    try writer.writeAll("\"");
                    try writer.writeAll(s);
                    try writer.writeAll("\"");
                },
                .symbol => |sym_id| {
                    if (self.memory_manager) |mm| {
                        if (mm.id_to_symbol.get(sym_id)) |s| {
                            try std.fmt.format(writer, "'{s}", .{s});
                            return;
                        }
                    }
                    try std.fmt.format(writer, "'symbol-#{d}", .{sym_id});
                },
                .list => |lst| {
                    try writer.writeAll("(");
                    for (lst, 0..) |v, idx| {
                        if (idx > 0) try writer.writeAll(" ");
                        try self.formatImpl(writer, v);
                    }
                    try writer.writeAll(")");
                },
                .structV => |struct_map| {
                    var iter = struct_map.iterator();
                    try writer.writeAll("(struct");
                    while (iter.next()) |v| {
                        try writer.writeAll(" ");
                        try self.formatImpl(writer, .{ .symbol = v.key_ptr.* });
                        try writer.writeAll(" ");
                        try self.formatImpl(writer, v.value_ptr.*);
                    }
                    try writer.writeAll(")");
                },
                .bytecode => |bc| try std.fmt.format(
                    writer,
                    "<function {s}>",
                    .{if (bc.name.len == 0) "_" else bc.name},
                ),
                .native_fn => |nf| try std.fmt.format(writer, "<native-func #{d}>", .{@intFromPtr(nf.impl)}),
            }
        }
    };

    pub const empty_list: Val = Val{ .list = &[0]Val{} };

    /// Create a new formatter. This allows printing Val objects. For better fidelity, pass in the
    /// `Vm`.
    pub fn formatter(self: Val, vm: ?*const Vm) Formatter {
        if (vm) |ptr| return .{ .val = self, .memory_manager = &ptr.env.memory_manager };
        return .{ .val = self, .memory_manager = null };
    }

    pub fn format(self: Val, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("warning: Try Val.formatter for better Val formatting.\n{any}", .{self.formatter(null)});
    }

    /// Get the tag for value.
    pub fn tag(self: Val) Tag {
        return @as(Tag, self);
    }

    /// Returns true if the value is none.
    pub fn isNone(self: Val) bool {
        return self.tag() == Tag.none;
    }

    /// Get the value as a bool.
    pub fn asBool(self: Val) !bool {
        switch (self) {
            .boolean => |b| return b,
            else => return error.TypeError,
        }
    }

    /// Get the value as an int.
    pub fn asInt(self: Val) !i64 {
        switch (self) {
            .int => |i| return i,
            else => return error.TypeError,
        }
    }

    /// Get the value as an f64. Val may be a float or an int.
    pub fn asFloat(self: Val) !f64 {
        switch (self) {
            .float => |f| return f,
            .int => |i| return @as(f64, @floatFromInt(i)),
            else => return error.TypeError,
        }
    }
};

test "val size is ok" {
    // TODO: Reduce the size of val to 2 words.
    try std.testing.expectEqual(3 * @sizeOf(usize), @sizeOf(Val));
}
