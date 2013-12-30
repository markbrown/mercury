:- module subtypes17.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.

:- import_module list.
:- import_module string.

:- subtype non_empty_list(T) < list(T)
    --->    [ground | ground].

:- pred p((func(non_empty_list(int)) = int)::in, int::out) is det.

p(Func, X) :-
    X = Func([1]).

:- func q(non_empty_list(T)) = T.

q([X | _]) = X.

main(!IO) :-
    p(q, X),
    io.format("Result: %d\n", [i(X)], !IO).

