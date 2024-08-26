const Vm = @This();

const Compiler = @import("Compiler.zig");
const Ir = @import("ir.zig").Ir;
const Module = @import("Module.zig");
const std = @import("std");

pub const Environment = @import("Environment.zig");
pub const Error = Environment.Error;
pub const NativeFnError = Val.NativeFn.Error;
pub const Val = @import("val.zig").Val;

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

/// Contains allocators needed to evaluate an expression.
pub const EvalAllocators = struct {
    /// Allocator used by the compiler to allocate temporary memory. Using an arena allocator is
    /// recommended for best performance.
    compiler_allocator: std.mem.Allocator,
    /// Allocator used to construct return value. Only used if the return value contains slices.
    return_value_allocator: std.mem.Allocator,
};

/// Evaluate a single expression from the string.
///
/// tmp_allocator - An allocator to use for parsing and compiling expr. The data will automatically
///   be freed by evalStr.
/// module - The module to run the expression in or "*default*" if null.
/// expr - The fizz expression to evaluate.
///
/// Note: The returned Val is only valid until the next garbage collection call.
pub fn evalStr(self: *Vm, T: type, allocators: EvalAllocators, expr: []const u8) !T {
    var ir = try Ir.initStrExpr(allocators.compiler_allocator, expr);
    defer ir.deinit(allocators.compiler_allocator);
    var compiler = try Compiler.initModule(allocators.compiler_allocator, &self.env, try self.env.getOrCreateModule(.{}));
    defer compiler.deinit();
    const bc = try compiler.compile(ir);
    const ret_val = try self.evalFuncVal(bc, &.{});
    return self.env.toZig(T, allocators.return_value_allocator, ret_val);
}

/// Evaluate the function and return the result.
///
/// Note: The returned Val is only valid until the next runGc call.
pub fn evalFuncVal(self: *Vm, func: Val, args: []const Val) Error!Val {
    defer self.env.stack.clearRetainingCapacity();
    defer self.env.frames.clearRetainingCapacity();
    return self.env.evalNoReset(func, args);
}

/// Register a function to the global namespace.
pub fn registerGlobalFn(
    self: *Vm,
    name: []const u8,
    func: *const fn (*Environment, []const Val) NativeFnError!Val,
) !void {
    const func_val = Val{ .native_fn = .{ .impl = func } };
    try self.env.global_module.setVal(&self.env, name, func_val);
}

/// Get the memory allocator used to allocate all `Val` types.
pub fn allocator(self: *const Vm) std.mem.Allocator {
    return self.env.allocator();
}

// Tests the example code from site/index.md.
test "index.md example test" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    _ = try vm.evalStr(Val, allocators, "(define args (list 1 2 3 4))");
    const actual = try vm.evalStr([]i64, allocators, "args");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep(&[_]i64{ 1, 2, 3, 4 }, actual);
}

// Tests the example code from site/zig-api.md
test "zig-api.md example test" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();

    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    _ = try vm.evalStr(Val, allocators, "(define magic-numbers (list 1 2 3 4))");
    const ResultType = struct { numbers: []const i64, numbers_sum: i64 };
    const actual = try vm.evalStr(ResultType, allocators, "(struct 'numbers magic-numbers 'numbers-sum (apply + magic-numbers))");
    defer std.testing.allocator.free(actual.numbers);
    try std.testing.expectEqualDeep(
        ResultType{ .numbers = &[_]i64{ 1, 2, 3, 4 }, .numbers_sum = 10 },
        actual,
    );
}

test "can eval basic expression" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();

    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    const actual = try vm.evalStr(i64, allocators, "4");
    try vm.env.runGc();
    try std.testing.expectEqual(4, actual);
    try std.testing.expectEqual(1, vm.env.runtime_stats.function_calls);
}

test "multiple expressions returns last expression" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    const actual = try vm.evalStr(i64, allocators, "4 5 6");
    try vm.env.runGc();
    try std.testing.expectEqual(actual, actual);
    try std.testing.expectEqual(1, vm.env.runtime_stats.function_calls);
}

