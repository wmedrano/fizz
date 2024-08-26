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
        \\$5: "------------------------------------------------------------"
        \\$6: "test functions"
        \\$7: 31400
        \\$8: 31400
        \\$9: "------------------------------------------------------------"
        \\$10: "test strings"
        \\$11: "0123"
        \\$12: 4
        \\$13: ""
        \\$14: "01"
        \\$15: ""
        \\$16: "3"
        \\$17: "------------------------------------------------------------"
        \\$18: "test lists"
        \\$19: 1
        \\$20: (2 3 4)
        \\$21: (3 4)
        \\$22: 4
        \\$23: (2 3 4 5)
        \\$24: (1 2)
        \\$25: "------------------------------------------------------------"
        \\$26: "test structs"
        \\$27: (struct 'id 0 'hello "world")
        \\$28: (struct 'id 100 'hello "world")
        \\$29: "world"
        \\$30: "------------------------------------------------------------"
        \\$31: "test fib"
        \\$32: <function >
        \\$33: 75025
        \\$34: "------------------------------------------------------------"
        \\$35: "test equal"
        \\$36: true
        \\$37: true
        \\$38: "------------------------------------------------------------"
        \\$39: "test modules"
        \\$40: ("*global*" "*test*" "/dev/null")
        \\$41: "------------------------------------------------------------"
        \\
    ;
    try std.testing.expectEqualStrings(expected, actual);
}

fn runAst(allocator: std.mem.Allocator, writer: anytype, vm: *Vm, expr_number: *usize, ast: *const Ast.Node) !void {
    var compiler = try Compiler.initModule(
        allocator,
        &vm.env,
        try vm.env.getOrCreateModule(.{ .name = "*test*" }),
    );
    defer compiler.deinit();
    const ir = try Ir.init(allocator, &[1]Ast.Node{ast.*});
    defer ir.deinit(allocator);
    const bytecode = try compiler.compile(ir);
    const res = try vm.evalFuncVal(bytecode, &.{});
    if (res.tag() != .none) {
        try writer.print("${d}: {any}\n", .{ expr_number.*, res });
        expr_number.* += 1;
    }
    try vm.env.runGc();
}