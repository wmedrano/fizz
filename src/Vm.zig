const Vm = @This();

const Compiler = @import("Compiler.zig");
const Ir = @import("ir.zig").Ir;
const std = @import("std");
const builtins = @import("builtins.zig");
const ErrorCollector = @import("datastructures/ErrorCollector.zig");
const Ast = @import("Ast.zig");
const Symbol = Val.Symbol;

pub const Env = @import("Env.zig");
pub const Error = Env.Error;
pub const NativeFnError = Val.NativeFn.Error;
pub const Val = @import("val.zig").Val;

env: Env,

/// Create a new virtual machine.
pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Vm {
    var vm = Vm{
        .env = try Env.init(allocator),
    };
    try builtins.registerAll(&vm);
    return vm;
}

/// Deinitialize a virtual machine. Using self after calling deinit is invalid.
pub fn deinit(self: *Vm) void {
    self.env.deinit();
}

/// Evaluate a single expression from the string.
///
/// allocator - Allocator used to allocate any slices or strings for the return value.
/// expr - The fizz expression to evaluate.
///
/// Note: The returned Val is only valid until the next garbage collection call.
pub fn evalStr(self: *Vm, T: type, allocator: std.mem.Allocator, expr: []const u8) !T {
    var tmp_arena = std.heap.ArenaAllocator.init(self.valAllocator());
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();
    const ir = try Ir.initStrExpr(tmp_allocator, &self.env.errors, expr);
    var compiler = try Compiler.init(tmp_allocator, &self.env);
    const bc = try compiler.compile(ir);
    const ret_val = try self.evalFuncVal(bc, &.{});
    return self.toZig(T, allocator, ret_val);
}

/// Evaluate the function and return the result.
///
/// Note: The returned Val is only valid until the next runGc call.
pub fn evalFuncVal(self: *Vm, func: Val, args: []const Val) Error!Val {
    defer self.env.stack.clearRetainingCapacity();
    defer self.env.frames.clearRetainingCapacity();
    return self.evalNoReset(func, args);
}

/// Register a function to the global namespace.
pub fn registerGlobalFn(
    self: *Vm,
    name: []const u8,
    func: *const fn (*Vm, []const Val) NativeFnError!Val,
) !void {
    const sym = try self.env.memory_manager.allocateSymbol(name);
    const func_val = Val{ .native_fn = .{ .impl = func } };
    try self.env.global_values.put(self.env.memory_manager.allocator, sym, func_val);
}

/// Get the memory allocator used for all `Val`.
pub fn valAllocator(self: *const Vm) std.mem.Allocator {
    return self.env.memory_manager.allocator;
}

/// Convert the val into a Zig value.
///
/// T - The type to convert to.
/// alloc - Allocator used to create strings and slices.
/// val - The value to convert from.
pub fn toZig(self: *Vm, T: type, alloc: std.mem.Allocator, val: Val) !T {
    if (T == Val) return val;
    if (T == void) {
        if (!val.isNone()) return error.TypeError;
        return;
    }
    if (T == bool) return val.asBool();
    if (T == i64) return val.asInt();
    if (T == f64) return val.asFloat();
    if (T == []u8 or T == []const u8) {
        switch (val) {
            .string => |s| return try alloc.dupe(u8, s),
            else => return error.TypeError,
        }
    }
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            switch (info.size) {
                .One => @compileError("Val.toZig does not support pointers."),
                .Slice => switch (val) {
                    .list => |lst| {
                        var ret = try alloc.alloc(info.child, lst.len);
                        var init_count: usize = 0;
                        errdefer toZigClean(T, alloc, ret, init_count);
                        for (0..lst.len) |idx| {
                            ret[idx] = try self.toZig(info.child, alloc, lst[idx]);
                            init_count += 1;
                        }
                        return ret;
                    },
                    else => return error.TypeError,
                },
                .Many => @compileError("Val.toZig does not support Many pointers."),
                .C => @compileError("Val.toZig does not support C pointers."),
            }
        },
        .Struct => |info| {
            const struct_val = switch (val) {
                .structV => |m| m,
                else => return error.TypeError,
            };
            var ret: T = undefined;
            var totalFieldsInit: usize = 0;
            errdefer inline for (info.fields, 0..info.fields.len) |field, idx| {
                if (idx < totalFieldsInit) {
                    toZigClean(field.type, alloc, @field(ret, field.name), null);
                }
            };
            inline for (info.fields, 0..info.fields.len) |field, idx| {
                totalFieldsInit = idx;
                var fizz_field_name: [field.name.len]u8 = undefined;
                @memcpy(&fizz_field_name, field.name);
                makeKebabCase(&fizz_field_name);
                if (self.env.memory_manager.symbols.getId(&fizz_field_name)) |sym| {
                    const field_val = struct_val.map.get(sym) orelse
                        return Error.TypeError;
                    const field_zig_val = try self.toZig(field.type, alloc, field_val);
                    errdefer toZigClean(field.type, alloc, field_zig_val, null);
                    @field(ret, field.name) = field_zig_val;
                } else {
                    try self.env.errors.addError(
                        "field {s} not found in Fizz struct",
                        .{fizz_field_name},
                    );
                    return Error.TypeError;
                }
            }
            return ret;
        },
        else => {
            @compileLog("Val.toZig called with type", T);
            @compileError("Val.toZig called with unsupported Zig type.");
        },
    }
}

