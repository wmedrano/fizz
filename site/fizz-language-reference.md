---
layout: page
title: Fizz Language Reference
nav_enabled: true
nav_order: 2
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

### lambda

Lambda is used to define a function.

```lisp
>> (define my-plus-func (lambda (a b) (+ a b)))
>> my-plus-func
$1 = <function >
>> (my-plus-func 2 2)
$2 = 4
>> ((lambda (a b) (- a b)) 2 2)
$3 = 0
```

### =

Returns true if 2 values are equal.

```lisp
>> (= 1 1)
$1 = true
>> (= 1 1.0)
$1 = false
>> (= 1 2)
$2 = false
>> (= "text" (str-concat (list "te" "xt")))
$3 = true
```

### if

`(if <pred> <true-branch> <optional-false-branch>)`

Returns the 2nd argument if the predicate is true, or else returns the 3rd
argument. If the third argument is not present, then it is assumed to be none.

```lisp
>> (if true "true" "false")
$1 = "true"
>> (if false "true" "false")
$2 = "false"
>> (if false "true")
```


### apply

`(apply <fn> <args-list>)` - Applies `<fn>` by assing in the `args-list`.

```lisp
>> (+ 1 2 3 4)
$1 = 10
>> (apply + (list 1 2 3 4))
$2 = 10
```

### %modules%

Get all the available modules as a list of strings.

```lisp
>> (modules)
$1 = ("%global%" "my-module.fizz")
```


## Strings

### ->str

Convert any type to its string representation.

```lisp
>> (->str "string")
$1 = "str"
>> (->str 1)
$2 = "1"
```

### str-len

Get the length of a string.

```lisp
>> (str-len "hello world")
$1 = 11
>> (str-len "")
$2 = 0
```

### str-concat

Concatenate a list of strings.

```lisp
>> (str-concat (list "hello" " " "world"))
$1 = "hello world"
```

### str-substr

Build a string out of a subset of another string.

```lisp
>> (str-substr "012345" 2 4)
$1 = "23"
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

## Struct

### struct

Create a new struct. Takes pairs of symbol, values.

```lisp
>> (struct)
$1 = (struct)
>> (struct 'id 0 'message "hello world!")
$2 = (struct id 0 message "hello world!")
```

### struct-set!

`(struct-set! <struct> <symbol> <value>)`

Set the value of a struct field.

```lisp
>> (define x (struct 'id 0 'message "hello world!")
>> (struct-set x 'id 100)
>> x
$1 = (struct 'id 100 'message "hello world!")
```

### struct-get

Get the value of a struct field.

```lisp
>> (define x (struct 'id 0 'message "hello world!")
>> (struct-get x 'message)
$1 = "hello world"
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

### nth

Get the nth element of a list based on the index. Fails if `idx` is greater or
equal to the length of the list.

```lisp
>> (nth (list 0 1 2 3) 2)
$1 = 2
```
