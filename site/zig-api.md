---
layout: page
title: Zig API
nav_enabled: true
nav_order: 1
---

# Zig API

## Quickstart

1. Download Fizz and place it in `build.zig.zon`.
   ```sh
   zig fetch --save https://github.com/wmedrano/fizz/archive/refs/tags/v0.1.0.tar.gz
   ```
1. Add Fizz as a dependency in `build.zig`.
   ```zig
   // Create the fizz dependency.
   const fizz = b.dependency("fizz", .{
	   .target = target,
	   .optimize = optimize,
   });

   ..

   // Use it for our executable.
   exe.root_module.addImport("fizz", fizz.module("fizz"));
   ```
1. Create the Fizz virtual machine in your code, for example, `src/main.zig`.
	```zig
	const fizz = @import("fizz");
	var vm = try fizz.Vm.init(allocator);
	defer vm.deinit();
	```
1. Write some code within the virtual machine.
   ```zig
   const src = \\
   \\ (define magic-numbers (list 1 2 3 4))
   \\ (struct
   \\   'numbers magic-numbers
   \\   'numbers-sum (apply + magic-numbers)
   \\ )
   ;
   ```
1. Run the code in the VM.
   ```zig
   const allocators = .{
	   .compiler_allocator = std.testing.allocator,
	   .return_value_allocator = std.testing.allocator,
   };
   const ResultType = struct { numbers: []const i64, numbers_sum: i64 };
   const result = try vm.evalStr(ResultType, allocators, src);
   defer allocators.return_value_allocator.free(result.numbers);
   ```
1. Run the garbage collector from time to time.
   ```zig
   try vm.runGc();
   ```

## Evaluating Expressions

Expressions can be evaluated with `vm.evalStr`. The first argument is the type
that should be returned. If you do not care about the return value, `fizz.Val`
can be used to hold any value returned by the VM.

{: .warning}
> Any `fizz.Val` that is returned is guaranteed to exist until the next garbage
> collection run. Use a concrete Zig type, (e.g. []u8) to ensure that the
> allocator is used to extend the lifetime.

```zig
/// Contains allocators needed to evaluate an expression.
pub const EvalAllocators = struct {
    /// Allocator used by the compiler to allocate temporary memory. Using an arena allocator is
    /// recommended for best performance.
    compiler_allocator: std.mem.Allocator,
    /// Allocator used to construct return value. Only used if the return value contains slices.
    return_value_allocator: std.mem.Allocator,
};
fn evalStr(self: *fizz.Vm, T: type, allocators: fizz.EvalAllocators, expr: []const u8) !T
```

- `self`: Pointer to the virtual machine.
- `allocator`: Allocators used for temporary compiler objects and finalized
  return values.
- `expr`: Lisp expression to evaluate. If multiple expressions are provided, the
  return value will contain the value of the final expression.


## Extracting Values

Values from the Fizz VM are extracted from `fizz.Vm.evalStr`. They can also manually
be extracted from a `fizz.Val` by calling `vm.env.toZig`.

```zig
fn toZig(self: *fizz.Env, comptime T: type, allocator: std.mem.Allocator, val: fizz.Val) !T
```

- `self`: A pointer to the environment.
- `T`: The desired output Zig type.
- `allocator`: Memory allocator for any string or slice allocations.
- `val`: The input value to be converted

**Example**

```zig
fn buildStringInFizz(allocator: std.mem.allocator, vm: *fizz.Vm) ![]const u8 {
   const val = try vm.evalStr(fizz.Val, allocators, "(str-concat (list \"hello\" \" \" \"world\"))");
   const string_val = try vm.env.toZig([]const u8, val);
   return string_val;
}
```


### Supported Conversions

- `bool`: Either `true` or `false`.
- `i64`: Fizz integers.
- `f64`: Can convert from either a Fizz int or a Fizz float.
- `void`: Converts from none. None is often returned by expressions that don't
  typically return values like `(define x 1)`.
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
const result = try vm.evalStr(TestType, allocators, src);
defer allocator.free(result.my_string);
defer allocator.free(result.my_list);
```

## Memory Management

Fizz is a garbage collected language. As the program runs, it will allocate
memory as needed. However, when the memory is not needed, it will stick around
until either `Vm.deinit` or `Vm.runGc` has run.

{: .todo}
> Allow Garbage Collector to automatically run when needed.
> <https://github.com/wmedrano/fizz/issues/4>

```zig
const fizz = @import("fizz");
var vm = try fizz.Vm.init(allocator);

// Do stuff
...

// Run GC to free up some memory.
try vm.runGc();

// Run deinit to free all memory.
defer vm.deinit();
```


## Custom Functions

{: .warning}
> Unstable, WIP! The function signature of custom functions and representation
> of `fizz.Val` may change.

Custom functions written in Zig may be registered with `Vm.registerGlobalFn` and
invoked within the VM.


```zig
fn beep(env: *Vm.Environment, args: []const Vm.Val) Vm.NativeFnError!Vm.Val {
	...
}

try vm.registerGlobalFn("beep!", beep)
_ = try vm.evalStr(fizz.Val, allocator, "(beep!)")
```

For some examples, see
<https://github.com/wmedrano/fizz/blob/main/src/builtins.zig>.
