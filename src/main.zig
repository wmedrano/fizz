const std = @import("std");
const Ast = @import("Ast.zig");
const Vm = @import("Vm.zig");
const Ir = @import("ir.zig").Ir;
const Compiler = @import("Compiler.zig");

pub fn main() !void {
    const input = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, "main.fizz", 1024 * 1024);
    defer std.heap.page_allocator.free(input);
    const stdout = std.io.getStdOut();
    try runScript(stdout.writer(), input);
}

fn runScript(writer: anytype, script_contents: []const u8) !void {
    var base_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = base_allocator.allocator();
    var vm = try Vm.init(allocator);
    defer vm.deinit();

    var ast_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer ast_arena.deinit();
    const ast = try Ast.initWithStr(ast_arena.allocator(), script_contents);
    var ir_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer ir_arena.deinit();
    for (1..ast.asts.len + 1, ast.asts) |idx, node| {
        var compiler = Compiler{ .vm = &vm };
        const ir = try Ir.init(ir_arena.allocator(), &node);
        const bytecode = try compiler.compile(ir);
        const res = try vm.eval(bytecode, &.{});
        std.debug.print("${d}: {any}\n", .{ idx, res });
        _ = ir_arena.reset(.retain_capacity);
        try vm.runGc();
    }
    try writer.print("gc_duration: {d}ns\n", .{vm.runtime_stats.gc_duration_nanos});
}

test "empty input" {
    try runScript(std.io.null_writer, "");
}
