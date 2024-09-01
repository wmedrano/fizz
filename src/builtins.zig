const ByteCode = @import("ByteCode.zig");
const Error = Val.NativeFn.Error;
const MemoryManager = @import("MemoryManager.zig");
const Val = @import("val.zig").Val;
const Env = @import("Env.zig");
const Vm = @import("Vm.zig");
const std = @import("std");

pub fn registerAll(env: *Env) !void {
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
        .symbol => |x| return x.id == b.symbol.id,
        .list => |x| {
            if (x.len != b.list.len) return true;
            for (x, b.list) |a_item, b_item| {
                if (!try equalImpl(a_item, b_item)) return false;
            }
            return true;
        },
        .structV => |x| {
            if (x.map.count() != b.structV.map.count()) return false;
            var iter = x.map.iterator();
            while (iter.next()) |a_entry| {
                const b_val = b.structV.map.get(a_entry.key_ptr.*) orelse return false;
                if (!try equalImpl(a_entry.value_ptr.*, b_val)) return false;
            }
            return true;
        },
        .bytecode => |x| return x == b.bytecode,
        .native_fn => |x| return x.impl == b.native_fn.impl,
    }
}

fn equal(_: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    if (vals[0].tag() != vals[1].tag()) return Error.TypeError;
    return .{ .boolean = try equalImpl(vals[0], vals[1]) };
}

fn modules(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 0) return Error.ArrityError;
    const module_count = 1 + vm.env.modules.count();
    var ret = vm.env.memory_manager.allocateListOfNone(module_count) catch return Error.RuntimeError;
    ret[0] = vm.env.memory_manager.allocateStringVal(vm.env.global_module.name) catch return Error.RuntimeError;

    var modules_iter = vm.env.modules.keyIterator();
    var idx: usize = 0;
    while (modules_iter.next()) |m| {
        idx += 1;
        ret[idx] = vm.env.memory_manager.allocateStringVal(m.*) catch return Error.RuntimeError;
    }

    return .{ .list = ret };
}

fn do(_: *Vm, vals: []const Val) Error!Val {
    if (vals.len == 0) return .none;
    return vals[vals.len - 1];
}

fn apply(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const args = switch (vals[1]) {
        .list => |lst| lst,
        else => return Error.TypeError,
    };
    const res = vm.evalNoReset(vals[0], args) catch |err| switch (err) {
        Error.ArrityError => return Error.ArrityError,
        Error.RuntimeError => return Error.RuntimeError,
        Error.TypeError => return Error.TypeError,
        else => return Error.RuntimeError,
    };
    return res;
}

fn toStr(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .string => return vals[0],
        else => {},
    }
    var buff = std.ArrayList(u8).init(vm.valAllocator());
    defer buff.deinit();
    const formatter = vals[0].formatter(vm);
    buff.writer().print("{any}", .{formatter}) catch return Error.RuntimeError;
    return vm.env.memory_manager.allocateStringVal(buff.items) catch return Error.RuntimeError;
}

fn strLen(_: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .string => |s| return Val{ .int = @intCast(s.len) },
        else => return Error.TypeError,
    }
}

fn strConcat(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    var buff = std.ArrayList(u8).init(vm.valAllocator());
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
    const v = vm.env.memory_manager.allocateStringVal(buff.items) catch return Error.RuntimeError;
    return v;
}

fn strSubstr(vm: *Vm, vals: []const Val) Error!Val {
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
    if (start == end) return vm.env.memory_manager.allocateStringVal("") catch return Error.RuntimeError;
    const substr = str[@intCast(start)..@intCast(end)];
    const v = vm.env.memory_manager.allocateStringVal(substr) catch return Error.RuntimeError;
    return v;
}

fn makeStruct(vm: *Vm, vals: []const Val) Error!Val {
    const field_count = vals.len / 2;
    if (field_count * 2 != vals.len) return Error.ArrityError;
    for (0..field_count) |idx| {
        switch (vals[idx * 2]) {
            .symbol => {},
            else => return Error.TypeError,
        }
    }
    const new_struct = vm.env.memory_manager.allocateStruct() catch return Error.RuntimeError;
    new_struct.map.ensureTotalCapacity(vm.valAllocator(), @intCast(field_count)) catch return Error.RuntimeError;
    for (0..field_count) |idx| {
        const name_idx = idx * 2;
        const val_idx = name_idx + 1;
        switch (vals[name_idx]) {
            .symbol => |k| {
                new_struct.map.put(vm.valAllocator(), k, vals[val_idx]) catch return Error.RuntimeError;
            },
            else => unreachable,
        }
    }
    return .{ .structV = new_struct };
}

fn structSet(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 3) return Error.ArrityError;
    const struct_val = switch (vals[0]) {
        .structV => |m| m,
        else => return Error.TypeError,
    };
    const sym = switch (vals[1]) {
        .symbol => |s| s,
        else => return Error.TypeError,
    };
    if (struct_val.map.getEntry(sym)) |entry| {
        entry.value_ptr.* = vals[2];
        return .none;
    }
    struct_val.map.put(vm.valAllocator(), sym, vals[2]) catch return Error.RuntimeError;
    return .none;
}

fn structGet(_: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    const struct_val = switch (vals[0]) {
        .structV => |m| m,
        else => return Error.TypeError,
    };
    const sym = switch (vals[1]) {
        .symbol => |s| s,
        else => return Error.TypeError,
    };
    const v = struct_val.map.get(sym) orelse return Error.RuntimeError;
    return v;
}

fn list(vm: *Vm, vals: []const Val) Error!Val {
    return vm.env.memory_manager.allocateListVal(vals) catch return Error.RuntimeError;
}

fn listPred(_: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 1) return Error.ArrityError;
    switch (vals[0]) {
        .list => return .{ .boolean = true },
        else => return .{ .boolean = false },
    }
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
            return vm.env.memory_manager.allocateListVal(lst[1..]) catch return Error.RuntimeError;
        },
        else => return Error.TypeError,
    }
}

fn nth(_: *Vm, vals: []const Val) Error!Val {
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

fn map(vm: *Vm, vals: []const Val) Error!Val {
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
    const ret = vm.env.memory_manager.allocateListOfNone(input_list.len) catch return Error.RuntimeError;
    vm.keepAlive(.{ .list = ret }) catch return Error.RuntimeError;
    defer vm.allowDeath(.{ .list = ret });
    for (input_list, 0..input_list.len) |input, idx| {
        ret[idx] = vm.evalNoReset(func, &[1]Val{input}) catch return Error.RuntimeError;
    }
    return .{ .list = ret };
}

fn filter(vm: *Vm, vals: []const Val) Error!Val {
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

    var keep_values = std.ArrayList(Val).initCapacity(vm.valAllocator(), input_list.len) catch return Error.RuntimeError;
    defer keep_values.deinit();
    for (input_list) |input| {
        const keep = vm.evalNoReset(func, &[1]Val{input}) catch return Error.RuntimeError;
        if (vm.toZig(bool, vm.valAllocator(), keep) catch return Error.RuntimeError) {
            keep_values.append(input) catch return Error.RuntimeError;
        }
    }

    const ret = vm.env.memory_manager.allocateListVal(keep_values.items) catch return Error.RuntimeError;
    return ret;
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
    try registerAll(&vm.env);
    defer vm.deinit();
}
