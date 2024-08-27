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
   zig fetch --save https://github.com/wmedrano/fizz/archive/refs/tags/v0.1.1.tar.gz
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
1. Run some code within the virtual machine.
   ```zig
   const src = \\
   \\ (define magic-numbers (list 1 2 3 4))
   \\ (struct
   \\   'numbers magic-numbers
   \\   'numbers-sum (apply + magic-numbers)
   \\ )
   ;
   const val = try vm.EvalStr(allocator, src);
   ```
1. Convert VM values into Zig.
   ```zig
   const ResultType = struct { numbers: []const i64, numbers_sum: i64 };
   const result = try vm.env.toZig(
       ResultType,
       allocator,
       val,
   );
   defer allocator.free(result.numbers);
   ```
1. Run the garbage collector from time to time.
   ```zig
   try vm.runGc();
   ```

## Evaluating Expressions

Expressions can be evaluated with `vm.evalStr`. The value of the returned
`fizz.Val` is guaranteed to exist until the next garbage collection run. See
[Extracting Values](#extracting-values) to extend the lifetime of the returned
values.

```zig
fn evalStr(self: *fizz.Vm, tmp_allocator: std.mem.Allocator, expr: []const u8) fizz.Val
```

- `self`: Pointer to the virtual machine.
- `tmp_allocator`: Allocator used for temporary memory for AST and ByteCode
  compiler.
- `expr`: Lisp expression to evaluate. If multiple expressions are provided, the
  returned `fizz.Val` will contain the value of the final expression.


## Extracting Values

Values are extracted using `vm.env.toZig`.

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
_ = try vm.evalStr(allocator, "(beep!)")
```

For some examples, see
<https://github.com/wmedrano/fizz/blob/main/src/builtins.zig>.
