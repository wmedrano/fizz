const MemoryManager = @This();
const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");
const Module = @import("Module.zig");

const std = @import("std");

/// The allocator used by all managed data.
allocator: std.mem.Allocator,
/// The color to tag all data that is reachable as opposed to unreachable. Unreachable data is
/// cleaned up for garbage collection.
reachable_color: Color = Color.red,

/// A map from symbol name to its id.
symbol_to_id: std.StringHashMapUnmanaged(usize) = .{},
/// A map from symbol id to its name.
id_to_symbol: std.AutoHashMapUnmanaged(usize, []const u8) = .{},
/// A map from an owned string to its reachable color.
strings: std.StringHashMapUnmanaged(Color) = .{},
/// A map from a struct pointer to its Color.
structs: std.AutoHashMapUnmanaged(*std.AutoHashMapUnmanaged(usize, Val), Color) = .{},
/// A map from an owned list pointer to its length and color.
lists: std.AutoHashMapUnmanaged([*]Val, LenAndColor) = .{},
/// A map from a bytecode pointer to its color.
bytecode: std.AutoHashMapUnmanaged(*ByteCode, Color) = .{},

keep_alive_strings: std.StringHashMapUnmanaged(usize) = .{},
keep_alive_structs: std.AutoHashMapUnmanaged(*std.AutoHashMapUnmanaged(usize, Val), usize) = .{},
keep_alive_lists: std.AutoHashMapUnmanaged([*]Val, usize) = .{},
keep_alive_bytecode: std.AutoHashMapUnmanaged(*ByteCode, usize) = .{},

/// Stores a length and a color.
const LenAndColor = struct {
    len: usize,
    color: Color,
};

/// Labels data with a color. Used for tagging data is reachable or unreachable for garbage
/// collection purposes.
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

/// Initialize a new memory manager.
pub fn init(allocator: std.mem.Allocator) MemoryManager {
    return .{
        .allocator = allocator,
    };
}

/// Deinitialize a memory manager.
pub fn deinit(self: *MemoryManager) void {
    self.sweep() catch {};
    self.sweep() catch {};

    var symbols_iter = self.symbol_to_id.keyIterator();
    while (symbols_iter.next()) |s| self.allocator.free(s.*);
    self.symbol_to_id.deinit(self.allocator);
    self.id_to_symbol.deinit(self.allocator);

    self.strings.deinit(self.allocator);
    self.structs.deinit(self.allocator);
    self.lists.deinit(self.allocator);
    self.bytecode.deinit(self.allocator);
    self.keep_alive_strings.deinit(self.allocator);
    self.keep_alive_structs.deinit(self.allocator);
    self.keep_alive_lists.deinit(self.allocator);
    self.keep_alive_bytecode.deinit(self.allocator);
}

/// Allocate a new string to be managed by the memory manager. If an equivalent string already
/// exists, it is returned instead. If not, then `str` is duplicated and added to the pool of
/// managed strings.
pub fn allocateString(self: *MemoryManager, str: []const u8) ![]const u8 {
    if (self.strings.getEntry(str)) |entry| {
        return entry.key_ptr.*;
    }
    const str_copy = try self.allocator.dupe(u8, str);
    try self.strings.put(
        self.allocator,
        str_copy,
        self.reachable_color.swap(),
    );
    return str_copy;
}

/// Create a new managed string `Val` from `str`.
pub fn allocateStringVal(self: *MemoryManager, str: []const u8) !Val {
    return .{ .string = try self.allocateString(str) };
}

/// Create a new symbol and return its id. If the symbol already exists, its id is returned.
pub fn allocateSymbol(self: *MemoryManager, sym: []const u8) !usize {
    if (self.symbolId(sym)) |id| return id;
    const new_id: usize = @intCast(self.symbol_to_id.count());
    const new_sym = try self.allocator.dupe(u8, sym);
    try self.symbol_to_id.put(self.allocator, new_sym, new_id);
    try self.id_to_symbol.put(self.allocator, new_id, new_sym);
    return new_id;
}

/// Get the id for a symbol or `null` if it has not been allocated.
pub fn symbolId(self: *const MemoryManager, sym: []const u8) ?usize {
    return self.symbol_to_id.get(sym);
}

/// Create a new managed symbol `Val` from `sym`.
pub fn allocateSymbolVal(self: *MemoryManager, sym: []const u8) !Val {
    return .{ .symbol = try self.allocateSymbol(sym) };
}

/// Allocate a new list of size `len`. All elements within the slice are uninitialized.
pub fn allocateListOfNone(self: *MemoryManager, len: usize) ![]Val {
    if (len == 0) {
        return &[0]Val{};
    }
    const lst = try self.allocator.alloc(Val, len);
    try self.lists.put(
        self.allocator,
        lst.ptr,
        .{ .len = len, .color = self.reachable_color.swap() },
    );
    for (0..len) |idx| lst[idx] = .none;
    return lst;
}

