:- module subtype_error9.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- implementation.

:- mutable(m, s, foo, ground, [untrailed]).

