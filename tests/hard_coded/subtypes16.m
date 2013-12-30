:- module subtypes16.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.

:- import_module list.
:- import_module string.

:- subtype non_empty_list(T) < list(T)
    --->    [ground | ground].

:- pred p(pred(non_empty_list(int), int)::in(pred(in, out) is det), int::out)
    is det.

p(Pred, X) :-
    Pred([1], X).

:- pred q(non_empty_list(T)::in, T::out) is det.

q([X | _], X).

main(!IO) :-
    p(q, X),
    io.format("Result: %d\n", [i(X)], !IO).

