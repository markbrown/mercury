:- module subtype_error1.
:- interface.
:- import_module list.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- type not_allowed == list(s).

