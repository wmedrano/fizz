---
layout: page
title: Zig API
nav_enabled: true
nav_order: 1
---

# Zig API

## Quickstart

In the following example, we:

1. Add fizz as a dependency.
   > TODO
1. Create the Fizz virtual machine.
	```zig
	const fizz = @import("fizz");
	var vm = try fizz.Vm.init(allocator);
	defer vm.deinit();
	```
1. Run some code within the virtual machine.
   ```zig
   _ = try vm.EvalStr(allocator, "(define magic-numbers (list 1 2 3 4))");
   const val = try vm.evalStr(
       allocator,
	   "(struct 'numbers magic-numbers 'numbers-sum (apply + magic-numbers))");
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

## Memory Management

Fizz is a garbage collected language. As the program runs, it will allocate
memory as needed. However, when the memory is not needed, it will stick around
until either `Vm.deinit` or `Vm.runGc` has run.

{: .todo}
> Allow Garbage Collector to automatically run when needed.

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
