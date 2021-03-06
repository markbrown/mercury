%-----------------------------------------------------------------------------%
% version_hash_table_test.m
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%

:- module version_hash_table_test.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module list.
:- import_module pair.
:- import_module version_hash_table.

%-----------------------------------------------------------------------------%

main(!IO) :-
    % Test `fold' which had an off-by-one bug.
    some [!HT] (
        !:HT = version_hash_table.init_default(generic_hash),
        version_hash_table.set("one", 1, !HT),
        version_hash_table.set("two", 2, !HT),
        version_hash_table.set("three", 3, !HT),
        version_hash_table.fold(concat, !.HT, []) = KVs,
        list.sort(KVs, SortedKVs),
        io.write(SortedKVs, !IO),
        io.nl(!IO)
    ).

:- func concat(K, V, list(pair(K, V))) = list(pair(K, V)).

concat(K, V, Acc) = [K - V | Acc].

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
