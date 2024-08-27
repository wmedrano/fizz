const std = @import("std");
const ScopeManager = @This();

pub const Scope = struct {
    symbols: std.ArrayListUnmanaged(Variable) = .{},
};

pub const Variable = struct {
    name: []const u8,
    idx: usize,
};

scopes: std.ArrayListUnmanaged(Scope),
allocator: std.mem.Allocator,
next_idx: usize,

pub fn init(allocator: std.mem.Allocator) !ScopeManager {
    var scopes = std.ArrayListUnmanaged(Scope){};
    try scopes.append(allocator, .{});
    return .{
        .scopes = scopes,
        .allocator = allocator,
        .next_idx = 0,
    };
}

pub fn initWithArgs(allocator: std.mem.Allocator, symbols: []const []const u8) !ScopeManager {
    var scopes = std.ArrayListUnmanaged(Scope){};
    try scopes.append(allocator, .{});
    try scopes.items[0].symbols.ensureTotalCapacity(allocator, symbols.len);
    for (symbols, 0..symbols.len) |sym, idx| {
        scopes.items[0].symbols.appendAssumeCapacity(.{ .name = sym, .idx = idx });
    }
    return .{
        .scopes = scopes,
        .allocator = allocator,
        .next_idx = symbols.len,
    };
}

pub fn deinit(self: *ScopeManager) void {
    for (self.scopes.items) |*scope| {
        scope.symbols.deinit(self.allocator);
    }
    self.scopes.deinit(self.allocator);
}

pub fn popScope(self: *ScopeManager) void {
    var s = self.scopes.pop();
    s.symbols.deinit(self.allocator);
}

pub fn pushScope(self: *ScopeManager) !void {
    try self.scopes.append(self.allocator, .{});
}

pub fn addVariable(self: *ScopeManager, name: []const u8) !usize {
    const idx = self.next_idx;
    if (self.scopes.items.len == 0) try self.pushScope();
    const scope = &self.scopes.items[self.scopes.items.len - 1];
    try scope.symbols.append(
        self.allocator,
        .{ .name = name, .idx = idx },
    );
    self.next_idx += 1;
    return idx;
}

pub fn variableIdx(self: *const ScopeManager, name: []const u8) ?usize {
    var scope_idx = self.scopes.items.len;
    while (scope_idx > 0) {
        scope_idx -= 1;
        var var_idx = self.scopes.items[scope_idx].symbols.items.len;
        while (var_idx > 0) {
            var_idx -= 1;
            if (std.mem.eql(u8, name, self.scopes.items[scope_idx].symbols.items[var_idx].name))
                return self.scopes.items[scope_idx].symbols.items[var_idx].idx;
        }
    }
    return null;
}

pub fn scopeCount(self: *const ScopeManager) usize {
    return self.scopes.items.len;
}

pub fn retainScopes(self: *ScopeManager, count: usize) !void {
    const scope_count = self.scopeCount();
    if (scope_count < count) return error.NoScopeToPop;
    const pop_count = scope_count - count;
    for (0..pop_count) |_| self.popScope();
}
