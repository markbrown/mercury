:- module subtypes14.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module list.
:- import_module string.

:- subtype pos < int
    --->    1 ; 2 ; 3.

:- pred p(pos::in, int::out) is det.

p(X, X).

main(!IO) :-
    p(1, Result),
    io.format("Result: %d\n", [i(Result)], !IO).

