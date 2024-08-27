const Val = @import("val.zig").Val;
const Environment = @import("Environment.zig");
const ByteCode = @import("ByteCode.zig");
const Error = Val.NativeFn.Error;
const std = @import("std");

pub fn registerAll(env: *Environment) !void {
    try env.global_module.setVal(env, "*modules*", .{ .native_fn = .{ .impl = modules } });
    try env.global_module.setVal(env, "do", .{ .native_fn = .{ .impl = do } });
    try env.global_module.setVal(env, "apply", .{ .native_fn = .{ .impl = apply } });
    try env.global_module.setVal(env, "->str", .{ .native_fn = .{ .impl = toStr } });
    try env.global_module.setVal(env, "=", .{ .native_fn = .{ .impl = equal } });
    try env.global_module.setVal(env, "str-len", .{ .native_fn = .{ .impl = strLen } });
    try env.global_module.setVal(env, "str-concat", .{ .native_fn = .{ .impl = strConcat } });
    try env.global_module.setVal(env, "str-substr", .{ .native_fn = .{ .impl = strSubstr } });
    try env.global_module.setVal(env, "struct", .{ .native_fn = .{ .impl = makeStruct } });
    try env.global_module.setVal(env, "struct-set!", .{ .native_fn = .{ .impl = structSet } });
    try env.global_module.setVal(env, "struct-get", .{ .native_fn = .{ .impl = structGet } });
    try env.global_module.setVal(env, "list", .{ .native_fn = .{ .impl = list } });
    try env.global_module.setVal(env, "list?", .{ .native_fn = .{ .impl = listPred } });
    try env.global_module.setVal(env, "len", .{ .native_fn = .{ .impl = len } });
    try env.global_module.setVal(env, "first", .{ .native_fn = .{ .impl = first } });
    try env.global_module.setVal(env, "rest", .{ .native_fn = .{ .impl = rest } });
    try env.global_module.setVal(env, "nth", .{ .native_fn = .{ .impl = nth } });
    try env.global_module.setVal(env, "map", .{ .native_fn = .{ .impl = map } });
    try env.global_module.setVal(env, "filter", .{ .native_fn = .{ .impl = filter } });
    try env.global_module.setVal(env, "+", .{ .native_fn = .{ .impl = add } });
    try env.global_module.setVal(env, "-", .{ .native_fn = .{ .impl = subtract } });
    try env.global_module.setVal(env, "*", .{ .native_fn = .{ .impl = multiply } });
    try env.global_module.setVal(env, "/", .{ .native_fn = .{ .impl = divide } });
    try env.global_module.setVal(env, "<", .{ .native_fn = .{ .impl = less } });
    try env.global_module.setVal(env, "<=", .{ .native_fn = .{ .impl = lessEq } });
    try env.global_module.setVal(env, ">", .{ .native_fn = .{ .impl = greater } });
    try env.global_module.setVal(env, ">=", .{ .native_fn = .{ .impl = greaterEq } });
}

fn equalImpl(a: Val, b: Val) Error!bool {
    if (a.tag() != b.tag()) return Error.TypeError;
    switch (a) {
        .none => return true,
        .boolean => |x| return x == b.boolean,
        .int => |x| return x == b.int,
        .float => |x| return x == b.float,
        .string => |x| return std.mem.eql(u8, x, b.string),
        .symbol => |x| return std.mem.eql(u8, x, b.symbol),
        .list => |x| {
            if (x.len != b.list.len) return true;
            for (x, b.list) |a_item, b_item| {
                if (!try equalImpl(a_item, b_item)) return false;
            }
            return true;
        },
        .structV => |x| {
            if (x.count() != b.structV.count()) return false;
            var iter = x.iterator();
            while (iter.next()) |a_entry| {
                const b_val = b.structV.get(a_entry.key_ptr.*) orelse return false;
                if (!try equalImpl(a_entry.value_ptr.*, b_val)) return false;
            }
            return true;
        },
        .bytecode => |x| return x == b.bytecode,
        .native_fn => |x| return x.impl == b.native_fn.impl,
    }
}

