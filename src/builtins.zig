const Val = @import("val.zig").Val;
const Vm = @import("Vm.zig");
const ByteCode = @import("ByteCode.zig");
const Error = Val.NativeFn.Error;
const std = @import("std");

pub fn registerAll(vm: *Vm) !void {
    try vm.global_module.setVal(vm, "%define%", .{ .native_fn = .{ .impl = define } });
    try vm.global_module.setVal(vm, "%modules%", .{ .native_fn = .{ .impl = modules } });
    try vm.global_module.setVal(vm, "apply", .{ .native_fn = .{ .impl = apply } });
    try vm.global_module.setVal(vm, "list", .{ .native_fn = .{ .impl = list } });
    try vm.global_module.setVal(vm, "len", .{ .native_fn = .{ .impl = len } });
    try vm.global_module.setVal(vm, "first", .{ .native_fn = .{ .impl = first } });
    try vm.global_module.setVal(vm, "rest", .{ .native_fn = .{ .impl = rest } });
    try vm.global_module.setVal(vm, "+", .{ .native_fn = .{ .impl = add } });
    try vm.global_module.setVal(vm, "-", .{ .native_fn = .{ .impl = subtract } });
    try vm.global_module.setVal(vm, "*", .{ .native_fn = .{ .impl = multiply } });
    try vm.global_module.setVal(vm, "/", .{ .native_fn = .{ .impl = divide } });
    try vm.global_module.setVal(vm, "<", .{ .native_fn = .{ .impl = less } });
    try vm.global_module.setVal(vm, "<=", .{ .native_fn = .{ .impl = lessEq } });
    try vm.global_module.setVal(vm, ">", .{ .native_fn = .{ .impl = greater } });
    try vm.global_module.setVal(vm, ">=", .{ .native_fn = .{ .impl = greaterEq } });
}

fn define(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const module = vm.frames.items[vm.frames.items.len - 1].bytecode.module;
    switch (vals[0]) {
        .symbol => |s| {
            module.setVal(vm, s, vals[1]) catch return Error.RuntimeError;
        },
        else => return Error.TypeError,
    }
    return .none;
}

fn modules(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 0) return Error.ArrityError;
    const module_count = 1 + vm.modules.count();
    var ret = vm.memory_manager.allocateUninitializedList(module_count) catch return Error.RuntimeError;
    ret[0] = vm.memory_manager.allocateStringVal(vm.global_module.name) catch return Error.RuntimeError;

    var modules_iter = vm.modules.keyIterator();
    var idx: usize = 0;
    while (modules_iter.next()) |m| {
        idx += 1;
        ret[idx] = vm.memory_manager.allocateStringVal(m.*) catch return Error.RuntimeError;
    }

    return .{ .list = ret };
}

fn apply(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const args = switch (vals[1]) {
        .list => |lst| lst,
        else => return Error.TypeError,
    };
    const res = vm.eval(vals[0], args) catch |err| switch (err) {
        Error.ArrityError => return Error.ArrityError,
        Error.RuntimeError => return Error.RuntimeError,
        Error.TypeError => return Error.TypeError,
        else => return Error.RuntimeError,
    };
    return res;
}

fn list(vm: *Vm, vals: []const Val) Error!Val {
    return vm.memory_manager.allocateListVal(vals) catch return Error.RuntimeError;
}

fn first(_: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => |lst| return lst[0],
        else => return Error.TypeError,
    }
}

fn rest(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => |lst| {
            if (lst.len == 0) return Error.RuntimeError;
            return vm.memory_manager.allocateListVal(lst[1..]) catch return Error.RuntimeError;
        },
        else => return Error.TypeError,
    }
}

fn len(_: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => |lst| return .{ .int = @intCast(lst.len) },
        else => return Error.TypeError,
    }
}

fn add(_: *Vm, vals: []const Val) Error!Val {
    var int_sum: i64 = 0;
    var float_sum: f64 = 0.0;
    var has_float = false;
    for (vals) |v| {
        switch (v) {
            .int => |n| int_sum += n,
            .float => |n| {
                float_sum += n;
                has_float = true;
            },
            else => return error.TypeError,
        }
    }
    if (has_float) {
        return .{ .float = float_sum + @as(f64, @floatFromInt(int_sum)) };
    }
    return .{ .int = int_sum };
}

fn negate(v: Val) Error!Val {
    switch (v) {
        .int => |i| return .{ .int = -i },
        .float => |f| return .{ .float = -f },
        else => return error.TypeError,
    }
}

fn subtract(vm: *Vm, vals: []const Val) Error!Val {
    switch (vals.len) {
        0 => return error.ArrityError,
        1 => return try negate(vals[0]),
        else => {
            const neg = try negate(try add(vm, vals[1..]));
            return try add(vm, &[2]Val{ vals[0], neg });
        },
    }
}

fn multiply(_: *Vm, vals: []const Val) Error!Val {
    var int_product: i64 = 1;
    var float_product: f64 = 1.0;
    var has_float = false;
    for (vals) |v| {
        switch (v) {
            .int => |n| int_product *= n,
            .float => |n| {
                float_product *= n;
                has_float = true;
            },
            else => return error.TypeError,
        }
    }
    if (has_float) {
        return .{ .float = float_product * @as(f64, @floatFromInt(int_product)) };
    }
    return .{ .int = int_product };
}

fn reciprocal(v: Val) Error!Val {
    switch (v) {
        .int => |i| return .{ .float = 1.0 / @as(f64, @floatFromInt(i)) },
        .float => |f| return .{ .float = 1.0 / f },
        else => return error.TypeError,
    }
}

fn divide(vm: *Vm, vals: []const Val) Error!Val {
    switch (vals.len) {
        0 => return error.ArrityError,
        1 => return try reciprocal(vals[0]),
        else => {
            const divisor = try multiply(vm, vals[1..]);
            return try multiply(vm, &[2]Val{
                vals[0],
                try reciprocal(divisor),
            });
        },
    }
}

fn numbersAreOrdered(vals: []const Val, comptime pred: fn (a: anytype, b: anytype) bool) Error!bool {
    if (vals.len > 1) {
        for (vals[0 .. vals.len - 1], vals[1..]) |a, b| {
            switch (a) {
                .int => |self| switch (b) {
                    .int => |other| if (!pred(self, other)) return false,
                    .float => |other| if (!pred(@as(f64, @floatFromInt(self)), other)) return false,
                    else => return Error.TypeError,
                },
                .float => |self| switch (b) {
                    .int => |other| if (!pred(self, @as(f64, @floatFromInt(other)))) return false,
                    .float => |other| if (!pred(self, other)) return false,
                    else => return Error.TypeError,
                },
                else => return Error.TypeError,
            }
        }
    }
    return true;
}

fn less(_: *Vm, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a < b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

fn lessEq(_: *Vm, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a <= b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

fn greater(_: *Vm, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a > b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

fn greaterEq(_: *Vm, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a >= b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

test "register_all does not fail" {
    var vm = try Vm.init(std.testing.allocator);
    try registerAll(&vm);
    defer vm.deinit();
}
