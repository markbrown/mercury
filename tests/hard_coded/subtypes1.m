:- module subtypes1.
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

:- pred p(non_empty_list(int)::in, int::out) is det.

p(Ns, N) :-
    q(Ns, N).

:- pred q(non_empty_list(T)::in, T::out) is det.

q([T | _], T).

