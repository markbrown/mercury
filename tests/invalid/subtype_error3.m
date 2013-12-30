:- module subtype_error3.
:- interface.

:- type t
    --->    foo
    ;       bar
    ;       baz.

:- subtype s < t
    --->    foo
    ;       bar.

:- subtype not_allowed < s
    --->    foo.

