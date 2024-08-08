const MemoryManager = @This();
const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");
const SlicesIter = @import("iter.zig").SlicesIter;

const std = @import("std");

allocator: std.mem.Allocator,
reachable_color: Color,
bytecode: std.AutoHashMapUnmanaged(*ByteCode, Color),
strings: std.StringHashMapUnmanaged(Color),

const Color = enum {
    red,
    blue,

    pub fn swap(self: Color) Color {
        switch (self) {
            .red => return .blue,
            .blue => return .red,
        }
    }
};

pub fn init(allocator: std.mem.Allocator) MemoryManager {
    return .{
        .allocator = allocator,
        .reachable_color = Color.red,
        .bytecode = .{},
        .strings = .{},
    };
}

pub fn deinit(self: *MemoryManager) void {
    self.sweep() catch {};
    self.sweep() catch {};
    self.strings.deinit(self.allocator);
    self.bytecode.deinit(self.allocator);
}

pub fn allocateByteCode(self: *MemoryManager) !*ByteCode {
    const bc = try self.allocator.create(ByteCode);
    try self.bytecode.put(self.allocator, bc, self.reachable_color);
    bc.* = ByteCode{
        .instructions = .{},
    };
    return bc;
}

pub fn allocateString(self: *MemoryManager, str: []const u8) ![]const u8 {
    if (self.strings.getEntry(str)) |entry| {
        return entry.key_ptr.*;
    }
    const str_copy = try self.allocator.dupe(u8, str);
    try self.strings.putNoClobber(self.allocator, str_copy, self.reachable_color);
    return str_copy;
}

pub fn allocateStringVal(self: *MemoryManager, str: []const u8) !Val {
    return .{ .string = try self.allocateString(str) };
}

pub fn allocateSymbolVal(self: *MemoryManager, sym: []const u8) !Val {
    return .{ .symbol = try self.allocateString(sym) };
}

pub fn markVal(self: *MemoryManager, v: Val) !void {
    switch (v) {
        .string => |s| try self.strings.put(self.allocator, s, self.reachable_color),
        .symbol => |s| try self.strings.put(self.allocator, s, self.reachable_color),
        .bytecode => |bc| {
            if (self.bytecode.getEntry(bc)) |entry| {
                if (entry.value_ptr.* == self.reachable_color) return;
                entry.value_ptr.* = self.reachable_color;
            } else {
                try self.bytecode.put(self.allocator, bc, self.reachable_color);
            }
            var vals_iter = bc.iterateVals();
            while (vals_iter.next()) |child_val| try self.markVal(child_val);
        },
        else => {},
    }
}

pub fn sweep(self: *MemoryManager) !void {
    var bytecode_iter = self.bytecode.iterator();
    while (bytecode_iter.next()) |entry| {
        if (entry.value_ptr.* != self.reachable_color) {
            ByteCode.deinit(entry.key_ptr.*, self.allocator);
            self.bytecode.removeByPtr(entry.key_ptr);
        }
    }

    var strings_iter = self.strings.iterator();
    while (strings_iter.next()) |entry| {
        if (entry.value_ptr.* != self.reachable_color) {
            self.allocator.free(entry.key_ptr.*);
            self.strings.removeByPtr(entry.key_ptr);
        }
    }

    self.reachable_color = self.reachable_color.swap();
}

test "no memory leaks" {
    var memory_manager = MemoryManager.init(std.testing.allocator);
    defer memory_manager.deinit();
    try memory_manager.markVal(.none);
    try memory_manager.sweep();
    try std.testing.expectEqualStrings("hello world", try memory_manager.allocateString("hello world"));
    try std.testing.expectError(
        error.TestExpectedEqual,
        std.testing.expectEqual("different pointers", try memory_manager.allocateString("different pointers")),
    );
}
