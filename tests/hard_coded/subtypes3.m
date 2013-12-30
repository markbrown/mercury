:- module subtypes3.
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

:- func f(non_empty_list(int)) = int.

f(Ns) = g(Ns).

:- func g(non_empty_list(T)) = T.

g([T | _]) = T.

