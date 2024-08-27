const std = @import("std");
const Ast = @import("Ast.zig");
const Vm = @import("Vm.zig");
const Ir = @import("ir.zig").Ir;
const Compiler = @import("Compiler.zig");

test "golden test" {
    const input = @embedFile("golden_test.fizz");

    var writer_buffer = std.ArrayList(u8).init(std.testing.allocator);
    var writer = writer_buffer.writer();
    defer writer_buffer.deinit();

    var base_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = base_allocator.allocator();
    var vm = try Vm.init(allocator);
    defer vm.deinit();

    var ast = try Ast.initWithStr(std.testing.allocator, input);
    defer ast.deinit();
    var expr_number: usize = 1;
    for (ast.asts) |node| {
        try runAst(std.testing.allocator, &writer, &vm, &expr_number, &node);
    }

    const actual = writer_buffer.items;
    const expected =
        \\$1: "------------------------------------------------------------"
        \\$2: "test define"
        \\$3: "defined once"
        \\$4: "redefined"
        \\$5: 600
        \\$6: "------------------------------------------------------------"
        \\$7: "test functions"
        \\$8: 31400
        \\$9: 31400
        \\$10: "------------------------------------------------------------"
        \\$11: "test strings"
        \\$12: "0123"
        \\$13: 4
        \\$14: ""
        \\$15: "01"
        \\$16: ""
        \\$17: "3"
        \\$18: "------------------------------------------------------------"
        \\$19: "test lists"
        \\$20: 1
        \\$21: (2 3 4)
        \\$22: (3 4)
        \\$23: 4
        \\$24: (2 3 4 5)
        \\$25: (1 2)
        \\$26: "------------------------------------------------------------"
        \\$27: "test structs"
        \\$28: (struct 'id 0 'hello "world")
        \\$29: (struct 'id 100 'hello "world")
        \\$30: "world"
        \\$31: "------------------------------------------------------------"
        \\$32: "test fib"
        \\$33: <function >
        \\$34: 75025
        \\$35: "------------------------------------------------------------"
        \\$36: "test equal"
        \\$37: true
        \\$38: true
        \\$39: "------------------------------------------------------------"
        \\$40: "test modules"
        \\$41: ("*global*" "/dev/null" "*default*")
        \\$42: "------------------------------------------------------------"
        \\
    ;
    try std.testing.expectEqualStrings(expected, actual);
}

fn runAst(allocator: std.mem.Allocator, writer: anytype, vm: *Vm, expr_number: *usize, ast: *const Ast.Node) !void {
    var compiler = try Compiler.initModule(
        allocator,
        &vm.env,
        try vm.env.getOrCreateModule(.{}),
    );
    defer compiler.deinit();
    const ir = try Ir.init(allocator, &[1]Ast.Node{ast.*});
    defer ir.deinit(allocator);
    const bytecode = try compiler.compile(ir);
    const res = try vm.eval(bytecode, &.{});
    if (res.tag() != .none) {
        try writer.print("${d}: {any}\n", .{ expr_number.*, res });
        expr_number.* += 1;
    }
    try vm.env.runGc();
}
