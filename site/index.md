---
layout: home
title: Home
nav_enabled: true
nav_order: 0
---

# Fizz

[website](https://wmedrano.github.io/fizz)

Fizz is an interpretted programming language that aims for simplicity and clean
Zig integration.

WARNING: Fizz is not yet in a usable state.

## Simplicity

It should be easy to get started writing Fizz. Fizz supports the following:

- Simple Syntax - All expressions are of the form `(<function> <operands>...)`.
 > ```lisp
 > >> (define pi 3.14)
 > >> (* 2 pi) ;; 6.28
 > ```
- Common datatypes like ints, floats, strings, and lists.
 > ```lisp
 > >> 1
 > >> 1.2
 > >> (list 1 2 3 4)
 > >> "hello world"
 > ```
- Module system for code organization.
 > ```lisp
 > (import "src/my-module.fizz") ;; Import a fizz script as a module.
 > (define radius 10)
 > (my-module/circle-area radius) ;; Reference values with <filename>/<identifier>.
 > ```

## Zig Integration

Fizz is built in Zig and meant to easily integrate into a Zig codebase.

```zig
var vm = try Vm.init(std.testing.allocator);
defer vm.deinit();
const clear_frames = true;
_ = try vm.evalStr("%test-module%", "(define args (list 1 2 3 4))", clear_frames);
const actual = try vm.evalStr("%test-module%", "(apply + args)", clear_frames);
try std.testing.expectEqualDeep(Val{ .int = 10 }, actual);
```

Zig Integration TODOs:
  1. Support structs.
  2. Allow `Val` to be converted to and from Zig types.
