:- module subtypes10.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module list.
:- import_module string.

main(!IO) :-
    N = f([1]),
    io.format("Result: %d\n", [i(N)], !IO).

:- subtype non_empty_list(T) < list(T) :: non_empty_list.

:- typeclass foo(T) where [
    func g(non_empty_list(T)::in) = (T::out) is det
].
	
:- func f(non_empty_list(T)::in) = (T::out) is det <= foo(T).

f(Ns) = g(Ns).

:- instance foo(int) where [
    func(g/1) is gi
].

:- func gi(non_empty_list(int)::in) = (int::out) is det.

gi([N | _]) = N.

