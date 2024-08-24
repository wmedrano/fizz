---
layout: page
title: Zig API
nav_enabled: true
nav_order: 1
---

{: .todo}
> Tag a 0.1.0 Fizz release and document how to use it as a module.

# Zig API

## Quickstart

In the following example, we:

1. Create the Fizz virtual machine.
1. Run some code within the virtual machine.
1. Convert a value into a custom Zig object.

```zig
const Vm = import("Vm.zig");

pub fn main() {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    // Create a VM.
    var vm = try Vm.init(allocator);
    defer vm.deinit();

    // Evaluate an expression.
    _ = try vm.evalStr(allocator, "(define magic-numbers (list 1 2 3 4))");
    const val = try vm.evalStr(
        allocator,
        "(struct 'numbers magic-numbers 'numbers-sum (apply + magic-numbers))",
    );

    // Convert the results into a Zig object.
    const ResultType = struct { numbers: []const i64, numbers_sum: i64 };
    const result = try vm.env.toZig(
        ResultType,
        allocator,
        val,
    );
    defer allocator.free(result.numbers);

    // Use the results.
    std.debug.print("Result is: {any}\n", .{result});
}
```

## Initialization & Memory Management

A VM is created with `try Vm.init(allocator)`. All values created for the VM
will use the allocator. Memory is cleaned up on `vm.deinit` and sometimes on
`vm.runGc`. Due to the use of garbage collection, it is not recommended to use
an arena for most uses.

```zig
var vm = try Vm.init(allocator);

// Do stuff...
try vm.runGc(); // Run GC from time to time.

defer vm.deinit();
```

### Garbage Collection

Fizz is a garbage collected language. Garbage collection is not yet automated
and must be called manually.

**Example**

```zig
fn doStuff(allocator: std.mem.Allocator, vm: *Vm) !void {
    // Bind a new list to x.
    const _ = try vm.evalStr(allocator, "(define x (list 1 2 3 4))");
    // Bind a new list to x. The previous list will still live in memory.
    const _ = try vm.evalStr(allocator, "(define x (list 1 2 3 4))");
    // Run the garbage collector. The unused list will be cleaned up.
    try vm.runGc();
}
```

## Extracting Values

Values are extracted using `vm.env.toZig`.

```zig
fn toZig(self: *Env, comptime T: type, allocator: Allocator, val: Val) !T
```

- `self`: A pointer to the environment.
- `T`: The desired output Zig type.
- `allocator`: Memory allocator for dynamic memory allocation
- `val`: The input value to be converted

**Example**

```zig
fn buildStringInFizz(allocator: std.mem.allocator, vm: *Vm) ![]const u8 {
   const val = try vm.evalStr(allocator, "(str-concat (list \"hello\" \" \" \"world\"))");
   const string_val = try vm.env.toZig([]const u8, val);
   return string_val;
}
```


### Supported Conversions

- `bool`: Either `true` or `false`.
- `i64`: Fizz integers.
- `f64`: Can convert from either a Fizz int or a Fizz float.
- `void`: Converts from none.
- `[]u8` or `[]const u8`: Converts from Fizz strings.
- `[]T` or `[]const T`: Converts from a Fizz list where `T` is a supported conversion.
  - Supports nested lists (e.g., `[][]f64`).
- `struct{..}` - Converts from a Fizz struct, (e.g., `(struct 'x 1 'y 2)`).

### Structs

Fizz structs may be parsed as Zig types. Zig types are extracted by field name,
with the `snake_case` field names mapping to `kebab-case`. For example,
`my_field` will be derived from `my-field.`

```zig
const TestType = struct {
    // Will be derived from `my-string field with a string.
    my_string: []const u8,
	// Will be derived from 'my-list field with a list of ints.
    my_list: []const i64,
	// Will be derived from 'nested field with the appropriate struct.
    nested: struct { a: i64, b: f64 },
};

const src = \\(struct
\\ 'my-string "hello world!"
\\ 'my-list   (list 1 2 3 4)
\\ 'nested (struct 'a 1 'b 2.0)
\\)
const complex_val = try vm.evalStr(allocator, src);
const result = try vm.env.toZig(TestType, allocator, complex_val);
defer allocator.free(result.my_string);
defer allocator.free(result.my_list);
```

## Custom Functions

{: .warning}
> Unstable, WIP! The function signature of custom functions and representation
> of `Vm.Val` may change.

Custom functions written in Zig may be registered with `Vm.registerGlobalFn` and
invoked within the VM.


```zig
fn beep(env: *Vm.Environment, args: []const Vm.Val) Vm.NativeFnError!Vm.Val {
	...
}

try vm.registerGlobalFn("beep!", beep)
_ = try vm.evalStr(allocator, "(beep!)")
```

For some examples, see
<https://github.com/wmedrano/fizz/blob/main/src/builtins.zig>.
