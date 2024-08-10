const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const iter = @import("iter.zig");
const compile = @import("compiler.zig").compile;
const builtins = @import("builtins.zig");

const std = @import("std");

pub const Options = struct {
    initial_stack_capacity: usize = 4096 / @sizeOf(Val),
    initial_frame_capacity: usize = 4096 / @sizeOf(Frame),
    enable_builtins: bool = true,
};

const Frame = struct {
    bytecode: *ByteCode,
    instruction_idx: usize,
    stack_start: usize,
};

pub const Vm = struct {
    memory_manager: MemoryManager,
    stack: std.ArrayListUnmanaged(Val),
    frames: std.ArrayListUnmanaged(Frame),
    symbols: std.StringHashMapUnmanaged(Val),

    /// Create a new virtual machine.
    pub fn init(options: Options, allocator: std.mem.Allocator) !Vm {
        const stack = try std.ArrayListUnmanaged(Val).initCapacity(
            allocator,
            options.initial_stack_capacity,
        );
        const frames = try std.ArrayListUnmanaged(Frame).initCapacity(
            allocator,
            options.initial_stack_capacity,
        );
        const symbols = std.StringHashMapUnmanaged(Val){};
        var vm = Vm{
            .memory_manager = MemoryManager.init(allocator),
            .stack = stack,
            .frames = frames,
            .symbols = symbols,
        };
        if (options.enable_builtins) {
            try builtins.registerAll(&vm);
        }
        return vm;
    }

    /// Deinitialize a virtual machine. Using self after calling deinit is invalid.
    pub fn deinit(self: *Vm) void {
        self.stack.deinit(self.memory_manager.allocator);
        self.frames.deinit(self.memory_manager.allocator);
        self.symbols.deinit(self.memory_manager.allocator);
        self.memory_manager.deinit();
    }

    /// Run the garbage collector to free up memory.
    pub fn runGc(self: *Vm) !void {
        try self.runGcKeepAlive(iter.EmptyIter(Val){});
    }

    /// Run the garbage collector to free up memory. This also keeps alive any values returned
    /// by values_iterator.
    pub fn runGcKeepAlive(self: *Vm, values_iterator: anytype) !void {
        for (self.stack.items) |v| try self.memory_manager.markVal(v);
        for (self.frames.items) |f| try self.memory_manager.markVal(.{ .bytecode = f.bytecode });
        while (values_iterator.next()) |v| try self.memory_manager.markVal(v);

        var global_values = self.symbols.iterator();
        while (global_values.next()) |entry| {
            try self.memory_manager.markVal(entry.value_ptr.*);
            try self.memory_manager.markVal(Val{ .string = entry.key_ptr.* });
        }

        try self.memory_manager.sweep();
    }

    /// Bind sym to the given val.
    ///
    /// Note: self will take ownership of freeing any memory from val.
    pub fn defineVal(self: *Vm, sym: []const u8, val: Val) !void {
        const interned_sym = try self.memory_manager.allocateString(sym);
        return self.symbols.put(self.memory_manager.allocator, interned_sym, val);
    }

    /// Evaluate a single expression from the string.
    ///
    /// Note: Val is only valid until the next garbage collection call.
    pub fn evalStr(self: *Vm, expr: []const u8) !Val {
        var arena = std.heap.ArenaAllocator.init(self.memory_manager.allocator);
        defer arena.deinit();
        const ir = try Ir.initStrExpr(arena.allocator(), expr);
        const bc = try compile(&self.memory_manager, ir);
        return self.eval(bc);
    }

    /// Evaluate the function and return the result. If bc is not already owned by self, then
    /// will take ownership of bc's lifecycle. This means bc.deinit() should not be called.
    ///
    /// Note: Val is only valid until the next garbage collection call.
    pub fn eval(self: *Vm, func: Val) !Val {
        const bc = try func.asByteCode();
        self.stack.clearRetainingCapacity();
        const frame = .{ .bytecode = bc, .instruction_idx = 0, .stack_start = 0 };
        self.frames.appendAssumeCapacity(frame);
        while (try self.runNext()) {}
        return self.stack.popOrNull() orelse .none;
    }

    fn runNext(self: *Vm) !bool {
        if (self.frames.items.len == 0) return false;
        var frame = &self.frames.items[self.frames.items.len - 1];
        const instruction = frame.bytecode.instructions.items[frame.instruction_idx];
        switch (instruction) {
            .push_const => |v| try self.stack.append(self.memory_manager.allocator, v),
            .deref => |s| {
                const v = self.symbols.get(s) orelse return error.SymbolNotFound;
                try self.stack.append(self.memory_manager.allocator, v);
            },
            .get_arg => |idx| {
                const v = self.stack.items[frame.stack_start + idx];
                try self.stack.append(self.memory_manager.allocator, v);
            },
            .eval => |n| try self.executeEval(n),
            .jump => |n| frame.instruction_idx += n,
            .jump_if => |n| if (try self.stack.pop().asBool()) {
                frame.instruction_idx += n;
            },
            .ret => if (!try self.executeRet()) return false,
        }
        frame.instruction_idx += 1;
        return true;
    }

    fn executeRet(self: *Vm) !bool {
        const old_frame = self.frames.pop();
        if (self.frames.items.len == 0) {
            return false;
        }
        const ret = self.stack.pop();
        self.stack.items = self.stack.items[0..old_frame.stack_start];
        self.stack.items[old_frame.stack_start - 1] = ret;
        return true;
    }

    fn executeEval(self: *Vm, n: usize) !void {
        const fn_idx = self.stack.items.len - n;
        const func = self.stack.items[fn_idx];
        const stack_start = fn_idx + 1;
        switch (func) {
            .bytecode => |bc| {
                const new_frame = .{
                    .bytecode = bc,
                    .instruction_idx = 0,
                    .stack_start = stack_start,
                };
                self.frames.appendAssumeCapacity(new_frame);
            },
            .native_fn => |nf| {
                self.stack.items[fn_idx] = try nf.impl(self, self.stack.items[stack_start..]);
                self.stack.items = self.stack.items[0..stack_start];
            },
            else => return error.TypeError,
        }
    }
};

test "can eval basic expression" {
    var vm = try Vm.init(.{}, std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("4");
    try vm.runGc();
    try std.testing.expectEqual(Val{ .int = 4 }, actual);
}

test "can deref symbols" {
    var vm = try Vm.init(.{}, std.testing.allocator);
    defer vm.deinit();
    try vm.defineVal("test", try vm.memory_manager.allocateStringVal("test-val"));
    const actual = try vm.evalStr("test");
    try std.testing.expectEqualDeep(Val{ .string = @constCast("test-val") }, actual);
}

test "lambda can eval" {
    var vm = try Vm.init(.{}, std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("((lambda (x) x) true)");
    try std.testing.expectEqualDeep(Val{ .boolean = true }, actual);
}
