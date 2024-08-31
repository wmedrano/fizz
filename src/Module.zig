const Module = @This();

const Env = @import("Env.zig");
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;
const iter = @import("datastructures/iter.zig");
const std = @import("std");

/// The name of the module. This string is owned and managed by Module.
name: []const u8,
/// The values within the module. The strings and values are managed by a Vm. Only the hashmap
/// datastructure itself is managed by Module.
values: std.AutoHashMapUnmanaged(usize, Val) = .{},
/// Map from alias to module that this module has access to.
alias_to_module: std.StringHashMapUnmanaged(*Module),

pub const Builder = struct {
    pub const default_name = "*default*";
    /// The name of the module. If the module is backed by a file, then this should be the filename.
    name: []const u8 = default_name,
};

/// Initialize an empty module with the given name.
pub fn init(allocator: std.mem.Allocator, b: Builder) !*Module {
    const module = try allocator.create(Module);
    module.* = .{
        .name = try allocator.dupe(u8, b.name),
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
pub fn setVal(self: *Module, env: *Env, sym: []const u8, v: Val) !void {
    const sym_id = try env.memory_manager.allocateSymbol(sym);
    try self.setValBySymbolId(env, sym_id, v);
}

/// Set a value within the module by the symbol id.
pub fn setValBySymbolId(self: *Module, env: *Env, sym_id: usize, v: Val) !void {
    try self.values.put(env.memory_manager.allocator, sym_id, v);
}

/// Get a value within the module.
pub fn getVal(self: *const Module, memory_manager: *const MemoryManager, sym: []const u8) ?Val {
    if (memory_manager.symbolId(sym)) |sym_id|
        return self.values.get(sym_id);
    return null;
}

/// Get a value within the module by its symbol id.
pub fn getValBySybolId(self: *const Module, sym_id: usize) ?Val {
    return self.values.get(sym_id);
}

/// Set a module alias.
pub fn setModuleAlias(self: *Module, allocator: std.mem.Allocator, alias: []const u8, module: *Module) !void {
    if (self.alias_to_module.contains(alias)) {
        try self.alias_to_module.put(allocator, alias, module);
        return;
    }
    const alias_dupe = try allocator.dupe(u8, alias);
    errdefer allocator.free(alias_dupe);
    try self.alias_to_module.put(allocator, alias_dupe, module);
}

/// Clear the module alias. If the alias is cleared, then `true` is returned. If the module did not
/// exist, then `false` is returned.
///
/// The passed in allocator is used to free the alias map.
pub fn clearModuleAlias(self: *Module, allocator: std.mem.Allocator, alias: []const u8) bool {
    const entry = self.alias_to_module.getEntry(alias) orelse return false;
    const alias_data = entry.key_ptr.*;
    self.alias_to_module.removeByPtr(entry.key_ptr);
    allocator.free(alias_data);
    return true;
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
    /// The underlying iterator over values.
    iterator: std.AutoHashMapUnmanaged(usize, Val).ValueIterator,

    /// Get the next referenced value.
    pub fn next(self: *ValIterator) ?Val {
        if (self.iterator.next()) |v| return v.*;
        return null;
    }
};

/// Iterate over all referenced values.
pub fn iterateVals(self: *const Module) ValIterator {
    return .{ .iterator = self.values.valueIterator() };
}

/// Get the directory for the module or the working directory if it is a virtual module.
pub fn directory(self: *const Module) !std.fs.Dir {
    const dirname = std.fs.path.dirname(self.name);
    if (dirname) |d| return std.fs.cwd().openDir(d, .{});
    return std.fs.cwd();
}

test "can iterate over values" {
    var env = try Env.init(std.testing.allocator);
    defer env.deinit();
    var module = try Module.init(std.testing.allocator, .{});
    defer module.deinit(env.memory_manager.allocator);
    try module.setVal(&env, "test-val", .{ .int = 42 });
    var it = module.iterateVals();
    const actual = try iter.toSlice(Val, std.testing.allocator, &it);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep(
        &[_]Val{.{ .int = 42 }},
        actual,
    );
}

test "default module directory is cwd" {
    var module = try Module.init(std.testing.allocator, .{ .name = "*virtual*" });
    defer module.deinit(std.testing.allocator);
    const actual_dir = try module.directory();
    const actual = try actual_dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(actual);
    const expected = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
}

test "default module alias" {
    try std.testing.expectEqualStrings("*global*", defaultModuleAlias("*global*"));
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
