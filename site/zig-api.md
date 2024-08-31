---
layout: page
title: Zig API
nav_enabled: true
nav_order: 1
---

# Zig API

## Evaluating Expressions

Expressions can be evaluated with `vm.evalStr`. The first argument is the type
that should be returned. If you do not care about the return value, `fizz.Val`
can be used to hold any value returned by the VM.

{: .warning}
> Any `fizz.Val` that is returned is guaranteed to exist until the next garbage
> collection run. Use a concrete Zig type, (e.g. []u8) to ensure that the
> allocator is used to extend the lifetime.

```zig
fn evalStr(self: *fizz.Vm, T: type, allocator: std.mem.allocator, expr: []const u8) !T
```

- `self`: Pointer to the virtual machine.
- `allocator`: Allocator used to allocate any slices or strings in `T`. `bool`,
  `int`, `float`, `void`, and structs do not require any memory allocations to
  convert their return value.
- `expr`: Lisp expression to evaluate. If multiple expressions are provided, the
  return value will contain the value of the final expression.

```zig
const fizz = @import("fizz");
var vm = try fizz.Vm.init(allocator);
const val = try fizz.evalStr(i64, allocator, "(+ 1 2)");
```

## Extracting Values

Values from the Fizz VM are extracted from `fizz.Vm.evalStr`. They can also manually
be extracted from a `fizz.Val` by calling `vm.env.toZig`.

```zig
fn toZig(self: *fizz.Env, comptime T: type, allocator: std.mem.Allocator, val: fizz.Val) !T
```

- `self`: A pointer to the environment.
- `T`: The desired output Zig type. If no conversion is desired, `fizz.Val` will
  return the raw Value object.
- `allocator`: Memory allocator for any string or slice allocations.
- `val`: The input value to be converted

**Example**

```zig
fn buildStringInFizz(allocator: std.mem.allocator, vm: *fizz.Vm) ![]const u8 {
   const val = try vm.evalStr(fizz.Val, allocator, "(str-concat (list \"hello\" \" \" \"world\"))");
   const string_val = try vm.env.toZig([]const u8, val);
   return string_val;
}
```

### Supported Conversions

- `void`: Converts from none. None is often returned by expressions that don't
  typically return values like `(define x 1)`.
- `bool`: Either `true` or `false`.
- `i64`: Fizz integers.
- `f64`: Can convert from either a Fizz int or a Fizz float.
- `[]u8` or `[]const u8`: Converts from Fizz strings. Requires allocations.
- `[]T` or `[]const T`: Converts from a Fizz list where `T` is a supported conversion.
  - Supports nested lists (e.g., `[][]f64`).
  - Requires allocating a list and possibly more allocations depending on the
    type of `T`.
- `struct{..}` - Converts from a Fizz struct, (e.g., `(struct 'x 1 'y 2)`).
  - May require allocations if any subtypes of the struct require an allocation.

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
const result = try vm.evalStr(TestType, std.testing.allocator, src);
defer allocator.free(result.my_string);
defer allocator.free(result.my_list);
```

## Memory Management

Fizz is a garbage collected language. As the program runs, it will allocate
memory as needed. However, when the memory is not needed, it will stick around
until either `Vm.deinit` or when the vm periodically runs `Vm.runGc`. The gc
strategy may be set by calling: `vm.env.gc_strategy = <strategy>;`. The possible
strategies are:

### .per_256_calls

The garbage collector automatically runs every 256 function calls. This counts
any internal function calls and the initial entrance. For example,
`vm.evalStr(..., "(+ 1 2 3)")` has 2 function calls, the initial enstance call
and the call to `+`.

### .manual

The garbage collector is never invoked automatically. It must be manually
invoked with `runGc`.

```zig
const fizz = @import("fizz");
var vm = try fizz.Vm.init(allocator);
defer vm.deinit();

// Do stuff
...

// Run GC to free up some memory.
try vm.runGc();
```

### Fiz Value Lifetimes

Values that require allocation (everything that is not `int` or `float` are not
guaranteed to live passed an evaluation due to garbage collection. Note that
this only applies to `fizz.Val`. Values that have been converted have been reallocated.

```zig
	const example_val = try vm.evalStr(Val, allocator, "\"test\"");
	const example_str = try vm.evalStr([]const u8, allocator, "\"test\"");
	defer allocater.free(example_str);

	// Can make use of example_val and example_str over here.
	...

	const other_val = try vm.evalStr(i64, allocator, "10");
	// example_val is now invalid as evalStr may have run the garbage collector.
	// example_str is ok as it was allocated with allocator.
```

To extend the lifetime of the value, call `Environment.keepAlive` to keep the
value alive and `Environment.allowDeath` to allow the garbage collector to clean
it up.

```zig
	const example_val = try vm.evalStr(Val, allocator, "\"test\"");
	try vm.env.keepAlive(example_val);
	defer vm.env.allowDeath(example_val);
	const example_str = try vm.evalStr([]const u8, allocator, "\"test\"");
	defer allocater.free(example_str);

	// Can make use of example_val and example_str over here.
	...

	const other_val = try vm.evalStr(i64, allocator, "10");
	// Can make use of example_val as keepAlive ensures it is not garbage collected.
	// example_str is ok as it was allocated with allocator.
```


## Errors

Fizz uses the standard Zig error mechanism, but also stores error logs under
`vm.env.errors`. The current errors can be printed by:

```zig
fn printErrors(vm: *fizz.Vm) void {
    std.debug.print("VM Errors: {any}\n", .{vm.env.errors});
}
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

### Instantiating Fizz Values

All values in Fizz are represented by `fizz.Val`. Some may be trivially
constructed, however, types that require extra memory must be allocated with a
`fizz.Environment`.

- `int` - `.{.int = 1}`
- `float` - `.{float = 1.0}`
- `string` - `try env.memory_manager.allocateStringVal("my-string")`
- `list` - `try env.memory_manager.allocateListOfNone(4)`
- `struct` - Not yet supported.
- `function` - TODO: Add documentation.
