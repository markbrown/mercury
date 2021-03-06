% Regression test.
% Test the same thing as bad_indirect_reuse2 but with simpler code. 

:- module bad_indirect_reuse2b.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module list.

main(!IO) :-
    copy(foo(1, 2), U),
    H = hide(U),
    oof(U, X),
    io.write(H, !IO),
    io.nl(!IO),
    io.write(X, !IO),
    io.nl(!IO).

:- type foo
    --->    foo(int, int).

:- type hide
    --->    hide(foo).

:- pred oof(foo::in, foo::out) is det.
:- pragma no_inline(oof/2).

oof(foo(A, B), foo(B, A)).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=8 sw=4 et wm=0 tw=0
