:- module subtype_export_main1.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module list.
:- import_module string.

:- import_module subtype_export1.

main(!IO) :-
    p(foo, X),
    io.format("Result: %d\n", [i(X)], !IO).

:- pred p(s::in, int::out) is det.

p(foo, 1).
p(bar, 2).

