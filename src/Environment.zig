const Environment = @This();

const Module = @import("Module.zig");
const Ast = @import("Ast.zig");
const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Compiler = @import("Compiler.zig");
const builtins = @import("builtins.zig");
const std = @import("std");

memory_manager: MemoryManager,
stack: std.ArrayListUnmanaged(Val),
frames: std.ArrayListUnmanaged(Frame),
global_module: Module,
modules: std.StringHashMapUnmanaged(*Module),
runtime_stats: RuntimeStats,

pub const Error = std.mem.Allocator.Error || Val.NativeFn.Error || error{ SymbolNotFound, FileError, SyntaxError };

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

/// The name of the global module.
pub const global_module_name = "%global%";

/// Create a new virtual machine.
pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!Environment {
    const stack = try std.ArrayListUnmanaged(Val).initCapacity(
        alloc,
        std.mem.page_size / @sizeOf(Val),
    );
    const frames = try std.ArrayListUnmanaged(Frame).initCapacity(
        alloc,
        std.mem.page_size / @sizeOf(Frame),
    );
    var vm = Environment{
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
pub fn deinit(self: *Environment) void {
    self.stack.deinit(self.allocator());
    self.frames.deinit(self.allocator());

    self.global_module.deinitLocal(self.allocator());
    var modules_iterator = self.modules.valueIterator();
    while (modules_iterator.next()) |module| module.*.deinit(self.allocator());
    self.modules.deinit(self.allocator());

    self.memory_manager.deinit();
}

/// Get the memory allocator used for all `Val`.
pub fn allocator(self: *const Environment) std.mem.Allocator {
    return self.memory_manager.allocator;
}

/// Convert the val into a Zig value.
pub fn toZig(self: *const Environment, T: type, alloc: std.mem.Allocator, val: Val) !T {
    if (T == void) {
        if (!val.isNone()) return error.TypeError;
        return;
    }
    if (T == bool) return val.asBool();
    if (T == i64) return val.asInt();
    if (T == f64) return val.asFloat();
    if (T == []u8) {
        switch (val) {
            .string => |s| return try alloc.dupe(u8, s),
            else => return error.TypeError,
        }
    }
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            switch (info.size) {
                .One => @compileError("Val.toZig does not support pointers"),
                .Slice => switch (val) {
                    .list => |lst| {
                        var ret = try alloc.alloc(info.child, lst.len);
                        var init_count: usize = 0;
                        errdefer toZigClean(T, alloc, ret, init_count);
                        for (0..lst.len) |idx| {
                            ret[idx] = try self.toZig(info.child, alloc, lst[idx]);
                            init_count += 1;
                        }
                        return ret;
                    },
                    else => return error.TypeError,
                },
                .Many => @compileError("Val.toZig does not support Many pointers"),
                .C => @compileError("Val.toZig does not support C pointers."),
            }
        },
        else => {
            @compileError("Val.toZig called with unsupported Zig type.");
        },
    }
}

// T - The type that will be cleaned up.
// alloc - The allocator used to allocate said values.
// v - The object to deallocate.
// slice_init_count - If v is a slice, then this is the number of elements that were initialized or
//   `null` to deallocate all the elements.
fn toZigClean(T: type, alloc: std.mem.Allocator, v: T, slice_init_count: ?usize) void {
    if (T == void or T == bool or T == i64 or T == f64) return;
    if (T == []u8) {
        alloc.free(v);
        return;
    }
    switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .Slice => {
                const slice = if (slice_init_count) |n| v[0..n] else v;
                for (slice) |item| toZigClean(info.child, alloc, item, null);
                alloc.free(v);
            },
            else => @compileError("Unreachable"),
        },
        else => {
            @compileError(@typeName(T));
        },
    }
}

