---
layout: home
title: Home
nav_enabled: true
nav_order: 0
---

# Fizz

[website](https://wmedrano.github.io/fizz)

Fizz is an interpretted programming language for embedding in Zig. Fizz aims for
**simplicity** and **Zig integration**.
Fizz is a **simple** interpretted programming language to **embed in Zig**.

WARNING: Fizz is not yet in a stable state.

## Simplicity

It should be easy to get started writing Fizz. Fizz supports the following:

- Simple Syntax - All expressions are of the form `(<function> <operands>...)`.
 > ```lisp
 > >> (define pi 3.14)
 > >> (* 2 pi) ;; 6.28
 > ```
- Common datatypes like ints, floats, strings, structs, and lists.
 > ```lisp
 > >> 1
 > >> 1.2
 > >> "hello world"
 > >> (list 1 2 3 4)
 > >> (struct 'field "yes" 'the-list (list 1 2 3 4))
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
_ = try vm.evalStr(std.testing.allocator, "(define args (list 1 2 3 4))");
const v = try vm.evalStr(std.testing.allocator, "args");
const actual = try vm.env.toZig([]i64, std.testing.allocator, v);
defer std.testing.allocator.free(actual);
try std.testing.expectEqualDeep(&[_]i64{ 1, 2, 3, 4 }, actual);
```