fn makeKebabCase(name: []u8) void {
    for (name, 0..name.len) |ch, idx| {
        if (ch == '_') name[idx] = '-';
    }
}

// T - The type that will be cleaned up.
// alloc - The allocator used to allocate said values.
// v - The object to deallocate.
// slice_init_count - If v is a slice, then this is the number of elements that were initialized or
//   `null` to deallocate all the elements.
fn toZigClean(T: type, alloc: std.mem.Allocator, v: T, slice_init_count: ?usize) void {
    if (T == void or T == bool or T == i64 or T == f64) return;
    if (T == []u8 or T == []const u8) {
        alloc.free(v);
        return;
    }
    switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .Slice => {
                const slice = if (slice_init_count) |n| v[0..n] else v;
                for (slice) |item| toZigClean(info.child, alloc, item, null);
                alloc.free(v);
            },
            else => {
                @compileLog("Val.toZig called with type", T);
                @compileError("Val.toZig cleanup for type not implemented.");
            },
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                toZigClean(field.type, alloc, @field(v, field.name), null);
            }
        },
        else => {
            @compileLog("Val.toZig called with type", @typeName(T));
            @compileError("Val.toZig cleanup for type not implemented.");
        },
    }
}

/// Run the garbage collector to free up memory.
pub fn runGc(self: *Vm) !void {
    var timer = try std.time.Timer.start();
    defer self.env.runtime_stats.gc_duration_nanos += timer.read();
    for (self.env.stack.items) |v| try self.env.memory_manager.markVal(v);
    for (self.env.frames.items) |f| try self.env.memory_manager.markVal(.{ .bytecode = f.bytecode });

    var global_values = self.env.global_values.valueIterator();
    while (global_values.next()) |v| {
        try self.env.memory_manager.markVal(v.*);
    }

    var strings_iter = self.env.memory_manager.keep_alive_strings.keyIterator();
    while (strings_iter.next()) |v| try self.env.memory_manager.markVal(.{ .string = v.* });

    var list_iter = self.env.memory_manager.keep_alive_lists.keyIterator();
    while (list_iter.next()) |v| {
        if (self.env.memory_manager.lists.get(v.*)) |len_and_color|
            try self.env.memory_manager.markVal(.{ .list = v.*[0..len_and_color.len] });
    }

    var structs_iter = self.env.memory_manager.keep_alive_structs.keyIterator();
    while (structs_iter.next()) |v| try self.env.memory_manager.markVal(.{ .structV = v.* });

    var bytecode_iter = self.env.memory_manager.keep_alive_bytecode.keyIterator();
    while (bytecode_iter.next()) |v| try self.env.memory_manager.markVal(.{ .bytecode = v.* });

    try self.env.memory_manager.sweep();
}

pub fn keepAlive(self: *Vm, val: Val) !void {
    const mm = &self.env.memory_manager;
    switch (val) {
        .string => |s| try self.refIncr(&mm.keep_alive_strings, s),
        .list => |lst| try self.refIncr(&mm.keep_alive_lists, lst.ptr),
        .structV => |strct| try self.refIncr(&mm.keep_alive_structs, strct),
        .bytecode => |bc| try self.refIncr(&mm.keep_alive_bytecode, bc),
        else => {},
    }
}

