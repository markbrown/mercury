:- module subtype_export2.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- type r == t.

:- pred p(r::in, int::out) is det.

:- implementation.

p(foo, 1).
p(bar, 2).
p(baz, 2).

