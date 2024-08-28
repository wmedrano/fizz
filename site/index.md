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
> Fizz is not yet in a stable state. If you have a use case that you would like
> handled, file an issue [![🪲](Bug)](https://github.com/wmedrano/fizz/issues).

**Links**

| [<img width=16px src="https://github.githubassets.com/images/icons/emoji/octocat.png"> GitHub](https://github.com/wmedrano/fizz) | [❤ Sponsor](https://github.com/sponsors/wmedrano)                                                             |
| [📚 Documentation](https://wmedrano.github.io/fizz)                                                                              | [<img width=16px src="https://avatars.githubusercontent.com/u/27973237"> Zig Discord](https://discord.gg/zig) |

## Goals

### Simplicity

It should be easy to get started writing Fizz. Fizz supports the following:

- Simple Syntax - All expressions are of the form `(<function> <operands>...)`.
 > ```lisp
 > >> (define pi 3.14)
 > >> (* 2 pi) ;; 6.28
 > >> (define plus (lambda (a b) (+ a b)))
 > >> (plus 2 2) ;; 4
 > >> (if (< 1 2) "red" "blue") ;; "red"
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

### Zig Integration

Fizz is built in Zig and meant to easily integrate into a Zig codebase.

[📚 documentation](https://wmedrano.github.io/fizz/zig-api)

```zig
const fizz = @import("fizz");

fn quack(_: *fizz.Environment, _: []const fizz.Val) fizz.NativeFnError!fizz.Val {
	std.debug.print("Quack!\n", .{});
	return .none;
}

pub fn example(allocator: std.mem.Allocator) !void {
    var vm = try fizz.Vm.init(allocator);
    defer vm.deinit();
    errdefer std.debug.print("Fizz VM failed:\n{any}\n", .{vm.env.errors});

    const actual = try vm.evalStr([]i64, allocator, "(list 1 2 3 4)");
    defer allocator.free(actual);
    try std.testing.expectEqualDeep(&[_]i64{ 1, 2, 3, 4 }, actual);

    try vm.registerGlobalFn("quack!", quack);
    try vm.evalStr(void, allocator, "(quack!)");
}
```