inline fn refIncr(self: *Vm, map: anytype, obj: anytype) !void {
    const entry = try map.getOrPutValue(self.valAllocator(), obj, 0);
    entry.value_ptr.* += 1;
}

pub fn allowDeath(self: *Vm, val: Val) void {
    const mm = &self.env.memory_manager;
    switch (val) {
        .string => |s| try self.refDecr(&mm.keep_alive_strings, s),
        .list => |lst| try self.refDecr(&mm.keep_alive_lists, lst.ptr),
        .structV => |strct| try self.refDecr(&mm.keep_alive_structs, strct),
        .bytecode => |bc| try self.refDecr(&mm.keep_alive_bytecode, bc),
        else => {},
    }
}

inline fn refDecr(_: *Vm, map: anytype, obj: anytype) !void {
    if (map.getEntry(obj)) |entry| {
        entry.value_ptr.* -= 1;
        if (entry.value_ptr.* == 0) map.removeByPtr(entry.key_ptr);
    }
}

/// Evaluate the function and return the result.
///
/// Compared to the `eval` function present in `Vm`, this function can be called from a native
/// function as it does not reset the function call and data stacks after execution.
///
/// Note: The returned Val is only valid until the next runGc call. Use `self.toZig` to extend the
/// lifetime if needed.
pub fn evalNoReset(self: *Vm, func: Val, args: []const Val) Error!Val {
    self.env.runtime_stats.function_calls += 1;
    if (self.env.gc_strategy == .per_256_calls and self.env.runtime_stats.function_calls % 256 == 0)
        self.runGc() catch return Error.RuntimeError;
    const stack_start = self.env.stack.items.len;
    // TODO: The following is fragile as it duplicates a lot of executeEval.
    switch (func) {
        .bytecode => |bc| {
            const frame = .{
                .bytecode = bc,
                .instruction = bc.instructions.items.ptr,
                .stack_start = stack_start,
                .ffi_boundary = true,
            };
            try self.env.stack.appendNTimes(self.valAllocator(), .none, bc.locals_count);
            self.env.frames.appendAssumeCapacity(frame);
            try self.env.stack.appendSlice(self.valAllocator(), args);
            while (try self.runNext()) {}
            if (self.env.stack.items.len > stack_start) {
                const ret = self.env.stack.pop();
                self.env.stack.items = self.env.stack.items[0..stack_start];
                return ret;
            } else {
                return .none;
            }
        },
        .native_fn => |nf| {
            try self.env.stack.appendSlice(self.valAllocator(), args);
            const ret = try nf.impl(self, args);
            if (self.env.stack.items.len > stack_start) self.env.stack.items = self.env.stack.items[0..stack_start];
            return ret;
        },
        else => return Error.TypeError,
    }
}

fn runNext(self: *Vm) Error!bool {
    var frame = &self.env.frames.items[self.env.frames.items.len - 1];
    switch (frame.instruction[0]) {
        .get_arg => |idx| try self.executeGetArg(frame, idx),
        .move => |idx| try self.executeMove(frame, idx),
        .push_const => |v| try self.executePushConst(v),
        .ret => {
            const should_continue = try self.executeRet();
            if (!should_continue) return false;
        },
        .deref_global => |s| try self.executeDeref(s),
        .eval => |n| try self.executeEval(frame, n),
        .jump => |n| frame.instruction += n,
        .jump_if => |n| if (try self.env.stack.pop().asBool()) {
            frame.instruction += n;
        },
        .define => |symbol| try self.executeDefine(symbol),
    }
    frame.instruction += 1;
    return true;
}

fn executePushConst(self: *Vm, v: Val) !void {
    try self.env.stack.append(self.valAllocator(), v);
}

fn executeDeref(self: *Vm, sym: Symbol) Error!void {
    if (self.env.global_values.get(sym)) |v| {
        try self.env.stack.append(self.valAllocator(), v);
        return;
    }
    return self.errSymbolNotFound(sym);
}

fn executeGetArg(self: *Vm, frame: *const Env.Frame, idx: usize) !void {
    const v = self.env.stack.items[frame.stack_start + idx];
    try self.env.stack.append(self.valAllocator(), v);
}

