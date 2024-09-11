---
layout: page
title: Fizz Language Reference
nav_enabled: true
nav_order: 2
---

# Reference

## Meta

### define

Values - `(define <name> <value>)`
Functions - `(define (<name> <args...>) <expr>...)`

Define a value that can be referenced.

```lisp
>> (define x 12)
>> (define (square x)
>>   (* x x))
>> (square x)
$1 = 144
```

### lambda

`(lambda (<args...>) <exprs...>)`

Define a function.

```lisp
>> (define my-plus-func (lambda (a b) (+ a b)))
>> my-plus-func
$1 = <function _>
>> (my-plus-func 2 2)
$2 = 4
>> ((lambda (a b) (- a b)) 2 2)
$3 = 0
```

### if

`(if <pred> <true-branch> <optional-false-branch>)`

Returns the `<true-branch>` if the predicate is `true`, or else returns the
`<optional-false-branch>`. If the `<optional-false-branch>` is not omitted, then
it is assumed to be none.

```lisp
>> (if true "true" "false")
$1 = "true"
>> (if false "true" "false")
$2 = "false"
>> (if false "true")
```

### =

`(= <a> <b>)`

Returns true if the two values are equal.

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

### apply

`(apply <fn> <args-list>)` - Applies `<fn>` by passing in the `<args-list>`.

```lisp
>> (+ 1 2 3 4)
$1 = 10
>> (apply + (list 1 2 3 4))
$2 = 10
```


## Strings

### ->str

`(->str <val>)`

Convert any type to its string representation.

```lisp
>> (->str "string")
$1 = "str"
>> (->str 1)
$2 = "1"
```

### str-len

`(str-len <str>)`

Get the length of a string.

```lisp
>> (str-len "hello world")
$1 = 11
>> (str-len "")
$2 = 0
```

### str-concat

`(str-concat <string-list>)`

Concatenate a list of strings.

```lisp
>> (str-concat (list "hello" " " "world"))
$1 = "hello world"
```

### str-substr

`(str-substr <string> <start-inclusive> <end-exclusive>)`

Build a string out of a range from another string.

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

`(<operator> <items...>)`

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

`(struct '<name1> <value1> '<name2> <value2> ...)`

Create a new struct. Takes pairs of symbol, values.

```lisp
>> (struct)
$1 = (struct)
>> (struct 'id 0 'message "hello world!")
$2 = (struct id 0 message "hello world!")
```

### struct-set!

`(struct-set! <struct> '<name> <value>)`

Set the value of a struct field.

```lisp
>> (define x (struct 'id 0 'message "hello world!")
>> (struct-set x 'id 100)
>> x
$1 = (struct 'id 100 'message "hello world!")
```

### struct-get

`(struct-get <struct> '<name>)`

Get the value of a struct field.

```lisp
>> (define x (struct 'id 0 'message "hello world!")
>> (struct-get x 'message)
$1 = "hello world"
```

## Lists

### list

`(list <items...>)`

Create a new list with any number of elements.

```lisp
>> (list)
$1 = ()
>> (list 1 1.1 "hello" (list true))
$2 = (1 1.1 "hello" (true))
```

### list?

`(list? <value>)`

Returns true if the argument is a list.

```lisp
>> (list? (list))
$1 = true
>> (list? (list 1 2 3))
$2 = true
>> (list? "123")
$3 = false
```

### len

`(len <list>)`

Get the number of elements in the list.

```lisp
>> (len (list))
$1 = 0
>> (len (list 1 2 3))
$2 = 3
```

### first

`(first <list>)`

Get the first element of a list.

```lisp
>> (first (list 1 2 3))
$1 = 1
```

### rest

`(rest <list>)`

Create a list that contains all elements except the first one.

```lisp
>> (rest (list 1))
$1 = ()
>> (rest (list 1 2 3))
$2 = (2 3)
```

### nth

`(nth <list> <index>)`

Get the nth element of a list based on the index. Fails if `<index>` is greater
or equal to the length of the list.

```lisp
>> (nth (list 0 1 2 3) 2)
$1 = 2
```

### map

`(map <function> <list>)`

Returns a list by applying `<function>` to each element in `<list>`.

```lisp
>> (map (lambda (n) (+ n 2)) (list 0 1 2))
$1 = (2 3 4)
```

### filter

`(filter <function> <list>)`

Returns a list by duplicating elements from `<list>` that return `true` when
`<function>` is applied.

```lisp
>> (filter (lambda (n) (> 0 n)) (list -1 1 -2 2 -3 3))
$1 = (1 2 3)
```
