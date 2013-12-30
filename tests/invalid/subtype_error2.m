:- module subtype_error2.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- type not_allowed 
    --->    not_allowed(s).