fn executeMove(self: *Vm, frame: *const Env.Frame, idx: usize) !void {
    const v = self.env.stack.popOrNull() orelse {
        try self.env.errors.addError("unexpected code branch reached, file a GitHub issue", .{});
        return error.RuntimeError;
    };
    self.env.stack.items[frame.stack_start + idx] = v;
}

fn executeEval(self: *Vm, frame: *const Env.Frame, n: usize) !void {
    self.env.runtime_stats.function_calls += 1;
    if (self.env.gc_strategy == .per_256_calls and self.env.runtime_stats.function_calls % 256 == 0)
        self.runGc() catch return Error.RuntimeError;
    const norm_n: usize = if (n == 0) self.env.stack.items.len - frame.stack_start else n;
    const arg_count = norm_n - 1;
    const fn_idx = self.env.stack.items.len - norm_n;
    const func = self.env.stack.items[fn_idx];
    const stack_start = fn_idx + 1;
    switch (func) {
        .bytecode => |bc| {
            if (bc.arg_count != arg_count) {
                try self.env.errors.addError(
                    "Function {s} received {d} arguments but expected {d}",
                    .{ bc.name, arg_count, bc.arg_count },
                );
                return error.ArrityError;
            }
            try self.env.stack.appendNTimes(self.valAllocator(), .none, bc.locals_count);
            const new_frame = Env.Frame{
                .bytecode = bc,
                .instruction = bc.instructions.items.ptr,
                .stack_start = stack_start,
                .ffi_boundary = false,
            };
            self.env.frames.appendAssumeCapacity(new_frame);
        },
        .native_fn => |nf| {
            self.env.stack.items[fn_idx] = try nf.impl(self, self.env.stack.items[stack_start..]);
            self.env.stack.items = self.env.stack.items[0..stack_start];
        },
        else => {
            try self.env.errors.addError(
                "Expected to evaluate value of type function but got {any}",
                .{func.tag()},
            );
            return error.TypeError;
        },
    }
}

fn executeRet(self: *Vm) !bool {
    const old_frame = self.env.frames.pop();
    if (old_frame.ffi_boundary) {
        return false;
    }
    const ret = self.env.stack.popOrNull() orelse .none;
    self.env.stack.items = self.env.stack.items[0..old_frame.stack_start];
    self.env.stack.items[old_frame.stack_start - 1] = ret;
    return true;
}

fn executeDefine(self: *Vm, symbol: Symbol) Error!void {
    const val = self.env.stack.pop();
    try self.env.global_values.put(self.env.memory_manager.allocator, symbol, val);
}

fn errSymbolNotFound(self: *Vm, sym: Symbol) Error {
    const name = self.env.memory_manager.symbols.getName(sym) orelse "*unknown-symbol*";
    try self.env.errors.addError(
        "Symbol {s} (id={d}) not found in global values",
        .{ name, sym.id },
    );
    return Error.SymbolNotFound;
}

test "can convert to zig val" {
    var vm = try init(std.testing.allocator);
    defer vm.deinit();

    try std.testing.expectEqual(false, vm.toZig(bool, std.testing.allocator, .{ .boolean = false }));
    try std.testing.expectEqual(42, vm.toZig(i64, std.testing.allocator, .{ .int = 42 }));
    try vm.toZig(void, std.testing.allocator, .none);
}

test "can convert to zig string" {
    var vm = try init(std.testing.allocator);
    defer vm.deinit();

    const actual_str = try vm.toZig([]const u8, std.testing.allocator, .{ .string = "string" });
    defer std.testing.allocator.free(actual_str);
    try std.testing.expectEqualStrings("string", actual_str);
}

