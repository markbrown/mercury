:- module subtypes13.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module list.
:- import_module string.

:- type enum
    --->    foo
    ;       bar
    ;       baz
    ;       quux.

:- subtype enum1 < enum
    --->    foo
    ;       bar
    ;       baz.

:- pred p(enum1::in, int::out) is det.

p(foo, 1).
p(bar, 2).
p(baz, 3).

main(!IO) :-
    p(foo, Result),
    io.format("Result: %d\n", [i(Result)], !IO).

