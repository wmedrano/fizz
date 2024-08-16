---
layout: page
title: Reference
nav_enabled: true
nav_order: 1
---

# Reference

## Meta

### define

Define a value within the current module that can be referenced.

```lisp
>> (define x 12)
>> (define square
>>   (lambda (x) (* x x)))
>> (square x)
$1 = 144
```

### %modules%

Get all the available modules as a list of strings.

```lisp
>> (modules)
$1 = ("%global%" "my-module.fizz")
```

### apply

`(apply <fn> <args-list>)` - Applies `<fn>` by assing in the `args-list`.

```lisp
>> (+ 1 2 3 4)
$1 = 10
>> (apply + (list 1 2 3 4))
$2 = 10
```

## Numbers

### + - * /

Fizz supports the basic arithmetic operators `+`, `-`, `*`, and `/`. `+` and `*`
may take 0 to any number of arguments. `-` and `/` require at least one argument.

```lisp
>> (+ 1 2 3 4)
$1 = 10
>> (- 4 (/ 1 2) (* 2 2))
$2 = -0.5
>> (+)
$3 = 0
>> (*)
$4 = 1
>> (- 1)
$5 = -1
>> (/ 2)
$6 = 1.5
```

### < <= > >=

Fizz supports basic number ordering operators. The operators take 0 to any
number of arguments.

```lisp
>> (<)
$1 = true
>> (< 0)
$2 = true
>> (< 0 1 2)
$2 = true
>> (< 0 1 2 0)
$3 = false
```

## Lists

### list

Create a new list with any number of elements.

```lisp
>> (list)
$1 = ()
>> (list 1 1.1 "hello" (list true))
$2 = (1 1.1 "hello" (true))
```

### len

Get the number of elements in the list.

```lisp
>> (len (list))
$1 = 0
>> (len (list 1 2 3))
$2 = 3
```

### first

Get the first element of a list.

```lisp
>> (first (list 1 2 3))
$1 = 1
```

### rest

Create a list that contains all elements except the first one.

```lisp
>> (rest (list 1))
$1 = ()
>> (rest (list 1 2 3))
$2 = (2 3)
```
