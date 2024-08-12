const Vm = @This();

const Module = @import("Module.zig");
const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const iter = @import("iter.zig");
const Compiler = @import("Compiler.zig");
const builtins = @import("builtins.zig");
const std = @import("std");

memory_manager: MemoryManager,
stack: std.ArrayListUnmanaged(Val),
frames: std.ArrayListUnmanaged(Frame),
global_module: Module,
runtime_stats: struct {
    gc_duration_nanos: u64 = 0,
},

const Frame = struct {
    bytecode: *ByteCode,
    instruction: [*]ByteCode.Instruction,
    stack_start: usize,
    ffi_boundary: bool,
};

/// Create a new virtual machine.
pub fn init(allocator: std.mem.Allocator) !Vm {
    const stack = try std.ArrayListUnmanaged(Val).initCapacity(
        allocator,
        std.mem.page_size / @sizeOf(Val),
    );
    const frames = try std.ArrayListUnmanaged(Frame).initCapacity(
        allocator,
        std.mem.page_size / @sizeOf(Frame),
    );
    var vm = Vm{
        .memory_manager = MemoryManager.init(allocator),
        .stack = stack,
        .frames = frames,
        .global_module = .{},
        .runtime_stats = .{},
    };
    try builtins.registerAll(&vm);
    return vm;
}

/// Deinitialize a virtual machine. Using self after calling deinit is invalid.
pub fn deinit(self: *Vm) void {
    self.stack.deinit(self.memory_manager.allocator);
    self.frames.deinit(self.memory_manager.allocator);
    self.global_module.deinit(self);
    self.memory_manager.deinit();
}

/// Run the garbage collector to free up memory.
pub fn runGc(self: *Vm) !void {
    try self.runGcKeepAlive(iter.EmptyIter(Val){});
}

/// Run the garbage collector to free up memory. This also keeps alive any values returned
/// by values_iterator.
pub fn runGcKeepAlive(self: *Vm, values_iterator: anytype) !void {
    var timer = try std.time.Timer.start();
    defer self.runtime_stats.gc_duration_nanos += timer.read();
    for (self.stack.items) |v| try self.memory_manager.markVal(v);
    for (self.frames.items) |f| try self.memory_manager.markVal(.{ .bytecode = f.bytecode });
    while (values_iterator.next()) |v| try self.memory_manager.markVal(v);

    var global_values = self.global_module.iterateVals();
    while (global_values.next()) |v| {
        try self.memory_manager.markVal(v);
    }

    try self.memory_manager.sweep();
}

/// Reset the state of the Vm.
///
/// TODO: Rename. This does not reset modules, only the stack and function frames.
pub fn reset(self: *Vm) void {
    self.stack.clearRetainingCapacity();
    self.frames.clearRetainingCapacity();
}

/// Evaluate a single expression from the string.
///
/// Note: Val is only valid until the next garbage collection call.
pub fn evalStr(self: *Vm, expr: []const u8) !Val {
    var arena = std.heap.ArenaAllocator.init(self.memory_manager.allocator);
    defer arena.deinit();
    const ir = try Ir.initStrExpr(arena.allocator(), expr);
    var compiler = Compiler{ .vm = self };
    const bc = try compiler.compile(ir);
    self.reset();
    return self.eval(bc, &.{});
}

/// Evaluate the function and return the result. If bc is not already owned by self, then
/// will take ownership of bc's lifecycle. This means bc.deinit() should not be called.
///
/// Note: Val is only valid until the next garbage collection call.
pub fn eval(self: *Vm, func: Val, args: []const Val) !Val {
    const stack_start = self.stack.items.len;
    switch (func) {
        .bytecode => |bc| {
            const frame = .{
                .bytecode = bc,
                .instruction = bc.instructions.items.ptr,
                .stack_start = stack_start,
                .ffi_boundary = true,
            };
            self.frames.appendAssumeCapacity(frame);
            try self.stack.appendSlice(self.memory_manager.allocator, args);
            while (try self.runNext()) {}
            if (self.stack.items.len > stack_start) {
                const ret = self.stack.pop();
                self.stack.items = self.stack.items[0..stack_start];
                return ret;
            } else {
                @setCold(true);
                return .none;
            }
        },
        .native_fn => |nf| {
            try self.stack.appendSlice(self.memory_manager.allocator, args);
            const ret = try nf.impl(self, args);
            if (self.stack.items.len > stack_start) self.stack.items = self.stack.items[0..stack_start];
            return ret;
        },
        else => return error.TypeError,
    }
}