/// Allocate a new managed slice of `Val` duplicating that duplicates the values in `contents`.
pub fn allocateList(self: *MemoryManager, contents: []const Val) ![]Val {
    if (contents.len == 0) {
        return &[0]Val{};
    }
    var lst = try self.allocateListOfNone(contents.len);
    for (0..contents.len) |idx| lst[idx] = contents[idx];
    return lst;
}

/// Allocate a new `Val` of type list that duplicates `contents`.
pub fn allocateListVal(self: *MemoryManager, contents: []const Val) !Val {
    return .{ .list = try self.allocateList(contents) };
}

/// Allocate a new bytecode object.
pub fn allocateByteCode(self: *MemoryManager, module: *Module) !*ByteCode {
    const bc = try self.allocator.create(ByteCode);
    try self.bytecode.put(self.allocator, bc, self.reachable_color.swap());
    bc.* = ByteCode{
        .name = "",
        .arg_count = 0,
        .locals_count = 0,
        .instructions = .{},
        .module = module,
    };
    return bc;
}

/// Allocate a new empty struct.
pub fn allocateStruct(self: *MemoryManager) !*std.AutoHashMapUnmanaged(usize, Val) {
    const m = try self.allocator.create(std.AutoHashMapUnmanaged(usize, Val));
    errdefer self.allocator.destroy(m);
    m.* = .{};
    try self.structs.put(self.allocator, m, self.reachable_color.swap());
    return m;
}

/// Mark a single value as reachable.
pub fn markVal(self: *MemoryManager, v: Val) !void {
    switch (v) {
        .string => |s| try self.strings.put(self.allocator, s, self.reachable_color),
        .structV => |s| {
            // Mark struct as reachable.
            if (self.structs.getEntry(s)) |entry| {
                if (entry.value_ptr.* == self.reachable_color) return;
                entry.value_ptr.* = self.reachable_color;
            } else {
                // This should not be possible as all structs should be in self.structs. Consider
                // returning an error instead.
                try self.structs.put(self.allocator, s, self.reachable_color);
            }
            // Mark any child values.
            var iter = s.valueIterator();
            while (iter.next()) |structVal| {
                try self.markVal(structVal.*);
            }
        },
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

/// Sweep all values that are unreachable and reset the color marking. For garbage collection, you
/// typically want to:
///   1. Call `self.markVal` on all reachable `Val` objects.
///   2. Call `self.sweep()` to garbage collect.
///   3. Repeat.
pub fn sweep(self: *MemoryManager) !void {
    var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer tmp_arena.deinit();

    var string_free_targets = std.ArrayList([]const u8).init(tmp_arena.allocator());
    var strings_iter = self.strings.iterator();
    while (strings_iter.next()) |entry| {
        if (entry.value_ptr.* != self.reachable_color) {
            try string_free_targets.append(entry.key_ptr.*);
        }
    }
    for (string_free_targets.items) |s| {
        _ = self.strings.remove(s);
        self.allocator.free(s);
    }
    _ = tmp_arena.reset(.retain_capacity);

    var list_free_targets = std.ArrayList([*]Val).init(tmp_arena.allocator());
    var lists_iter = self.lists.iterator();
    while (lists_iter.next()) |entry| {
        if (entry.value_ptr.color != self.reachable_color) {
            const lst = entry.key_ptr.*[0..entry.value_ptr.len];
            self.allocator.free(lst);
            try list_free_targets.append(entry.key_ptr.*);
        }
    }
    for (list_free_targets.items) |t| _ = self.lists.remove(t);
    _ = tmp_arena.reset(.retain_capacity);

    var struct_free_targets = std.ArrayList(*std.AutoHashMapUnmanaged(usize, Val)).init(tmp_arena.allocator());
    var structsIter = self.structs.iterator();
    while (structsIter.next()) |entry| {
        if (entry.value_ptr.* != self.reachable_color) {
            try struct_free_targets.append(entry.key_ptr.*);
        }
    }
    for (struct_free_targets.items) |t| {
        _ = self.structs.remove(t);
        t.*.deinit(self.allocator);
        self.allocator.destroy(t);
    }
    _ = tmp_arena.reset(.retain_capacity);

    var bytecode_free_targets = std.ArrayList(*ByteCode).init(tmp_arena.allocator());
    var bytecode_iter = self.bytecode.iterator();
    while (bytecode_iter.next()) |entry| {
        if (entry.value_ptr.* != self.reachable_color) {
            ByteCode.deinit(entry.key_ptr.*, self.allocator);
            try bytecode_free_targets.append(entry.key_ptr.*);
        }
    }
    for (bytecode_free_targets.items) |bc| _ = self.bytecode.remove(bc);
    _ = tmp_arena.reset(.retain_capacity);

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
