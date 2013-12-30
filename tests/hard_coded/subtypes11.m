:- module subtypes11.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module list.
:- import_module maybe.
:- import_module string.

:- subtype yes(T) < maybe(T)
    --->    yes(ground).

main(!IO) :-
    p(yes(yes(1)), X),
    q(X, Y),
    io.format("Result: %d\n", [i(Y)], !IO).

:- pred p(yes(yes(T))::in, yes(T)::out) is det.

p(yes(Y), Y).

:- pred q(yes(T)::in, T::out) is det.

q(yes(T), T).