/// Run the garbage collector to free up memory.
pub fn runGc(self: *Environment) !void {
    var timer = try std.time.Timer.start();
    defer self.runtime_stats.gc_duration_nanos += timer.read();
    for (self.stack.items) |v| try self.memory_manager.markVal(v);
    for (self.frames.items) |f| try self.memory_manager.markVal(.{ .bytecode = f.bytecode });

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

/// Get the module with the given name. If it does not exist, then it is created.
pub fn getOrCreateModule(self: *Environment, builder: Module.Builder) !*Module {
    if (self.getModule(builder.name)) |m| {
        return m;
    }
    const m = try Module.init(self.allocator(), builder);
    try self.registerModule(m);
    return m;
}

/// Get the Module by name or null if it does not exist.
pub fn getModule(self: *Environment, name: []const u8) ?*Module {
    if (std.mem.eql(u8, name, self.global_module.name)) {
        return &self.global_module;
    }
    return self.modules.get(name);
}

/// Register a module. An error is returned if there is a memory error or the module already exists.
pub fn registerModule(self: *Environment, module: *Module) !void {
    if (self.getModule(module.name)) |_| {
        return error.ModuleAlreadyExists;
    }
    try self.modules.put(self.allocator(), module.name, module);
}

/// Delete a module.
pub fn deleteModule(self: *Environment, module: *Module) !void {
    if (self.modules.getEntry(module.name)) |found_module| {
        if (found_module.value_ptr.* != module) return error.ModuleDoesNotMatchRegisteredModule;
        var modules_iter = self.modules.valueIterator();
        while (modules_iter.next()) |any_m| {
            if (any_m.* == module) continue;
            var aliases_iter = any_m.*.alias_to_module.iterator();
            while (aliases_iter.next()) |alias| {
                if (alias.value_ptr.* == module) {
                    any_m.*.alias_to_module.removeByPtr(alias.key_ptr);
                }
            }
        }
        module.deinit(self.allocator());
        self.modules.removeByPtr(found_module.key_ptr);
    }
    return error.ModuleDoesNotExist;
}

/// Evaluate the function and return the result.
///
/// Compared to the `eval` function present in `Vm`, this function can be called from a native
/// function as it does not reset the function call and data stacks after execution.
///
/// Note: The returned Val is only valid until the next runGc call.
pub fn evalNoReset(self: *Environment, func: Val, args: []const Val) Error!Val {
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

fn runNext(self: *Environment) Error!bool {
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

fn executePushConst(self: *Environment, v: Val) !void {
    try self.stack.append(self.allocator(), v);
}

fn executeDeref(self: *Environment, module: *const Module, sym: []const u8) Error!void {
    const v = module.getVal(sym) orelse {
        return Error.SymbolNotFound;
    };
    try self.stack.append(self.allocator(), v);
}

fn executeGetArg(self: *Environment, frame: *const Frame, idx: usize) !void {
    const v = self.stack.items[frame.stack_start + idx];
    try self.stack.append(self.allocator(), v);
}

fn executeEval(self: *Environment, frame: *const Frame, n: usize) !void {
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

fn executeRet(self: *Environment) !bool {
    const old_frame = self.frames.pop();
    if (old_frame.ffi_boundary) {
        return false;
    }
    const ret = self.stack.popOrNull() orelse .none;
    self.stack.items = self.stack.items[0..old_frame.stack_start];
    self.stack.items[old_frame.stack_start - 1] = ret;
    return true;
}

fn executeImportModule(self: *Environment, module: *Module, module_path: []const u8) Error!void {
    const base_dir = module.directory() catch return Error.FileError;
    const full_path = base_dir.realpathAlloc(self.allocator(), module_path) catch return Error.FileError;
    defer self.allocator().free(full_path);
    const module_alias = Module.defaultModuleAlias(full_path);
    if (self.getModule(full_path)) |m| {
        try module.setModuleAlias(self.allocator(), module_alias, m);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(self.allocator());
    defer arena.deinit();
    const file_size_limit = 64 * 1024 * 1024;
    const contents = std.fs.cwd().readFileAlloc(arena.allocator(), full_path, file_size_limit) catch return Error.FileError;
    const ast = Ast.initWithStr(arena.allocator(), contents) catch return Error.SyntaxError;
    var module_ok = false;
    const new_module = self.getOrCreateModule(.{ .name = full_path }) catch return Error.RuntimeError;
    errdefer if (!module_ok) self.deleteModule(new_module) catch {};
    const ir = Ir.init(arena.allocator(), ast.asts) catch return Error.RuntimeError;
    var compiler = try Compiler.initModule(arena.allocator(), self, new_module);
    const module_bytecode = compiler.compile(ir) catch Error.RuntimeError;
    _ = try self.evalNoReset(try module_bytecode, &.{});
    module_ok = true;
    try module.setModuleAlias(self.allocator(), module_alias, new_module);
}

test "can convert to zig val" {
    var env = try init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqual(false, env.toZig(bool, std.testing.allocator, .{ .boolean = false }));
    try std.testing.expectEqual(42, env.toZig(i64, std.testing.allocator, .{ .int = 42 }));
    try env.toZig(void, std.testing.allocator, .none);

    const actual_str = try env.toZig([]u8, std.testing.allocator, .{ .string = "string" });
    defer std.testing.allocator.free(actual_str);
    try std.testing.expectEqualStrings("string", actual_str);

    const actual_int_list = try env.toZig(
        []i64,
        std.testing.allocator,
        Val{ .list = @constCast(&[_]Val{ Val{ .int = 1 }, Val{ .int = 2 } }) },
    );
    defer std.testing.allocator.free(actual_int_list);
    try std.testing.expectEqualDeep(&[_]i64{ 1, 2 }, actual_int_list);

    const actual_float_list_list = try env.toZig(
        [][]f64,
        std.testing.allocator,
        Val{ .list = @constCast(
            &[_]Val{
                Val{ .list = @constCast(&[_]Val{ .{ .float = 1.0 }, .{ .float = 2.0 } }) },
                Val{ .list = @constCast(&[_]Val{ .{ .float = 3.0 }, .{ .float = 4.0 } }) },
            },
        ) },
    );
    defer std.testing.allocator.free(actual_float_list_list);
    defer for (actual_float_list_list) |lst| std.testing.allocator.free(lst);
    try std.testing.expectEqualDeep(
        &[_][]const f64{
            &[_]f64{ 1.0, 2.0 },
            &[_]f64{ 3.0, 4.0 },
        },
        actual_float_list_list,
    );
}

test "can't convert list of heterogenous types" {
    var env = try init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(
        error.TypeError,
        env.toZig(
            [][]u8,
            std.testing.allocator,
            Val{ .list = @constCast(
                &[_]Val{
                    Val{ .list = @constCast(&[_]Val{ .{ .string = "good" }, .{ .string = "also good" } }) },
                    Val{ .list = @constCast(&[_]Val{ .{ .string = "still good" }, .{ .symbol = "bad" } }) },
                },
            ) },
        ),
    );
}