fn runNext(self: *Vm) !bool {
    var frame = &self.frames.items[self.frames.items.len - 1];
    switch (frame.instruction[0]) {
        .get_arg => |idx| try self.executeGetArg(frame, idx),
        .push_const => |v| try self.executePushConst(v),
        .ret => {
            const should_continue = try self.executeRet();
            if (!should_continue) return false;
        },
        .deref => |s| try self.executeDeref(s),
        .eval => |n| try self.executeEval(frame, n),
        .jump => |n| frame.instruction += n,
        .jump_if => |n| if (try self.stack.pop().asBool()) {
            frame.instruction += n;
        },
    }
    frame.instruction += 1;
    return true;
}

fn executePushConst(self: *Vm, v: Val) !void {
    try self.stack.append(self.memory_manager.allocator, v);
}

fn executeDeref(self: *Vm, sym: []const u8) !void {
    const v = self.global_module.getVal(sym) orelse return error.SymbolNotFound;
    try self.stack.append(self.memory_manager.allocator, v);
}

fn executeGetArg(self: *Vm, frame: *const Frame, idx: usize) !void {
    const v = self.stack.items[frame.stack_start + idx];
    try self.stack.append(self.memory_manager.allocator, v);
}

fn executeEval(self: *Vm, frame: *const Frame, n: usize) !void {
    const norm_n: usize = if (n == 0) self.stack.items.len - frame.stack_start else n;
    const arg_count = norm_n - 1;
    const fn_idx = self.stack.items.len - norm_n;
    const func = self.stack.items[fn_idx];
    const stack_start = fn_idx + 1;
    switch (func) {
        .bytecode => |bc| {
            if (bc.arg_count != arg_count) return error.ArrityError;
            const new_frame = Frame{
                .bytecode = bc,
                .instruction = bc.instructions.items.ptr,
                .stack_start = stack_start,
                .ffi_boundary = false,
            };
            self.frames.appendAssumeCapacity(new_frame);
        },
        .native_fn => |nf| {
            self.stack.items[fn_idx] = try nf.impl(self, self.stack.items[stack_start..]);
            self.stack.items = self.stack.items[0..stack_start];
        },
        else => {
            return error.TypeError;
        },
    }
}

fn executeRet(self: *Vm) !bool {
    const old_frame = self.frames.pop();
    if (old_frame.ffi_boundary) {
        return false;
    }
    const ret = self.stack.popOrNull() orelse .none;
    self.stack.items = self.stack.items[0..old_frame.stack_start];
    self.stack.items[old_frame.stack_start - 1] = ret;
    return true;
}

test "can eval basic expression" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("4");
    try vm.runGc();
    try std.testing.expectEqual(Val{ .int = 4 }, actual);
}

test "can deref symbols" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try vm.global_module.setVal(&vm, "test", try vm.memory_manager.allocateStringVal("test-val"));
    const actual = try vm.evalStr("test");
    try std.testing.expectEqualDeep(Val{ .string = @constCast("test-val") }, actual);
}

test "lambda can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("((lambda (x) x) true)");
    try std.testing.expectEqualDeep(Val{ .boolean = true }, actual);
}

test "apply takes native function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("(apply + (list 1 2 3 4))");
    try std.testing.expectEqualDeep(Val{ .int = 10 }, actual);
}

test "apply takes bytecode function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("(apply (lambda (a b c d) (- 0 a b c d)) (list 1 2 3 4))");
    try std.testing.expectEqualDeep(Val{ .int = -10 }, actual);
}
