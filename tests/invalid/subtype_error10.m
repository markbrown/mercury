:- module subtype_error10.
:- interface.
:- import_module list.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- pred p(list(T)::in, int::out) is det.

:- implementation.

:- pragma type_spec(p/2, T = s).

p(Ts, list.length(Ts)).

