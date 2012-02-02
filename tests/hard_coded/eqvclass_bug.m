:- module eqvclass_bug.

:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.


:- implementation.

:- import_module eqvclass.

main(!IO) :-
	ensure_equivalence(0, 0, eqvclass.init, NewEqvClass),
	io.print(NewEqvClass, !IO),
	io.nl(!IO).
