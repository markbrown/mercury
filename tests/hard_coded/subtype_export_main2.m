:- module subtype_export_main2.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module list.
:- import_module string.

:- import_module subtype_export2.

main(!IO) :-
    p(foo, X),
    io.format("Result: %d\n", [i(X)], !IO).

