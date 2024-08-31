const ErrorCollector = @This();
const std = @import("std");

errors: std.ArrayList(Error),

pub const Error = union(enum) {
    msg: []const u8,

    pub fn format(self: *const Error, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}\n", .{self.msg});
    }
};

pub fn init(alloc: std.mem.Allocator) ErrorCollector {
    @setCold(true);
    return .{
        .errors = std.ArrayList(Error).init(alloc),
    };
}

pub fn deinit(self: *ErrorCollector) void {
    @setCold(true);
    self.clear();
    self.errors.deinit();
}

pub fn allocator(self: *ErrorCollector) std.mem.Allocator {
    @setCold(true);
    return self.errors.allocator;
}

pub fn clear(self: *ErrorCollector) void {
    @setCold(true);
    for (self.errors.items) |err| {
        switch (err) {
            .msg => |msg| self.errors.allocator.free(msg),
        }
    }
    self.errors.clearRetainingCapacity();
}

pub fn addError(self: *ErrorCollector, err: Error) !void {
    @setCold(true);
    const err_copy = Error{
        .msg = try self.errors.allocator.dupe(u8, err.msg),
    };
    try self.addErrorOwned(err_copy);
}

pub fn addErrorOwned(self: *ErrorCollector, err: Error) !void {
    @setCold(true);
    try self.errors.append(err);
}

pub fn format(self: *const ErrorCollector, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    @setCold(true);
    for (self.errors.items) |err| {
        try writer.print("{any}\n", .{err});
    }
}
