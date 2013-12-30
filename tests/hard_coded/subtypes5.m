:- module subtypes5.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module list.
:- import_module string.

main(!IO) :-
    p([1], N),
    io.format("Result: %d\n", [i(N)], !IO).

:- subtype non_empty_list(T) < list(T) :: non_empty_list.

:- typeclass foo(T) where [
    pred q(non_empty_list(T)::in, T::out) is det
].

:- pred p(non_empty_list(T)::in, T::out) is det <= foo(T).

p(Ns, N) :-
    q(Ns, N).

:- instance foo(int) where [
    q([N | _], N)
].

