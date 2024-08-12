const Val = @import("val.zig").Val;
const Vm = @import("Vm.zig");
const ByteCode = @import("ByteCode.zig");
const Error = Val.NativeFn.Error;
const std = @import("std");

const apply_bytecode_instructions = [_]ByteCode.Instruction{ .unwrap_list, .{ .eval = 0 }, .ret };

pub fn registerAll(vm: *Vm) !void {
    try vm.global_module.setVal(vm, "%define", .{ .native_fn = .{ .impl = define } });
    try vm.global_module.setVal(vm, "list", .{ .native_fn = .{ .impl = list } });
    try vm.global_module.setVal(vm, "first", .{ .native_fn = .{ .impl = first } });
    try vm.global_module.setVal(vm, "rest", .{ .native_fn = .{ .impl = rest } });
    try vm.global_module.setVal(vm, "len", .{ .native_fn = .{ .impl = len } });
    try vm.global_module.setVal(vm, "+", .{ .native_fn = .{ .impl = add } });
    try vm.global_module.setVal(vm, "-", .{ .native_fn = .{ .impl = subtract } });
    try vm.global_module.setVal(vm, "*", .{ .native_fn = .{ .impl = multiply } });
    try vm.global_module.setVal(vm, "/", .{ .native_fn = .{ .impl = divide } });
    try vm.global_module.setVal(vm, "<", .{ .native_fn = .{ .impl = less } });
    try vm.global_module.setVal(vm, ">", .{ .native_fn = .{ .impl = greater } });

    const apply_bytecode = try vm.memory_manager.allocateByteCode();
    apply_bytecode.* = .{
        .name = try vm.memory_manager.allocator.dupe(u8, "apply"),
        .arg_count = 2,
        .instructions = std.ArrayListUnmanaged(ByteCode.Instruction){
            .items = try vm.memory_manager.allocator.dupe(
                ByteCode.Instruction,
                &apply_bytecode_instructions,
            ),
            .capacity = apply_bytecode_instructions.len,
        },
    };
    try vm.global_module.setVal(vm, "apply", .{ .bytecode = apply_bytecode });
}

fn define(vm: *Vm, vals: []const Val) Error!Val {
    if (vals.len != 2) return Error.ArrityError;
    switch (vals[0]) {
        .symbol => |s| {
            vm.global_module.setVal(vm, s, vals[1]) catch return Error.RuntimeError;
        },
        else => return Error.TypeError,
    }
    return .none;
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

fn less_impl(vals: []const Val) Error!bool {
    if (vals.len > 1) {
        for (vals[0 .. vals.len - 1], vals[1..]) |a, b| {
            switch (a) {
                .int => |i| switch (b) {
                    .int => |other| if (i >= other) return false,
                    .float => |other| if (@as(f64, @floatFromInt(i)) >= other) return false,
                    else => return Error.TypeError,
                },
                .float => |f| switch (b) {
                    .int => |other| if (f >= @as(f64, @floatFromInt(other))) return false,
                    .float => |other| if (f >= other) return false,
                    else => return Error.TypeError,
                },
                else => return Error.TypeError,
            }
        }
    }
    return true;
}

fn less(_: *Vm, vals: []const Val) Error!Val {
    return .{ .boolean = try less_impl(vals) };
}

fn greater_impl(vals: []const Val) Error!bool {
    if (vals.len > 1) {
        for (vals[0 .. vals.len - 1], vals[1..]) |a, b| {
            switch (a) {
                .int => |i| switch (b) {
                    .int => |other| if (i <= other) return false,
                    .float => |other| if (@as(f64, @floatFromInt(i)) <= other) return false,
                    else => return Error.TypeError,
                },
                .float => |f| switch (b) {
                    .int => |other| if (f <= @as(f64, @floatFromInt(other))) return false,
                    .float => |other| if (f <= other) return false,
                    else => return Error.TypeError,
                },
                else => return Error.TypeError,
            }
        }
    }
    return true;
}

fn greater(_: *Vm, vals: []const Val) Error!Val {
    return .{ .boolean = try greater_impl(vals) };
}

test "register_all does not fail" {
    var vm = try Vm.init(std.testing.allocator);
    try registerAll(&vm);
    defer vm.deinit();
}
