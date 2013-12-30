:- module subtype_error5.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- implementation.

:- typeclass c(T, U) where [].

:- typeclass d(T) <= c(T, s) where [].

