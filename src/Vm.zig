const Vm = @This();

const Module = @import("Module.zig");
const Ast = @import("Ast.zig");
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
modules: std.StringHashMapUnmanaged(*Module),
runtime_stats: RuntimeStats,

const Error = std.mem.Allocator.Error || Val.NativeFn.Error || error{ SymbolNotFound, FileError, SyntaxError };

const RuntimeStats = struct {
    gc_duration_nanos: u64 = 0,
    function_calls: u64 = 0,
};

const Frame = struct {
    bytecode: *ByteCode,
    instruction: [*]ByteCode.Instruction,
    stack_start: usize,
    ffi_boundary: bool,
};

const global_module_name = "%global%";

/// Create a new virtual machine.
pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!Vm {
    const stack = try std.ArrayListUnmanaged(Val).initCapacity(
        alloc,
        std.mem.page_size / @sizeOf(Val),
    );
    const frames = try std.ArrayListUnmanaged(Frame).initCapacity(
        alloc,
        std.mem.page_size / @sizeOf(Frame),
    );
    var vm = Vm{
        .memory_manager = MemoryManager.init(alloc),
        .stack = stack,
        .frames = frames,
        .global_module = .{
            .name = try alloc.dupe(u8, global_module_name),
            .values = .{},
            .alias_to_module = .{},
        },
        .modules = .{},
        .runtime_stats = .{},
    };
    try builtins.registerAll(&vm);
    return vm;
}

/// Deinitialize a virtual machine. Using self after calling deinit is invalid.
pub fn deinit(self: *Vm) void {
    self.stack.deinit(self.allocator());
    self.frames.deinit(self.allocator());

    self.global_module.deinitLocal(self.allocator());
    var modules_iterator = self.modules.valueIterator();
    while (modules_iterator.next()) |module| module.*.deinit(self.allocator());
    self.modules.deinit(self.allocator());

    self.memory_manager.deinit();
}

/// Get the memory allocator used for all `Val`.
pub fn allocator(self: *const Vm) std.mem.Allocator {
    return self.memory_manager.allocator;
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

    var modules_iterator = self.modules.valueIterator();
    while (modules_iterator.next()) |module| {
        var vals_iterator = module.*.iterateVals();
        while (vals_iterator.next()) |v| {
            try self.memory_manager.markVal(v);
        }
    }

    try self.memory_manager.sweep();
}

/// Reset the state of the Vm.
pub fn clearFrames(self: *Vm) void {
    self.stack.clearRetainingCapacity();
    self.frames.clearRetainingCapacity();
}

/// Get the module with the given name. If it does not exist, then it is created.
pub fn getOrCreateModule(self: *Vm, name: []const u8) !*Module {
    if (self.getModule(name)) |m| return m;
    const m = try Module.init(self.allocator(), name);
    try self.registerModule(m);
    return m;
}

/// Get the Module by name or null if it does not exist.
pub fn getModule(self: *Vm, name: []const u8) ?*Module {
    if (std.mem.eql(u8, name, self.global_module.name)) {
        return &self.global_module;
    }
    return self.modules.get(name);
}

/// Register a module. An error is returned if there is a memory error or the module already exists.
pub fn registerModule(self: *Vm, module: *Module) !void {
    if (self.getModule(module.name)) |_| {
        return error.ModuleAlreadyExists;
    }
    try self.modules.put(self.allocator(), module.name, module);
}

/// Delete a module.
pub fn deleteModule(self: *Vm, module: *Module) !void {
    if (self.modules.getEntry(module.name)) |m| {
        if (m.value_ptr.* != module) return error.ModuleDoesNotMatchRegisteredModule;
        self.modules.removeByPtr(m.key_ptr);
    }
    return error.ModuleDoesNotExist;
}

/// Evaluate a single expression from the string.
///
/// If clear_frames is equal to `true`, then the Vm stack and function frames will be cleared prior
/// to evaluation. Usually this should be `true` for a top level run. When evaluating from a native
/// function, you may want to preserve the stack so that the VM can continue to function as usual
/// after the value is returned.
///
/// Note: Val is only valid until the next garbage collection call.
pub fn evalStr(self: *Vm, module: []const u8, expr: []const u8, clear_frames: bool) !Val {
    var arena = std.heap.ArenaAllocator.init(self.allocator());
    defer arena.deinit();
    const ir = try Ir.initStrExpr(arena.allocator(), expr);
    var compiler = try Compiler.initModule(arena.allocator(), self, try self.getOrCreateModule(module));
    const bc = try compiler.compile(ir);
    if (clear_frames) self.clearFrames();
    return self.eval(bc, &.{});
}

/// Evaluate the function and return the result. If bc is not already owned by self, then
/// will take ownership of bc's lifecycle. This means bc.deinit() should not be called.
///
/// Note: Val is only valid until the next garbage collection call.
pub fn eval(self: *Vm, func: Val, args: []const Val) Error!Val {
    self.runtime_stats.function_calls += 1;
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
            try self.stack.appendSlice(self.allocator(), args);
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
            try self.stack.appendSlice(self.allocator(), args);
            const ret = try nf.impl(self, args);
            if (self.stack.items.len > stack_start) self.stack.items = self.stack.items[0..stack_start];
            return ret;
        },
        else => return Error.TypeError,
    }
}