test "can convert to zig slice" {
    var vm = try init(std.testing.allocator);
    defer vm.deinit();

    const actual_int_list = try vm.toZig(
        []i64,
        std.testing.allocator,
        Val{ .list = @constCast(&[_]Val{ Val{ .int = 1 }, Val{ .int = 2 } }) },
    );
    defer std.testing.allocator.free(actual_int_list);
    try std.testing.expectEqualDeep(&[_]i64{ 1, 2 }, actual_int_list);

    const actual_float_list_list = try vm.toZig(
        [][]f64,
        std.testing.allocator,
        Val{ .list = @constCast(
            &[_]Val{
                Val{ .list = @constCast(&[_]Val{ .{ .float = 1.0 }, .{ .float = 2.0 } }) },
                Val{ .list = @constCast(&[_]Val{ .{ .float = 3.0 }, .{ .float = 4.0 } }) },
            },
        ) },
    );
    defer std.testing.allocator.free(actual_float_list_list);
    defer for (actual_float_list_list) |lst| std.testing.allocator.free(lst);
    try std.testing.expectEqualDeep(
        &[_][]const f64{
            &[_]f64{ 1.0, 2.0 },
            &[_]f64{ 3.0, 4.0 },
        },
        actual_float_list_list,
    );
}

test "can't convert list of heterogenous types" {
    var vm = try init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectError(
        error.TypeError,
        vm.toZig(
            [][]u8,
            std.testing.allocator,
            Val{ .list = @constCast(
                &[_]Val{
                    Val{ .list = @constCast(&[_]Val{ .{ .string = "good" }, .{ .string = "also good" } }) },
                    Val{ .list = @constCast(&[_]Val{ .{ .string = "still good" }, .{ .symbol = .{ .id = 0 } } }) },
                },
            ) },
        ),
    );
}

test "can convert to zig struct" {
    var vm = try @import("Vm.zig").init(std.testing.allocator);
    defer vm.deinit();

    _ = try vm.evalStr(void, std.testing.allocator, "(define string \"string\")");
    _ = try vm.evalStr(void, std.testing.allocator, "(define lst (list 0 1 2))");
    _ = try vm.evalStr(void, std.testing.allocator, "(define strct (struct 'a-val 1 'b-val 2.0))");

    const TestType = struct {
        string: []const u8,
        list: []const i64,
        strct: struct { a_val: i64, b_val: f64 },
    };
    const actual = try vm.evalStr(
        TestType,
        std.testing.allocator,
        "(struct 'string string 'list lst 'strct strct)",
    );
    defer std.testing.allocator.free(actual.string);
    defer std.testing.allocator.free(actual.list);
    try std.testing.expectEqualDeep(
        TestType{
            .string = "string",
            .list = &[_]i64{ 0, 1, 2 },
            .strct = .{ .a_val = 1, .b_val = 2.0 },
        },
        actual,
    );
}

test "can convert to zig slice of structs" {
    var vm = try @import("Vm.zig").init(std.testing.allocator);
    defer vm.deinit();

    try vm.evalStr(void, std.testing.allocator, "(define x (struct 'a 1 'b 2))");

    const TestType = struct { a: i64, b: i64 };
    const actual = try vm.evalStr([]TestType, std.testing.allocator, "(list x x x)");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep(
        &[_]TestType{
            .{ .a = 1, .b = 2 },
            .{ .a = 1, .b = 2 },
            .{ .a = 1, .b = 2 },
        },
        actual,
    );
}

test "partially built struct cleans up" {
    var vm = try @import("Vm.zig").init(std.testing.allocator);
    defer vm.deinit();

    try vm.evalStr(void, std.testing.allocator, "(define string \"string\")");
    try vm.evalStr(void, std.testing.allocator, "(define bad-list (list 0 1 2 \"bad\"))");
    const TestType = struct {
        string: []const u8,
        list: []const i64,
    };
    try std.testing.expectError(
        error.TypeError,
        vm.evalStr(TestType, std.testing.allocator, "(struct 'string string 'list bad-list)"),
    );
}

fn quack(vm: *Vm, _: []const Val) NativeFnError!Val {
    return vm.env.memory_manager.allocateStringVal("quack!") catch return Error.RuntimeError;
}

// Tests the example code from site/index.md.
test "index.md example test" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    errdefer std.debug.print("Fizz VM failed:\n{any}\n", .{vm.env.errors});

    try vm.evalStr(void, std.testing.allocator, "(define my-list (list 1 2 3 4))");
    const sum = vm.evalStr(i64, std.testing.allocator, "(apply + my-list)");
    try std.testing.expectEqual(10, sum);

    try vm.registerGlobalFn("quack!", quack);
    const text = try vm.evalStr([]u8, std.testing.allocator, "(quack!)");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("quack!", text);
}

