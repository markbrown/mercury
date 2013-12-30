:- module subtypes12.
:- interface.
:- import_module io.
:- pred main(io::di, io::uo) is det.
:- implementation.
:- import_module int.
:- import_module list.
:- import_module string.

:- type parser_base(S, T) == pred(S, list(T), list(T)).

:- subtype parser(S, T) < parser_base(S, T)
    :: (pred(out, in, out) is semidet).

:- pred seq(list(parser(S, T))::in, list(S)::in, list(S)::out,
    list(T)::in, list(T)::out) is semidet.

seq([], !Ss, !Ts).
seq([P | Ps], !Ss, !Ts) :-
    P(S, !Ts),
    list.cons(S, !Ss),
    seq(Ps, !Ss, !Ts).

:- pred n(int::in, int::out, list(int)::in, list(int)::out) is semidet.

n(K, N + K, [N | Ns], Ns).

main(!IO) :-
    Input = [1, 1, 1, 1, 1],
    ( seq([n(1), n(2), n(3)], [], Result, Input, Remainder) ->
        io.format("Result: %s\nRemainder: %s\n",
            [s(string(Result)), s(string(Remainder))], !IO)
    ;
        io.write_string("Parse failed.\n", !IO)
    ).

