const Val = @import("val.zig").Val;
const ByteCode = @import("ByteCode.zig");

const std = @import("std");

pub const Options = struct {
    initial_stack_capacity: usize = 4096,
    initial_frame_capacity: usize = 1024,
};

const Frame = struct {
    bytecode: *const ByteCode,
    instruction_idx: usize,
    stack_start: usize,
};

pub fn Vm(comptime options: Options) type {
    return struct {
        const VmImpl = @This();
        allocator: std.mem.Allocator,
        stack: std.ArrayListUnmanaged(Val),
        frames: std.ArrayListUnmanaged(Frame),
        symbols: std.StringHashMapUnmanaged(Val),

        pub fn init(allocator: std.mem.Allocator) !VmImpl {
            const stack = try std.ArrayListUnmanaged(Val).initCapacity(
                allocator,
                options.initial_stack_capacity,
            );
            const frames = try std.ArrayListUnmanaged(Frame).initCapacity(
                allocator,
                options.initial_stack_capacity,
            );
            const symbols = std.StringHashMapUnmanaged(Val){};
            return .{
                .allocator = allocator,
                .stack = stack,
                .frames = frames,
                .symbols = symbols,
            };
        }

        pub fn deinit(self: *VmImpl) void {
            self.stack.deinit(self.allocator);
            self.frames.deinit(self.allocator);
            self.symbols.deinit(self.allocator);
        }

        pub fn defineVal(self: *VmImpl, sym: []const u8, val: Val) !void {
            return self.symbols.put(self.allocator, sym, val);
        }

        pub fn evalStr(self: *VmImpl, expr: []const u8) !Val {
            var ir = try @import("ir.zig").Ir.initStrExpr(self.allocator, expr);
            defer ir.deinit(self.allocator);
            var bc = try ByteCode.init(self.allocator, ir);
            defer bc.deinit();
            return self.eval(&bc);
        }

        pub fn eval(self: *VmImpl, bc: *ByteCode) !Val {
            self.stack.clearRetainingCapacity();
            const frame = .{ .bytecode = bc, .instruction_idx = 0, .stack_start = 0 };
            self.frames.appendAssumeCapacity(frame);
            while (try self.runNext()) {}
            return self.stack.popOrNull() orelse .none;
        }

        fn runNext(self: *VmImpl) !bool {
            if (self.frames.items.len == 0) return false;
            var frame = &self.frames.items[self.frames.items.len - 1];
            const instruction = frame.bytecode.instructions.items[frame.instruction_idx];
            switch (instruction) {
                .push_const => |v| try self.stack.append(self.allocator, v),
                .deref => |s| {
                    const v = self.symbols.get(s) orelse return error.SymbolNotFound;
                    try self.stack.append(self.allocator, v);
                },
                .get_arg => |idx| {
                    const v = self.stack.items[frame.stack_start + idx];
                    try self.stack.append(self.allocator, v);
                },
                .eval => |n| {
                    const fn_idx = self.stack.items.len - n;
                    const func = self.stack.items[fn_idx];
                    const new_frame = .{
                        .bytecode = try func.asByteCode(),
                        .instruction_idx = 0,
                        .stack_start = fn_idx + 1,
                    };
                    self.frames.appendAssumeCapacity(new_frame);
                },
                .jump => |n| frame.instruction_idx += n,
                .jump_if => |n| if (try self.stack.pop().isTruthy()) {
                    frame.instruction_idx += n;
                },
                .ret => {
                    const old_frame = self.frames.pop();
                    if (self.frames.items.len == 0) {
                        return false;
                    }
                    const ret = self.stack.pop();
                    self.stack.items = self.stack.items[0..old_frame.stack_start];
                    self.stack.items[old_frame.stack_start - 1] = ret;
                },
            }
            frame.instruction_idx += 1;
            return true;
        }
    };
}

test "can eval basic expression" {
    var vm = try Vm(.{}).init(std.testing.allocator);
    defer vm.deinit();
    var actual = try vm.evalStr("4");
    defer actual.deinit(vm.allocator);
    try std.testing.expectEqual(Val.initInt(4), actual);
}

test "can deref symbols" {
    var vm = try Vm(.{}).init(std.testing.allocator);
    defer vm.deinit();
    try vm.defineVal("test", try Val.initString(vm.allocator, "test-val"));
    var actual = try vm.evalStr("test");
    defer actual.deinit(vm.allocator);
    try std.testing.expectEqualDeep(Val{ .string = @constCast("test-val") }, actual);
}

test "lambda can eval" {
    var vm = try Vm(.{}).init(std.testing.allocator);
    defer vm.deinit();
    var actual = try vm.evalStr("((lambda () true))");
    defer actual.deinit(vm.allocator);
    try std.testing.expectEqualDeep(Val.initBoolean(true), actual);
}