// Tests the example code from site/zig-api.md
test "zig-api.md example test" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();

    _ = try vm.evalStr(Val, std.testing.allocator, "(define magic-numbers (list 1 2 3 4))");
    const ResultType = struct { numbers: []const i64, numbers_sum: i64 };
    const actual = try vm.evalStr(ResultType, std.testing.allocator, "(struct 'numbers magic-numbers 'numbers-sum (apply + magic-numbers))");
    defer std.testing.allocator.free(actual.numbers);
    try std.testing.expectEqualDeep(
        ResultType{ .numbers = &[_]i64{ 1, 2, 3, 4 }, .numbers_sum = 10 },
        actual,
    );
}

test "can eval basic expression" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();

    const actual = try vm.evalStr(i64, std.testing.allocator, "4");
    try vm.runGc();
    try std.testing.expectEqual(4, actual);
    try std.testing.expectEqual(1, vm.env.runtime_stats.function_calls);
}

test "multiple expressions returns last expression" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(i64, std.testing.allocator, "4 5 6");
    try vm.runGc();
    try std.testing.expectEqual(actual, actual);
    try std.testing.expectEqual(1, vm.env.runtime_stats.function_calls);
}

test "can deref symbols" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try vm.evalStr(void, std.testing.allocator, "(define test \"test-val\")");
    const actual = try vm.evalStr([]const u8, std.testing.allocator, "test");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep("test-val", actual);
}

test "lambda can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(bool, std.testing.allocator, "((lambda (x) x) true)");
    try std.testing.expectEqualDeep(true, actual);
}

test "apply takes native function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(i64, std.testing.allocator, "(apply + (list 1 2 3 4))");
    try std.testing.expectEqualDeep(10, actual);
}

test "apply takes bytecode function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(
        i64,
        std.testing.allocator,
        "(apply (lambda (a b c d) (- 0 a b c d)) (list 1 2 3 4))",
    );
    try std.testing.expectEqualDeep(-10, actual);
}

test "recursive function can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqualDeep(
        Val.none,
        try vm.evalStr(Val, std.testing.allocator, "(define fib (lambda (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))"),
    );
    try std.testing.expectEqualDeep(
        55,
        try vm.evalStr(i64, std.testing.allocator, "(fib 10)"),
    );
    try std.testing.expectEqualDeep(620, vm.env.runtime_stats.function_calls);
}

test "->str" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqualStrings(
        "4",
        (try vm.evalStr(Val, std.testing.allocator, "(->str 4)")).string,
    );
    try std.testing.expectEqualStrings(
        "cat",
        (try vm.evalStr(Val, std.testing.allocator, "(->str \"cat\")")).string,
    );
    try std.testing.expectEqualStrings(
        "<function _>",
        (try vm.evalStr(Val, std.testing.allocator, "(->str (lambda () 4))")).string,
    );
    try std.testing.expectEqualStrings(
        "(1 2 <function _>)",
        (try vm.evalStr(Val, std.testing.allocator, "(->str (list 1 2 (lambda () 4)))")).string,
    );
}

test "struct can build and get" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try vm.evalStr(void, std.testing.allocator, "(define x (struct 'id 0 'message \"hello world\"))");
    try std.testing.expectEqual(
        0,
        try vm.evalStr(i64, std.testing.allocator, "(struct-get x 'id)"),
    );
    try std.testing.expectEqualStrings(
        "hello world",
        (try vm.evalStr(Val, std.testing.allocator, "(struct-get x 'message)")).string,
    );
    try std.testing.expectError(
        error.RuntimeError,
        vm.evalStr(Val, std.testing.allocator, "(struct-get x 'does-not-exist)"),
    );
}

test "struct get with nonexistant field fails" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try vm.evalStr(void, std.testing.allocator, "(define x (struct 'id 0 'message \"hello world\"))");
    try std.testing.expectError(
        error.RuntimeError,
        vm.evalStr(Val, std.testing.allocator, "(struct-get x 'does-not-exist)"),
    );
}

test "can keep alive" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr(Val, std.testing.allocator, "\"test\"");
    try std.testing.expectEqualStrings("test", actual.string);
    try vm.keepAlive(actual);
    defer vm.allowDeath(actual);
    try vm.runGc();
    try std.testing.expectEqualStrings("test", actual.string);
}
