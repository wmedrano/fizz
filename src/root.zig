pub const Vm = @import("Vm.zig");
pub const Val = @import("val.zig").Val;
pub const Environment = @import("Environment.zig");
pub const NativeFnError = Val.NativeFn.Error;

pub const Ast = @import("Ast.zig");
pub const Ir = @import("ir.zig").Ir;
pub const Compiler = @import("Compiler.zig");
