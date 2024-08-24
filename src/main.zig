const std = @import("std");
const Ast = @import("Ast.zig");
const Vm = @import("Vm.zig");
const Ir = @import("ir.zig").Ir;
const Compiler = @import("Compiler.zig");

pub fn main() !void {
    const input = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, "main.fizz", 1024 * 1024);
    defer std.heap.page_allocator.free(input);
    const stdout = std.io.getStdOut();
    try runScript(stdout.writer(), input, false);
}

fn runScript(
    writer: anytype,
    script_contents: []const u8,
    require_determinism: bool,
) !void {
    var base_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = base_allocator.allocator();
    var vm = try Vm.init(allocator);
    defer vm.deinit();

    var ast_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer ast_arena.deinit();
    const ast = try Ast.initWithStr(ast_arena.allocator(), script_contents);
    var ir_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer ir_arena.deinit();
    var expr_number: usize = 1;
    for (ast.asts) |node| {
        try runAst(ir_arena.allocator(), writer, &vm, &expr_number, &node);
        _ = ir_arena.reset(.retain_capacity);
    }
    if (!require_determinism) {
        try writer.print("gc_duration: {d}ns\n", .{vm.env.runtime_stats.gc_duration_nanos});
    }
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
    const res = try vm.eval(bytecode, &.{});
    if (res.tag() != .none) {
        try writer.print("${d}: {any}\n", .{ expr_number.*, res });
        expr_number.* += 1;
    }
    try vm.env.runGc();
}

test "simple input" {
    var actual = std.ArrayList(u8).init(std.testing.allocator);
    defer actual.deinit();
    try runScript(actual.writer(), "(+ 1 2) (- 3.0 4.0) (< 1 2) (list \"hello\" 42) (*modules*)", true);
    try std.testing.expectEqualStrings(
        \\$1: 3
        \\$2: -1
        \\$3: true
        \\$4: ("hello" 42)
        \\$5: ("*global*" "*test*")
        \\
    , actual.items);
}
