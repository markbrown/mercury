:- module subtype_error8.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- pred p(int::in, int::out) is det.

:- implementation.
:- import_module list.

p(_X, Y) :-
    Term = [foo] `with_type` list(s),
    list.length(Term, Y).

