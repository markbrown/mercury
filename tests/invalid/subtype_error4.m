:- module subtype_error4.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- implementation.

:- typeclass c(T) where [].

:- instance c(s) where [].

