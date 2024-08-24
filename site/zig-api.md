---
layout: page
title: Zig API
nav_enabled: true
nav_order: 1
---

- TODO: Finish documentation.
- TODO: Figure out how to use modules from a GitHub repo.
- TODO: Tag a 0.1.0 Fizz release.

# Zig API

## Quickstart

In the following example, we:

1. Create a virtual machine.
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
