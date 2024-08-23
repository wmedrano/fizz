const Vm = @This();

const Compiler = @import("Compiler.zig");
const Environment = @import("Environment.zig");
const Ir = @import("ir.zig").Ir;
const Module = @import("Module.zig");
const Val = @import("val.zig").Val;
const std = @import("std");

pub const Error = Environment.Error;

env: Environment,

/// Create a new virtual machine.
pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!Vm {
    return Vm{
        .env = try Environment.init(alloc),
    };
}

/// Deinitialize a virtual machine. Using self after calling deinit is invalid.
pub fn deinit(self: *Vm) void {
    self.env.deinit();
}

/// Evaluate a single expression from the string.
///
/// tmp_allocator - An allocator to use for parsing and compiling expr. The data will automatically
///   be freed by evalStr.
/// module - The module to run the expression in or "%default%" if null.
/// expr - The fizz expression to evaluate.
///
/// Note: The returned Val is only valid until the next garbage collection call.
pub fn evalStr(self: *Vm, tmp_allocator: std.mem.Allocator, module: Module.Builder, expr: []const u8) !Val {
    var ir = try Ir.initStrExpr(tmp_allocator, expr);
    defer ir.deinit(tmp_allocator);
    var compiler = try Compiler.initModule(tmp_allocator, &self.env, try self.env.getOrCreateModule(module));
    defer compiler.deinit();
    const bc = try compiler.compile(ir);
    return self.eval(bc, &.{});
}

/// Evaluate the function and return the result.
///
/// Note: The returned Val is only valid until the next runGc call.
pub fn eval(self: *Vm, func: Val, args: []const Val) Error!Val {
    defer self.env.stack.clearRetainingCapacity();
    defer self.env.frames.clearRetainingCapacity();
    return self.env.evalNoReset(func, args);
}

/// Get the memory allocator used to allocate all `Val` types.
pub fn allocator(self: *const Vm) std.mem.Allocator {
    return self.env.allocator();
}

// Tests the example code from site/index.md.
test "index.md example test" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    _ = try vm.evalStr(std.testing.allocator, .{}, "(define args (list 1 2 3 4))");
    const v = try vm.evalStr(std.testing.allocator, .{}, "args");
    const actual = try vm.env.toZig([]i64, std.testing.allocator, v);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep(&[_]i64{ 1, 2, 3, 4 }, actual);
}

test "can eval basic expression" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(std.testing.allocator, .{}, "4");
    try vm.env.runGc();
    try std.testing.expectEqual(Val{ .int = 4 }, actual);
    try std.testing.expectEqual(1, vm.env.runtime_stats.function_calls);
}

test "can deref symbols" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try vm.env.global_module.setVal(&vm.env, "test", try vm.env.memory_manager.allocateStringVal("test-val"));
    const actual = try vm.evalStr(std.testing.allocator, .{}, "test");
    try std.testing.expectEqualDeep(Val{ .string = @constCast("test-val") }, actual);
}

test "lambda can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(std.testing.allocator, .{}, "((lambda (x) x) true)");
    try std.testing.expectEqualDeep(Val{ .boolean = true }, actual);
}

test "apply takes native function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(std.testing.allocator, .{}, "(apply + (list 1 2 3 4))");
    try std.testing.expectEqualDeep(Val{ .int = 10 }, actual);
}

test "apply takes bytecode function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(std.testing.allocator, .{}, "(apply (lambda (a b c d) (- 0 a b c d)) (list 1 2 3 4))");
    try std.testing.expectEqualDeep(Val{ .int = -10 }, actual);
}

test "recursive function can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqualDeep(
        Val.none,
        try vm.evalStr(std.testing.allocator, .{}, "(define fib (lambda (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))"),
    );
    try std.testing.expectEqualDeep(
        Val{ .int = 55 },
        try vm.evalStr(std.testing.allocator, .{}, "(fib 10)"),
    );
    try std.testing.expectEqualDeep(621, vm.env.runtime_stats.function_calls);
}

test "can only deref symbols from the same module" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try (try vm.env.getOrCreateModule(.{}))
        .setVal(&vm.env, "test", try vm.env.memory_manager.allocateStringVal("test-val"));
    try std.testing.expectEqualStrings(
        "test-val",
        (try vm.evalStr(std.testing.allocator, .{}, "test")).string,
    );
    try std.testing.expectError(
        error.SymbolNotFound,
        vm.evalStr(std.testing.allocator, .{ .name = "%other%" }, "test"),
    );
}

test "symbols from imported modules can be referenced" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    _ = try vm.evalStr(std.testing.allocator, .{}, "(import \"test_scripts/geometry.fizz\")");
    try std.testing.expectEqualDeep(
        Val{ .float = 3.14 },
        try vm.evalStr(std.testing.allocator, .{}, "geometry/pi"),
    );
}

test "module imports are relative" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqualDeep(Val.none, vm.evalStr(std.testing.allocator, .{}, "(import \"test_scripts/import.fizz\")"));
    try std.testing.expectEqualDeep(
        Val{ .float = 6.28 },
        try vm.evalStr(std.testing.allocator, .{}, "import/two-pi"),
    );
}

test "import bad file fails" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectError(
        error.TypeError,
        vm.evalStr(std.testing.allocator, .{}, "(import \"test_scripts/fail.fizz\")"),
    );
}

test "->string" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqualStrings(
        "4",
        (try vm.evalStr(std.testing.allocator, .{}, "(->string 4)")).string,
    );
    try std.testing.expectEqualStrings(
        "cat",
        (try vm.evalStr(std.testing.allocator, .{}, "(->string \"cat\")")).string,
    );
    try std.testing.expectEqualStrings(
        "<function _>",
        (try vm.evalStr(std.testing.allocator, .{}, "(->string (lambda () 4))")).string,
    );
    try std.testing.expectEqualStrings(
        "(1 2 <function _>)",
        (try vm.evalStr(std.testing.allocator, .{}, "(->string (list 1 2 (lambda () 4)))")).string,
    );
}
