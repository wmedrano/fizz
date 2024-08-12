const MemoryManager = @This();
const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");

const std = @import("std");

allocator: std.mem.Allocator,
reachable_color: Color,
strings: std.StringHashMapUnmanaged(Color),
lists: std.AutoHashMapUnmanaged([*]Val, LenAndColor),
bytecode: std.AutoHashMapUnmanaged(*ByteCode, Color),

const LenAndColor = struct {
    len: usize,
    color: Color,
};

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
        .strings = .{},
        .lists = .{},
        .bytecode = .{},
    };
}

pub fn deinit(self: *MemoryManager) void {
    self.sweep() catch {};
    self.sweep() catch {};
    self.strings.deinit(self.allocator);
    self.lists.deinit(self.allocator);
    self.bytecode.deinit(self.allocator);
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

pub fn allocateList(self: *MemoryManager, contents: []const Val) ![]Val {
    if (contents.len == 0) {
        return &[0]Val{};
    }
    var lst = try self.allocator.alloc(Val, contents.len);
    for (0..contents.len) |idx| lst[idx] = contents[idx];
    try self.lists.put(self.allocator, lst.ptr, .{ .len = contents.len, .color = self.reachable_color });
    return lst;
}

pub fn allocateListVal(self: *MemoryManager, contents: []const Val) !Val {
    return .{ .list = try self.allocateList(contents) };
}

pub fn allocateByteCode(self: *MemoryManager) !*ByteCode {
    const bc = try self.allocator.create(ByteCode);
    try self.bytecode.put(self.allocator, bc, self.reachable_color);
    bc.* = ByteCode{
        .name = "",
        .arg_count = 0,
        .instructions = .{},
    };
    return bc;
}

pub fn markVal(self: *MemoryManager, v: Val) !void {
    switch (v) {
        .string => |s| try self.strings.put(self.allocator, s, self.reachable_color),
        .symbol => |s| try self.strings.put(self.allocator, s, self.reachable_color),
        .list => |lst| {
            if (self.lists.getEntry(lst.ptr)) |entry| {
                if (entry.value_ptr.color == self.reachable_color) return;
                entry.value_ptr.color = self.reachable_color;
            } else {
                try self.lists.put(self.allocator, lst.ptr, .{ .len = lst.len, .color = self.reachable_color });
            }
            for (lst) |child_val| try self.markVal(child_val);
        },
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
    var strings_iter = self.strings.iterator();
    while (strings_iter.next()) |entry| {
        if (entry.value_ptr.* != self.reachable_color) {
            self.allocator.free(entry.key_ptr.*);
            self.strings.removeByPtr(entry.key_ptr);
        }
    }

    var lists_iter = self.lists.iterator();
    while (lists_iter.next()) |entry| {
        if (entry.value_ptr.color != self.reachable_color) {
            const lst = entry.key_ptr.*[0..entry.value_ptr.len];
            self.allocator.free(lst);
            self.lists.removeByPtr(entry.key_ptr);
        }
    }

    var bytecode_iter = self.bytecode.iterator();
    while (bytecode_iter.next()) |entry| {
        if (entry.value_ptr.* != self.reachable_color) {
            ByteCode.deinit(entry.key_ptr.*, self.allocator);
            self.bytecode.removeByPtr(entry.key_ptr);
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

    const test_str = "different pointers";
    try std.testing.expect(
        test_str.ptr !=
            (try memory_manager.allocateString(test_str)).ptr,
    );
}
