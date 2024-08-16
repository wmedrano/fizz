const Module = @This();

const Val = @import("val.zig").Val;
const Vm = @import("Vm.zig");
const iter = @import("iter.zig");
const std = @import("std");

/// The name of the module. This string is owned and managed by Module.
name: []const u8,
/// The values within the module. The strings and values are managed by a Vm. Only the hashmap
/// datastructure itself is managed by Module.
values: std.StringHashMapUnmanaged(Val) = .{},
/// Map from alias to module that this module has access to.
alias_to_module: std.StringHashMapUnmanaged(*Module),

/// Initialize an empty module with the given name.
pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Module {
    const module = try allocator.create(Module);
    module.* = .{
        .name = try allocator.dupe(u8, name),
        .values = .{},
        .alias_to_module = .{},
    };
    return module;
}

/// Deinitialize the module.
pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
    self.deinitLocal(allocator);
    allocator.destroy(self);
}

/// Deinitialize the module. deinitLocal should be used if the Module was allocated on the stack
/// instead of with a memory allocator as done in init.
pub fn deinitLocal(self: *Module, allocator: std.mem.Allocator) void {
    self.values.deinit(allocator);
    allocator.free(self.name);

    var alias_iter = self.alias_to_module.keyIterator();
    while (alias_iter.next()) |a| allocator.free(a.*);
    self.alias_to_module.deinit(allocator);
    self.* = undefined;
}

/// Set a value within the module.
pub fn setVal(self: *Module, vm: *Vm, sym: []const u8, v: Val) !void {
    const interned_sym = try vm.memory_manager.allocateString(sym);
    try self.values.put(vm.allocator(), interned_sym, v);
}

/// Get a value within the module.
pub fn getVal(self: *const Module, sym: []const u8) ?Val {
    return self.values.get(sym);
}

/// Set a module alias.
pub fn setModuleAlias(self: *Module, allocator: std.mem.Allocator, alias: []const u8, module: *Module) !void {
    try self.alias_to_module.put(allocator, try allocator.dupe(u8, alias), module);
}

/// Get the default name for the alias for a module derived from path.
pub fn defaultModuleAlias(path: []const u8) []const u8 {
    if (path.len == 0) return &.{};
    var start = path.len - 1;
    while (start > 0 and path[start] != '/') start -= 1;
    if (path[start] == '/') start += 1;
    var end = path.len - 1;
    while (end > 0) {
        if (path[end] == '.') return path[start..end];
        end -= 1;
    }
    return path[start..];
}

pub const AliasAndSymbol = struct { module_alias: ?[]const u8, symbol: []const u8 };

/// Parse the module and symbol.
pub fn parseModuleAndSymbol(ident: []const u8) AliasAndSymbol {
    var separator_idx: usize = 0;
    while (separator_idx < ident.len and ident[separator_idx] != '/') {
        separator_idx += 1;
    }
    if (separator_idx == ident.len or separator_idx == 0 or separator_idx + 1 == ident.len) {
        return .{ .module_alias = null, .symbol = ident };
    }
    return .{
        .module_alias = ident[0..separator_idx],
        .symbol = ident[separator_idx + 1 ..],
    };
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
    var module = try Module.init(std.testing.allocator, "%test%");
    defer module.deinit(vm.allocator());
    try module.setVal(&vm, "test-val", .{ .int = 42 });
    var it = module.iterateVals();
    const actual = try iter.toSlice(Val, std.testing.allocator, &it);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep(
        &[_]Val{ .{ .int = 42 }, .{ .symbol = "test-val" } },
        actual,
    );
}

test "default module alias" {
    try std.testing.expectEqualStrings("%global%", defaultModuleAlias("%global%"));
    try std.testing.expectEqualStrings("module", defaultModuleAlias("module.fizz"));
    try std.testing.expectEqualStrings("module", defaultModuleAlias("my/module.fizz"));
}

test "parse module and symbol" {
    try std.testing.expectEqualDeep(
        AliasAndSymbol{ .module_alias = null, .symbol = "/" },
        parseModuleAndSymbol("/"),
    );
    try std.testing.expectEqualDeep(
        AliasAndSymbol{ .module_alias = null, .symbol = "module/" },
        parseModuleAndSymbol("module/"),
    );
    try std.testing.expectEqualDeep(
        AliasAndSymbol{ .module_alias = null, .symbol = "/symbol" },
        parseModuleAndSymbol("/symbol"),
    );
    try std.testing.expectEqualDeep(
        AliasAndSymbol{ .module_alias = "module", .symbol = "symbol" },
        parseModuleAndSymbol("module/symbol"),
    );
    try std.testing.expectEqualDeep(
        AliasAndSymbol{ .module_alias = "module", .symbol = "symbol/subsymbol" },
        parseModuleAndSymbol("module/symbol/subsymbol"),
    );
}