test "can deref symbols" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try vm.env.global_module.setVal(&vm.env, "test", try vm.env.memory_manager.allocateStringVal("test-val"));
    const actual = try vm.evalStr([]const u8, allocators, "test");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep("test-val", actual);
}

test "lambda can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    const actual = try vm.evalStr(bool, allocators, "((lambda (x) x) true)");
    try std.testing.expectEqualDeep(true, actual);
}

test "apply takes native function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    const actual = try vm.evalStr(i64, allocators, "(apply + (list 1 2 3 4))");
    try std.testing.expectEqualDeep(10, actual);
}

test "apply takes bytecode function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    const actual = try vm.evalStr(
        i64,
        allocators,
        "(apply (lambda (a b c d) (- 0 a b c d)) (list 1 2 3 4))",
    );
    try std.testing.expectEqualDeep(-10, actual);
}

test "recursive function can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try std.testing.expectEqualDeep(
        Val.none,
        try vm.evalStr(Val, allocators, "(define fib (lambda (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))"),
    );
    try std.testing.expectEqualDeep(
        55,
        try vm.evalStr(i64, allocators, "(fib 10)"),
    );
    try std.testing.expectEqualDeep(621, vm.env.runtime_stats.function_calls);
}

test "can only deref symbols from the same module" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try (try vm.env.getOrCreateModule(.{ .name = "*other*" }))
        .setVal(&vm.env, "test", try vm.env.memory_manager.allocateStringVal("test-val"));
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try std.testing.expectError(
        error.SymbolNotFound,
        vm.evalStr(Val, allocators, "test"),
    );
}

test "symbols from imported modules can be referenced" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    _ = try vm.evalStr(Val, allocators, "(import \"test_scripts/geometry.fizz\")");
    try std.testing.expectEqualDeep(
        3.14,
        try vm.evalStr(f64, allocators, "geometry/pi"),
    );
}

test "module imports are relative" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try std.testing.expectEqualDeep({}, try vm.evalStr(void, allocators, "(import \"test_scripts/import.fizz\")"));
    try std.testing.expectEqualDeep(
        6.28,
        try vm.evalStr(f64, allocators, "import/two-pi"),
    );
}

test "import bad file fails" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try std.testing.expectError(
        error.TypeError,
        vm.evalStr(Val, allocators, "(import \"test_scripts/fail.fizz\")"),
    );
}

test "->str" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try std.testing.expectEqualStrings(
        "4",
        (try vm.evalStr(Val, allocators, "(->str 4)")).string,
    );
    try std.testing.expectEqualStrings(
        "cat",
        (try vm.evalStr(Val, allocators, "(->str \"cat\")")).string,
    );
    try std.testing.expectEqualStrings(
        "<function _>",
        (try vm.evalStr(Val, allocators, "(->str (lambda () 4))")).string,
    );
    try std.testing.expectEqualStrings(
        "(1 2 <function _>)",
        (try vm.evalStr(Val, allocators, "(->str (list 1 2 (lambda () 4)))")).string,
    );
}

test "struct can build and get" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try vm.evalStr(void, allocators, "(define x (struct 'id 0 'message \"hello world\"))");
    try std.testing.expectEqual(
        0,
        try vm.evalStr(i64, allocators, "(struct-get x 'id)"),
    );
    try std.testing.expectEqualStrings(
        "hello world",
        (try vm.evalStr(Val, allocators, "(struct-get x 'message)")).string,
    );
    try std.testing.expectError(
        error.RuntimeError,
        vm.evalStr(Val, allocators, "(struct-get x 'does-not-exist)"),
    );
}

test "struct get with nonexistant field fails" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const allocators = .{
        .compiler_allocator = std.testing.allocator,
        .return_value_allocator = std.testing.allocator,
    };
    try vm.evalStr(void, allocators, "(define x (struct 'id 0 'message \"hello world\"))");
    try std.testing.expectError(
        error.RuntimeError,
        vm.evalStr(Val, allocators, "(struct-get x 'does-not-exist)"),
    );
}
