const Env = @This();

const std = @import("std");
const Ast = @import("Ast.zig");
const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");
const Ir = @import("ir.zig").Ir;
const MemoryManager = @import("MemoryManager.zig");
const Compiler = @import("Compiler.zig");
const ErrorCollector = @import("datastructures/ErrorCollector.zig");

/// Deals with allocating and deallocating values. This involves garbage collection.
memory_manager: MemoryManager,

/// Holds the data stack. The boundary of function start and end indices is in the frames object.
stack: std.ArrayListUnmanaged(Val),

/// Holds the stack frames with the final value containing the details of the current function call.
frames: std.ArrayListUnmanaged(Frame),

/// Holds global values.
global_values: std.AutoHashMapUnmanaged(Val.Symbol, Val),

/// Place to store errors.
errors: ErrorCollector,

/// Strategy to use for GC.
gc_strategy: GcStrategy = .per_256_calls,

/// Runtime stats for the VM.
runtime_stats: RuntimeStats,

pub const Error = std.mem.Allocator.Error || Val.NativeFn.Error || error{ SymbolNotFound, FileError, SyntaxError };

const RuntimeStats = struct {
    gc_duration_nanos: u64 = 0,
    function_calls: u64 = 0,
};

pub const Frame = struct {
    bytecode: *ByteCode,
    instruction: [*]ByteCode.Instruction,
    stack_start: usize,
    ffi_boundary: bool,
};

/// Strategy to use for garbage collection.
pub const GcStrategy = enum {
    /// The garbage collector is never called automatically. It must be called manually with
    /// `runGc`.
    manual,
    /// The garbage collector is invoked every 256 function calls.
    per_256_calls,
};

/// The name of the global module.
pub const global_module_name = "*global*";

/// Create a new virtual machine.
pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!Env {
    const stack = try std.ArrayListUnmanaged(Val).initCapacity(
        alloc,
        std.mem.page_size / @sizeOf(Val),
    );
    const frames = try std.ArrayListUnmanaged(Frame).initCapacity(
        alloc,
        std.mem.page_size / @sizeOf(Frame),
    );
    return Env{
        .memory_manager = MemoryManager.init(alloc),
        .stack = stack,
        .frames = frames,
        .global_values = .{},
        .errors = ErrorCollector.init(alloc),
        .runtime_stats = .{},
    };
}

/// Deinitialize a virtual machine. Using self after calling deinit is invalid.
pub fn deinit(self: *Env) void {
    self.stack.deinit(self.memory_manager.allocator);
    self.frames.deinit(self.memory_manager.allocator);

    self.global_values.deinit(self.memory_manager.allocator);
    self.memory_manager.deinit();
    self.errors.deinit();
}
