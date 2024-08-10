const Val = @import("val.zig").Val;
const Error = Val.NativeFn.Error;

pub fn registerAll(vm: anytype) !void {
    try vm.defineVal("+", .{ .native_fn = .{ .impl = add } });
    try vm.defineVal("-", .{ .native_fn = .{ .impl = subtract } });
    try vm.defineVal("*", .{ .native_fn = .{ .impl = multiply } });
    try vm.defineVal("/", .{ .native_fn = .{ .impl = divide } });
}

fn add(vals: []const Val) Error!Val {
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

fn subtract(vals: []const Val) Error!Val {
    switch (vals.len) {
        0 => return error.RuntimeError,
        1 => return try negate(vals[0]),
        else => {
            const rest = try negate(try add(vals[1..]));
            return try add(&[2]Val{ vals[0], rest });
        },
    }
}

fn multiply(vals: []const Val) Error!Val {
    var int_product: i64 = 0;
    var float_product: f64 = 0.0;
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

fn divide(vals: []const Val) Error!Val {
    switch (vals.len) {
        0 => return error.RuntimeError,
        1 => return try reciprocal(vals[0]),
        else => {
            const divisor = try multiply(vals[1..]);
            return try multiply(&[2]Val{
                vals[0],
                try reciprocal(divisor),
            });
        },
    }
}
