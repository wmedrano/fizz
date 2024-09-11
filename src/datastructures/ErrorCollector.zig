const ErrorCollector = @This();
const std = @import("std");

errors: std.ArrayList([]const u8),

pub fn init(alloc: std.mem.Allocator) ErrorCollector {
    @setCold(true);
    return .{
        .errors = std.ArrayList([]const u8).init(alloc),
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
    for (self.errors.items) |msg| {
        self.errors.allocator.free(msg);
    }
    self.errors.clearRetainingCapacity();
}

pub fn addError(self: *ErrorCollector, comptime fmt: []const u8, args: anytype) !void {
    @setCold(true);
    const msg = try std.fmt.allocPrint(self.allocator(), fmt, args);
    try self.errors.append(msg);
}

pub fn format(self: *const ErrorCollector, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    @setCold(true);
    for (self.errors.items) |err| {
        try writer.print("{any}\n", .{err});
    }
}
