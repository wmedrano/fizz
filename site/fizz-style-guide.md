---
layout: page
title: Fizz Style Guide
nav_enabled: true
nav_order: 2
---

# Style Guide

## Naming

All names should be `kebab-case`. For example, `my-variable` is ok, but
`my_variable` and `MyVariable` are not recommended.

There are additional types of functions that have conventions:

| Item         | Rule                                                            | Example         |
|--------------|-----------------------------------------------------------------|-----------------|
| Side Effects | Functions with side effects should end in `!`                   | `struct-set!`   |
| Predicate    | Predicates (functions that return true/false) should end in `?` | `list?`         |
| Conversions  | `<src>-><dst>`                                                  | `list->string`  |
| Special      | Special variables should be surrounded by `*`                   | `*special-var*` |
