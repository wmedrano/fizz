const Val = @import("val.zig").Val;
const Environment = @import("Environment.zig");
const ByteCode = @import("ByteCode.zig");
const Error = Val.NativeFn.Error;
const std = @import("std");

pub fn registerAll(env: *Environment) !void {
    try env.global_module.setVal(env, "%define%", .{ .native_fn = .{ .impl = define } });
    try env.global_module.setVal(env, "%modules%", .{ .native_fn = .{ .impl = modules } });
    try env.global_module.setVal(env, "apply", .{ .native_fn = .{ .impl = apply } });
    try env.global_module.setVal(env, "->string", .{ .native_fn = .{ .impl = toString } });
    try env.global_module.setVal(env, "list", .{ .native_fn = .{ .impl = list } });
    try env.global_module.setVal(env, "len", .{ .native_fn = .{ .impl = len } });
    try env.global_module.setVal(env, "first", .{ .native_fn = .{ .impl = first } });
    try env.global_module.setVal(env, "rest", .{ .native_fn = .{ .impl = rest } });
    try env.global_module.setVal(env, "+", .{ .native_fn = .{ .impl = add } });
    try env.global_module.setVal(env, "-", .{ .native_fn = .{ .impl = subtract } });
    try env.global_module.setVal(env, "*", .{ .native_fn = .{ .impl = multiply } });
    try env.global_module.setVal(env, "/", .{ .native_fn = .{ .impl = divide } });
    try env.global_module.setVal(env, "<", .{ .native_fn = .{ .impl = less } });
    try env.global_module.setVal(env, "<=", .{ .native_fn = .{ .impl = lessEq } });
    try env.global_module.setVal(env, ">", .{ .native_fn = .{ .impl = greater } });
    try env.global_module.setVal(env, ">=", .{ .native_fn = .{ .impl = greaterEq } });
}

fn define(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const module = env.frames.items[env.frames.items.len - 1].bytecode.module;
    switch (vals[0]) {
        .symbol => |s| {
            module.setVal(env, s, vals[1]) catch return Error.RuntimeError;
        },
        else => return Error.TypeError,
    }
    return .none;
}

fn modules(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 0) return Error.ArrityError;
    const module_count = 1 + env.modules.count();
    var ret = env.memory_manager.allocateUninitializedList(module_count) catch return Error.RuntimeError;
    ret[0] = env.memory_manager.allocateStringVal(env.global_module.name) catch return Error.RuntimeError;

    var modules_iter = env.modules.keyIterator();
    var idx: usize = 0;
    while (modules_iter.next()) |m| {
        idx += 1;
        ret[idx] = env.memory_manager.allocateStringVal(m.*) catch return Error.RuntimeError;
    }

    return .{ .list = ret };
}

fn apply(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const args = switch (vals[1]) {
        .list => |lst| lst,
        else => return Error.TypeError,
    };
    const res = env.evalNoReset(vals[0], args) catch |err| switch (err) {
        Error.ArrityError => return Error.ArrityError,
        Error.RuntimeError => return Error.RuntimeError,
        Error.TypeError => return Error.TypeError,
        else => return Error.RuntimeError,
    };
    return res;
}

fn toStringImpl(buff: *std.ArrayList(u8), val: Val) !void {
    switch (val) {
        .none => try buff.appendSlice("none"),
        .boolean => |b| try buff.appendSlice(if (b) "true" else "false"),
        .int => |i| try std.fmt.format(buff.writer(), "{d}", .{i}),
        .float => |f| try std.fmt.format(buff.writer(), "{d}", .{f}),
        .string => |s| try buff.appendSlice(s),
        .symbol => |s| try std.fmt.format(buff.writer(), "'{s}", .{s}),
        .list => |lst| {
            try buff.appendSlice("(");
            for (lst, 0..) |v, idx| {
                if (idx > 0) try buff.appendSlice(" ");
                try toStringImpl(buff, v);
            }
            try buff.appendSlice(")");
        },
        .bytecode => |bc| try std.fmt.format(
            buff.writer(),
            "<function {s}>",
            .{if (bc.name.len == 0) "_" else bc.name},
        ),
        .native_fn => |nf| try std.fmt.format(buff.writer(), "<native-func #{d}>", .{@intFromPtr(nf.impl)}),
    }
}

fn toString(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    var buff = std.ArrayList(u8).init(env.allocator());
    defer buff.deinit();
    toStringImpl(&buff, vals[0]) catch return Error.RuntimeError;
    return env.memory_manager.allocateStringVal(buff.items) catch return Error.RuntimeError;
}

fn list(env: *Environment, vals: []const Val) Error!Val {
    return env.memory_manager.allocateListVal(vals) catch return Error.RuntimeError;
}

fn first(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => |lst| return lst[0],
        else => return Error.TypeError,
    }
}

fn rest(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => |lst| {
            if (lst.len == 0) return Error.RuntimeError;
            return env.memory_manager.allocateListVal(lst[1..]) catch return Error.RuntimeError;
        },
        else => return Error.TypeError,
    }
}

fn len(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => |lst| return .{ .int = @intCast(lst.len) },
        else => return Error.TypeError,
    }
}

fn add(_: *Environment, vals: []const Val) Error!Val {
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

fn subtract(env: *Environment, vals: []const Val) Error!Val {
    switch (vals.len) {
        0 => return error.ArrityError,
        1 => return try negate(vals[0]),
        else => {
            const neg = try negate(try add(env, vals[1..]));
            return try add(env, &[2]Val{ vals[0], neg });
        },
    }
}

fn multiply(_: *Environment, vals: []const Val) Error!Val {
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

fn divide(env: *Environment, vals: []const Val) Error!Val {
    switch (vals.len) {
        0 => return error.ArrityError,
        1 => return try reciprocal(vals[0]),
        else => {
            const divisor = try multiply(env, vals[1..]);
            return try multiply(env, &[2]Val{
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

fn less(_: *Environment, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a < b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

fn lessEq(_: *Environment, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a <= b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

fn greater(_: *Environment, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a > b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

fn greaterEq(_: *Environment, vals: []const Val) Error!Val {
    const impl = struct {
        fn pred(a: anytype, b: anytype) bool {
            return a >= b;
        }
    };
    return .{ .boolean = try numbersAreOrdered(vals, impl.pred) };
}

test "register_all does not fail" {
    var env = try Environment.init(std.testing.allocator);
    try registerAll(&env);
    defer env.deinit();
}
