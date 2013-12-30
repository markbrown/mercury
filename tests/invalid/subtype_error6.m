:- module subtype_error6.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- implementation.
:- import_module list.

:- typeclass c(T, U) where [].

:- typeclass d(T) where [].

:- instance d(list(T)) <= c(T, s) where [].

