const Module = @This();

const Val = @import("val.zig").Val;
const Vm = @import("Vm.zig");
const iter = @import("iter.zig");
const std = @import("std");

values: std.StringHashMapUnmanaged(Val) = .{},

/// Set a value within the module.
pub fn setVal(self: *Module, vm: *Vm, sym: []const u8, v: Val) !void {
    const interned_sym = try vm.memory_manager.allocateString(sym);
    try self.values.put(vm.memory_manager.allocator, interned_sym, v);
}

/// Get a value within the module.
pub fn getVal(self: *const Module, sym: []const u8) ?Val {
    return self.values.get(sym);
}

/// Deinitialize the module.
pub fn deinit(self: *Module, vm: *Vm) void {
    self.values.deinit(vm.memory_manager.allocator);
}

/// An iterator over values referenced within the module.
pub const ValIterator = struct {
    /// The next (symbol) value that will be returned.
    next_val: ?[]const u8,
    /// The underlying iterator over values.
    iterator: std.StringHashMapUnmanaged(Val).Iterator,

    /// Get the next referenced value.
    pub fn next(self: *ValIterator) ?Val {
        if (self.next_val) |v| {
            self.next_val = null;
            return .{ .symbol = v };
        }
        if (self.iterator.next()) |nxt| {
            self.next_val = nxt.key_ptr.*;
            return nxt.value_ptr.*;
        }
        return null;
    }
};

/// Iterate over all referenced values.
pub fn iterateVals(self: *const Module) ValIterator {
    return ValIterator{
        .next_val = null,
        .iterator = self.values.iterator(),
    };
}

test "can iterate over values" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    var module = Module{};
    defer module.deinit(&vm);
    try module.setVal(&vm, "test-val", .{ .int = 42 });
    var it = module.iterateVals();
    const actual = try iter.toSlice(Val, std.testing.allocator, &it);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep(
        &[_]Val{ .{ .int = 42 }, .{ .symbol = "test-val" } },
        actual,
    );
}
