---
layout: home
title: Home
nav_enabled: true
nav_order: 0
---

# Fizz

Fizz is a **simple** interpretted programming language meant for **embedding in
Zig**.

{: .warning}
> Requires Zig 0.13.0

{: .warning}
> Fizz is not yet in a stable state. If you have a use case that you would like
> handled, file an [🪲 issue](https://github.com/wmedrano/fizz/issues).

**Links**

| [<img width=16px src="https://github.githubassets.com/images/icons/emoji/octocat.png"> GitHub](https://github.com/wmedrano/fizz) | [❤ Sponsor](https://github.com/sponsors/wmedrano)                                                             |
| [📚 Documentation](https://wmedrano.github.io/fizz)                                                                              | [<img width=16px src="https://avatars.githubusercontent.com/u/27973237"> Zig Discord](https://discord.gg/zig) |

## Quickstart

1. Download Fizz and place it in `build.zig.zon`.
   ```sh
   zig fetch --save https://github.com/wmedrano/fiz/archive/refs/tags/v0.3.0.tar.gz
   ```
1. Add Fizz as a dependency in `build.zig`.
   ```zig
   const fizz = b.dependency("fizz", .{.target = target, .optimize = optimize});
   ...
   // Use it for our executable or library.
   exe.root_module.addImport("fizz", fizz.module("fizz"));
   ```
1. Create the Fizz virtual machine.
   ```zig
   const fizz = @import("fizz");

   ...
   var vm = try fizz.Vm.init(allocator);
   defer vm.deinit();
   errdefer std.debug.print("Fizz VM failed:\n{any}\n", .{vm.env.errors});
   ```
1. Evaluate expressions in the VM.
   ```zig
   try vm.evalStr(void, allocator, "(define my-list (list 1 2 3 4))");
   const sum = vm.evalStr(i64, allocator, "(apply + my-list)");
   std.debug.print("Sum was: {d}\n", .{sum});
   ```
1. Call custom Zig functions.
   ```zig
   fn quack(vm: *fizz.Vm, _: []const fizz.Val) fizz.NativeFnError!fizz.Val {
       return vm.env.memory_manager.allocateStringVal("quack!") catch return fizz.NativnFnError.RuntimeError;
   }

   ...
   try vm.registerGlobalFn("quack!", quack);
   const text = try vm.evalStr([]u8, allocator, "(quack!)");
   defer allocator.free(text);
   ```

## Goals

### Simplicity

It should be easy to get started writing Fizz. Fizz supports the following:

- Simple Syntax - All expressions are of the form `(<function> <operands>...)`.
 > ```lisp
 > >> (define pi 3.14)
 > >> (* 2 pi) ;; 6.28
 > >> (define (plus a b) (+ a b))
 > >> (plus 2 2) ;; 4
 > >> (if (< 1 2) "red" "blue") ;; "red"
 > ```
- Common datatypes like ints, floats, strings, structs, and lists.
 > ```lisp
 > >> true
 > >> 1
 > >> 1.2
 > >> "hello world"
 > >> (list 1 2 3 4)
 > >> (struct 'field "yes" 'the-list (list 1 2 3 4))
 > ```

### Zig Integration

Fizz is built in Zig and meant to easily integrate into a Zig codebase.

[📚 documentation](https://wmedrano.github.io/fizz/zig-api)
