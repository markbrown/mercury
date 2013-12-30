:- module subtype_error7.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- typeclass c(T, U) where [].

:- implementation.

:- pred p(T::in, T::out) is det <= c(T, s).

p(T, T).