fn equal(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    if (vals[0].tag() != vals[1].tag()) return Error.TypeError;
    return .{ .boolean = try equalImpl(vals[0], vals[1]) };
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

fn do(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len == 0) return .none;
    return vals[vals.len - 1];
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
        .structV => |struct_map| {
            var iter = struct_map.iterator();
            try buff.appendSlice("(struct");
            while (iter.next()) |v| {
                try buff.appendSlice(" ");
                try buff.appendSlice(v.key_ptr.*);
                try buff.appendSlice(" ");
                try toStringImpl(buff, v.value_ptr.*);
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

fn toStr(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    var buff = std.ArrayList(u8).init(env.allocator());
    defer buff.deinit();
    toStringImpl(&buff, vals[0]) catch return Error.RuntimeError;
    return env.memory_manager.allocateStringVal(buff.items) catch return Error.RuntimeError;
}

fn strLen(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .string => |s| return Val{ .int = @intCast(s.len) },
        else => return Error.TypeError,
    }
}

fn strConcat(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    var buff = std.ArrayList(u8).init(env.allocator());
    defer buff.deinit();
    switch (vals[0]) {
        .list => |lst| {
            for (lst) |substr| {
                switch (substr) {
                    .string => |s| buff.appendSlice(s) catch return Error.RuntimeError,
                    else => return Error.TypeError,
                }
            }
        },
        else => return Error.TypeError,
    }
    const v = env.memory_manager.allocateStringVal(buff.items) catch return Error.RuntimeError;
    return v;
}

fn strSubstr(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 3) return Error.ArrityError;
    const str = switch (vals[0]) {
        .string => |s| s,
        else => return Error.TypeError,
    };
    const start = switch (vals[1]) {
        .int => |i| i,
        else => return Error.TypeError,
    };
    if (start < 0 or start >= str.len) return Error.RuntimeError;
    const end = switch (vals[2]) {
        .int => |i| i,
        else => return Error.TypeError,
    };
    if (end < start or end > str.len) return Error.RuntimeError;
    if (start == str.len and start != end) return Error.RuntimeError;
    if (start == end) return env.memory_manager.allocateStringVal("") catch return Error.RuntimeError;
    const substr = str[@intCast(start)..@intCast(end)];
    const v = env.memory_manager.allocateStringVal(substr) catch return Error.RuntimeError;
    return v;
}

fn makeStruct(env: *Environment, vals: []const Val) Error!Val {
    const field_count = vals.len / 2;
    if (field_count * 2 != vals.len) return Error.ArrityError;
    for (0..field_count) |idx| {
        switch (vals[idx * 2]) {
            .symbol => {},
            else => return Error.TypeError,
        }
    }
    const fields = env.memory_manager.allocateStruct() catch return Error.RuntimeError;
    fields.ensureTotalCapacity(env.allocator(), @intCast(field_count)) catch return Error.RuntimeError;
    for (0..field_count) |idx| {
        const name_idx = idx * 2;
        const val_idx = name_idx + 1;
        switch (vals[name_idx]) {
            .symbol => |s| {
                const k = env.allocator().dupe(u8, s) catch return Error.RuntimeError;
                errdefer env.allocator().free(k);
                fields.put(env.allocator(), k, vals[val_idx]) catch return Error.RuntimeError;
            },
            else => unreachable,
        }
    }
    return .{ .structV = fields };
}

fn structSet(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 3) return Error.ArrityError;
    const struct_map = switch (vals[0]) {
        .structV => |m| m,
        else => return Error.TypeError,
    };
    const sym = switch (vals[1]) {
        .symbol => |s| s,
        else => return Error.TypeError,
    };
    if (struct_map.getKey(sym)) |k| {
        struct_map.put(env.allocator(), k, vals[2]) catch return Error.RuntimeError;
        return .none;
    }
    const sym_key = env.allocator().dupe(u8, sym) catch return Error.RuntimeError;
    errdefer env.allocator().free(sym_key);
    struct_map.put(env.allocator(), sym_key, vals[2]) catch return Error.RuntimeError;
    return .none;
}

fn structGet(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const struct_map = switch (vals[0]) {
        .structV => |m| m,
        else => return Error.TypeError,
    };
    const sym = switch (vals[1]) {
        .symbol => |s| s,
        else => return Error.TypeError,
    };
    const v = struct_map.get(sym) orelse return Error.RuntimeError;
    return v;
}

fn list(env: *Environment, vals: []const Val) Error!Val {
    return env.memory_manager.allocateListVal(vals) catch return Error.RuntimeError;
}

fn listPred(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => return .{ .boolean = true },
        else => return .{ .boolean = false },
    }
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

fn nth(_: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const lst = switch (vals[0]) {
        .list => |lst| lst,
        else => return Error.TypeError,
    };
    const idx = switch (vals[1]) {
        .int => |i| i,
        else => return Error.TypeError,
    };
    if (idx < lst.len) return lst[@intCast(idx)] else return Error.RuntimeError;
}

fn map(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const func = switch (vals[0]) {
        .native_fn => vals[0],
        .bytecode => vals[0],
        else => return Error.TypeError,
    };
    const input_list = switch (vals[1]) {
        .list => |lst| lst,
        else => return Error.TypeError,
    };
    const ret = env.memory_manager.allocateUninitializedList(input_list.len) catch return Error.RuntimeError;
    for (input_list, 0..input_list.len) |input, idx| {
        ret[idx] = env.evalNoReset(func, &[1]Val{input}) catch return Error.RuntimeError;
    }
    return .{ .list = ret };
}

fn filter(env: *Environment, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const func = switch (vals[0]) {
        .native_fn => vals[0],
        .bytecode => vals[0],
        else => return Error.TypeError,
    };
    const input_list = switch (vals[1]) {
        .list => |lst| lst,
        else => return Error.TypeError,
    };

    var keep_values = std.ArrayList(Val).initCapacity(env.allocator(), input_list.len) catch return Error.RuntimeError;
    defer keep_values.deinit();
    for (input_list) |input| {
        const keep = env.evalNoReset(func, &[1]Val{input}) catch return Error.RuntimeError;
        if (env.toZig(bool, env.allocator(), keep) catch return Error.RuntimeError) {
            keep_values.append(input) catch return Error.RuntimeError;
        }
    }

    const ret = env.memory_manager.allocateListVal(keep_values.items) catch return Error.RuntimeError;
    return ret;
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
