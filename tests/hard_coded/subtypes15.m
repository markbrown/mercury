:- module subtypes15.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module list.
:- import_module maybe.
:- import_module string.

:- subtype yes(T) < maybe(T)
    --->    yes(ground).

:- inst yes(T)
    --->    yes(T).

main(!IO) :-
    p(yes(yes(1)), X),
    q(X, Y),
    io.format("Result: %d\n", [i(Y)], !IO).

:- pred p(maybe(T)::in(yes(I)), T::out(I)) is det.

p(yes(T), T).

:- pred q(yes(T)::in, T::out) is det.

q(yes(T), T).

