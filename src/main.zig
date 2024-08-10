const std = @import("std");
const Vm = @import("vm.zig").Vm;
const Ir = @import("ir.zig").Ir;
const compile = @import("compiler.zig").compile;

pub fn main() !void {
    var base_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = base_allocator.allocator();
    var vm = try Vm(.{}).init(allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const input = try std.fs.cwd().readFileAlloc(arena.allocator(), "/dev/stdin", 1024 * 1024);
    const ir = try Ir.initStrExpr(arena.allocator(), input);
    const bytecode = try compile(&vm.memory_manager, ir);
    _ = arena.reset(.free_all);

    const res = try vm.eval(bytecode);
    std.debug.print("Result: {any}\n", .{res});
    try vm.runGc();
}