fn runNext(self: *Vm) Error!bool {
    var frame = &self.frames.items[self.frames.items.len - 1];
    switch (frame.instruction[0]) {
        .get_arg => |idx| try self.executeGetArg(frame, idx),
        .push_const => |v| try self.executePushConst(v),
        .ret => {
            const should_continue = try self.executeRet();
            if (!should_continue) return false;
        },
        .deref_local => |s| {
            const mod_and_sym = Module.parseModuleAndSymbol(s);
            if (mod_and_sym.module_alias) |alias| {
                const m = frame.bytecode.module.alias_to_module.get(alias) orelse return Error.SymbolNotFound;
                try self.executeDeref(m, mod_and_sym.symbol);
            } else {
                try self.executeDeref(frame.bytecode.module, mod_and_sym.symbol);
            }
        },
        .deref_global => |s| try self.executeDeref(&self.global_module, s),
        .eval => |n| try self.executeEval(frame, n),
        .jump => |n| frame.instruction += n,
        .jump_if => |n| if (try self.stack.pop().asBool()) {
            frame.instruction += n;
        },
        .import_module => |path| try self.executeImportModule(frame.bytecode.module, path),
    }
    frame.instruction += 1;
    return true;
}

fn executePushConst(self: *Vm, v: Val) !void {
    try self.stack.append(self.allocator(), v);
}

fn executeDeref(self: *Vm, module: *const Module, sym: []const u8) Error!void {
    const v = module.getVal(sym) orelse return Error.SymbolNotFound;
    try self.stack.append(self.allocator(), v);
}

fn executeGetArg(self: *Vm, frame: *const Frame, idx: usize) !void {
    const v = self.stack.items[frame.stack_start + idx];
    try self.stack.append(self.allocator(), v);
}

fn executeEval(self: *Vm, frame: *const Frame, n: usize) !void {
    self.runtime_stats.function_calls += 1;
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

fn executeImportModule(self: *Vm, module: *Module, module_path: []const u8) Error!void {
    const module_alias = Module.defaultModuleAlias(module_path);
    if (self.getModule(module_path)) |m| {
        try module.setModuleAlias(self.allocator(), module_alias, m);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(self.allocator());
    defer arena.deinit();
    const file_size_limit = 64 * 1024 * 1024;
    const contents = std.fs.cwd().readFileAlloc(arena.allocator(), module_path, file_size_limit) catch return Error.FileError;
    const ast = Ast.initWithStr(arena.allocator(), contents) catch return Error.SyntaxError;
    var module_ok = false;
    const new_module = self.getOrCreateModule(module_path) catch return Error.RuntimeError;
    errdefer if (!module_ok) self.deleteModule(new_module) catch {};
    const ir = Ir.init(arena.allocator(), ast.asts) catch return Error.RuntimeError;
    var compiler = try Compiler.initModule(arena.allocator(), self, new_module);
    const module_bytecode = compiler.compile(ir) catch Error.RuntimeError;
    _ = try self.eval(try module_bytecode, &.{});
    module_ok = true;
    try module.setModuleAlias(self.allocator(), module_alias, new_module);
}

test "can eval basic expression" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("%test%", "4", true);
    try vm.runGc();
    try std.testing.expectEqual(Val{ .int = 4 }, actual);
    try std.testing.expectEqual(1, vm.runtime_stats.function_calls);
}

test "can deref symbols" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try vm.global_module.setVal(&vm, "test", try vm.memory_manager.allocateStringVal("test-val"));
    const actual = try vm.evalStr("%test%", "test", true);
    try std.testing.expectEqualDeep(Val{ .string = @constCast("test-val") }, actual);
}

test "lambda can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("%test%", "((lambda (x) x) true)", true);
    try std.testing.expectEqualDeep(Val{ .boolean = true }, actual);
}

test "apply takes native function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("%test%", "(apply + (list 1 2 3 4))", true);
    try std.testing.expectEqualDeep(Val{ .int = 10 }, actual);
}

test "apply takes bytecode function and list" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const actual = try vm.evalStr("%test%", "(apply (lambda (a b c d) (- 0 a b c d)) (list 1 2 3 4))", true);
    try std.testing.expectEqualDeep(Val{ .int = -10 }, actual);
}

test "recursive function can eval" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqualDeep(
        Val.none,
        try vm.evalStr("%test%", "(define fib (lambda (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))", true),
    );
    try std.testing.expectEqualDeep(
        Val{ .int = 55 },
        try vm.evalStr("%test%", "(fib 10)", true),
    );
    try std.testing.expectEqualDeep(621, vm.runtime_stats.function_calls);
}

test "can only deref symbols from the same module" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    try (try vm.getOrCreateModule("%test%"))
        .setVal(&vm, "test", try vm.memory_manager.allocateStringVal("test-val"));
    try std.testing.expectEqualDeep(
        Val{ .string = @constCast("test-val") },
        try vm.evalStr("%test%", "test", true),
    );
    try std.testing.expectError(
        error.SymbolNotFound,
        vm.evalStr("%other%", "test", true),
    );
}

test "symbols from imported modules can be referenced" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    _ = try vm.evalStr("%test%", "(import \"test_scripts/geometry.fizz\")", true);
    try std.testing.expectEqualDeep(
        Val{ .float = 3.14 },
        try vm.evalStr("%test%", "geometry/pi", true),
    );
}
