---
layout: page
title: CHANGELOG & Roadmap
nav_enabled: true
nav_order: 4
---

# CHANGELOG & RoadMap

## Roadmap

Fizz aims to deliver on **simpilicity** and **Zig integration**. This means the
following tradeoffs may happen:

- Simplicity over expressiveness.
- Simplicity over performance.
  - Fizz aims to be about as performant as Python but can adjust to optimize
    specific use cases.
- Ease of Zig build over porting to C/C++/Rust/...

## Releases

### 0.2.0 (In Progress)

Will focus on:

- Improved error reporting.
- Incorporating user feedback.
- Performance & API tweaks.

- `Vm.evalStr` returns a Zig type by default.
- Allow define within subexpressions.

### 0.1.1 (Current)

- Add `map` and `filter` functions.

### 0.1.0

Status: Target feature set implemented. In validation phase.

- Support int, float, string, list, struct, and functions.
- Support converting from `fizz.Val` to Zig values.
- Provide a set of builtin functions.
- Support for modules.
