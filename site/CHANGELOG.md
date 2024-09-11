---
layout: page
title: CHANGELOG & Roadmap
nav_enabled: true
nav_order: 4
---

# CHANGELOG & RoadMap

## Roadmap

For current plans see the current milestones on
[GitHub](https://github.com/wmedrano/fizz/milestones).

Fizz aims to deliver on **simpilicity** and **Zig integration**. This means the
following tradeoffs may happen:

- Simplicity over expressiveness.
- Simplicity over performance.
  - Fizz aims to be about as performant as Python but can adjust to optimize
    specific use cases.
- Ease of Zig build over porting to C/C++/Rust/...

## Releases

### 0.3.0 (Current)

- Remove modules. Their implementation was too hacky.

### 0.2.1

- Improved performance by interning symbol strings.
- `(define (<name> <arg>...) <expr>...)` syntax available for functions.

### 0.2.0

**Zig API**

- `Vm.evalStr` returns a Zig type by default.
- `Vm.env.errors` collects errors that may be printed.
- Most functions that take `*Environment` now take a `*Vm`.
- `Environment` has been renamed to `Env`.
- Garbage collection happens automatically. May be set to manual.
- `Vm.keepAlive` and `Vm.allowDeath` allow extending life of a `Val`.

**Fizz Language**

- Allow define within subexpressions.

### 0.1.1

- Add `map` and `filter` functions.

### 0.1.0

Status: Target feature set implemented. In validation phase.

- Support int, float, string, list, struct, and functions.
- Support converting from `fizz.Val` to Zig values.
- Provide a set of builtin functions.
- Support for modules.
