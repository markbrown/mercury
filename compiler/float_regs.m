%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2012 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: float_regs.m
% Author: wangp.
%
% In the following we assume that Mercury `float' is wider than a word,
% and that we are targeting a Mercury abstract machine with float registers.
% The module is not used otherwise.
%
% Arguments in first-order calls are passed via float registers if the formal
% parameter has type `float' or equivalent.  All other arguments are passed via
% regular registers.
%
% Higher-order calls are complicated by polymorphism.  A procedure of type
% `pred(float)' may be an argument to another procedure, where that argument
% position has type `pred(T)'.  Calling that higher-order term should place
% its argument into a regular register (since it is polymorphic), but the
% actual procedure expects its argument in a float register.
%
% We deal with these problems of incompatible calling conventions by
% substituting wrapper closures over the original higher-order terms, when the
% original higher-order term is passed to a callee or stored in a data term,
% where the expected calling convention is different.  See below for examples.
%
% As we have seen, a higher-order type does not identify the register class for
% each argument.  A higher-order inst already contains information about the
% calling convention to use for a term with that inst: the argument modes.
% In this module, we extend higher-order insts to record the register class
% that must be used for each argument, e.g.
%
%       pred(in, out, out) is det /* arg regs: [reg_r, reg_r, reg_f] */
%
% indicates that the first and second arguments must be passed via regular
% registers.  The third argument must be passed via a float register.
%
%-----------------------------------------------------------------------------%
%
% EXAMPLE 1
% ---------
%
%   :- pred get_q(pred(T, T)).
%   :- mode get_q(out(pred(in, out) is det)) is det.
%
%   p(X) :-
%       get_q(Q),
%       call(Q, 1.0, X).
%
% Q has type `pred(float, float)' and we would be misled to pass the float
% arguments in the higher-order call via the float registers.  The inst
% contains the information to correct the higher-order call.
%
%   :- pred get_q(pred(T, T)).
%   :- mode get_q(out(pred(in, out) is det /* arg regs: [reg_r, reg_r] */))
%       is det.
%
%   p(X) :-
%       get_q(Q),
%       % new insts:
%       % Q -> pred(in, out) is det /* arg regs: [reg_r, reg_r] */
%       call(Q, 1.0, X).
%       % arg regs: [reg_r, reg_r]
%
% EXAMPLE 2
% ---------
%
%   :- pred foo(float) is semidet.
%   :- pred q(pred(T)::in(pred(in) is semidet /* arg regs: [reg_r] */), T::in)
%       is semidet.
%
%   p :-
%       F = foo,            /* arg regs: [reg_f] */
%       q(F, 1.0).          /* F incompatible */
%
% becomes
%
%   p :-
%       F = foo,            /* arg regs: [reg_f] */
%       F1 = wrapper1(F),   /* arg regs: [reg_r] */
%       q(F1, 1.0).
%
%   :- pred wrapper(
%       pred(float)::in(pred(in) is semidet /* arg regs: [reg_f] */),
%       float::in) is semidet.
%
%   wrapper1(F, X) :- /* must use reg_r: X */
%       call(F, X).
%
% The wrapper1 predicate has an annotation that causes the code generator to
% use a regular register for the argument X.
%
% EXAMPLE 3
% ---------
%
%   :- type foo(T) ---> mkfoo(pred(T, T)).
%   :- inst mkfoo  ---> mkfoo(pred(in, out) is det).
%
%   :- pred p(foo(float)::out(mkfoo)) is det.
%   :- pred q(float::in, float::in) is det.
%
%   p(Foo) :-
%       Q = q,              /* arg regs: [reg_f, reg_f] */
%       Foo = mkfoo(Q).
%       ...
%
% becomes
%
%   p(Foo) :-
%       Q = q,              /* arg regs: [reg_f, reg_f] */
%       Q1 = wrapper2(Q),   /* arg regs: [reg_r, reg_r] */
%       Foo = mkfoo(Q1).
%
% `q' needs to be wrapped in argument of `mkfoo'.  Foo has type `foo(float)'
% but may be passed to a procedure with the argument type `foo(T)'.
% Then `q' could be extracted from Foo, and called with arguments placed in
% the regular registers.
%
%-----------------------------------------------------------------------------%

:- module transform_hlds.float_regs.
:- interface.

:- import_module hlds.hlds_module.
:- import_module parse_tree.error_util.

:- import_module list.

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers(module_info::in, module_info::out,
    list(error_spec)::out) is det.

%----------------------------------------------------------------------------%
%----------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.inst_match.
:- import_module check_hlds.inst_util.
:- import_module check_hlds.mode_util.
:- import_module check_hlds.polymorphism.
:- import_module check_hlds.type_util.
:- import_module hlds.goal_util.
:- import_module hlds.hlds_data.
:- import_module hlds.hlds_error_util.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_pred.
:- import_module hlds.instmap.
:- import_module hlds.passes_aux.
:- import_module hlds.quantification.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.builtin_lib_types.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_mode.
:- import_module parse_tree.prog_type.
:- import_module parse_tree.set_of_var.
:- import_module transform_hlds.dependency_graph.
:- import_module transform_hlds.lambda.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module io.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module varset.

%-----------------------------------------------------------------------------%

insert_reg_wrappers(!ModuleInfo, Specs) :-
    % In the first phase, update the pred_inst_infos in argument modes to
    % include information about the register type that should be used for
    % each higher-order argument.
    module_info_get_valid_predids(PredIds, !ModuleInfo),
    list.foldl(add_arg_regs_in_pred, PredIds, !ModuleInfo),

    % In the second phase, go over every procedure goal, update instmap deltas
    % to include the information from pred_inst_infos.  When a higher-order
    % variable has an inst that indicates it uses a different calling
    % convention than is required in a given context, replace that variable
    % with a wrapper closure which has the expected calling convention.
    list.foldl2(insert_reg_wrappers_pred, PredIds, !ModuleInfo, [], Specs),
    module_info_clobber_dependency_info(!ModuleInfo).

%-----------------------------------------------------------------------------%
%
% First phase
%

:- pred add_arg_regs_in_pred(pred_id::in, module_info::in, module_info::out)
    is det.

add_arg_regs_in_pred(PredId, !ModuleInfo) :-
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo0),
    ProcIds = pred_info_procids(PredInfo0),
    list.foldl(add_arg_regs_in_proc(!.ModuleInfo), ProcIds,
        PredInfo0, PredInfo),
    module_info_set_pred_info(PredId, PredInfo, !ModuleInfo).

:- pred add_arg_regs_in_proc(module_info::in, proc_id::in,
    pred_info::in, pred_info::out) is det.

add_arg_regs_in_proc(ModuleInfo, ProcId, PredInfo0, PredInfo) :-
    pred_info_get_markers(PredInfo0, PredMarkers),
    pred_info_proc_info(PredInfo0, ProcId, ProcInfo0),
    proc_info_get_argmodes(ProcInfo0, ArgModes0),
    ( check_marker(PredMarkers, marker_class_instance_method) ->
        % For class instance methods use the argument types before
        % instance types were substituted. The list of arguments in the
        % procedure may be longer due to type_infos and typeclass_infos.
        pred_info_get_instance_method_arg_types(PredInfo0, IM_ArgTypes),
        list.length(IM_ArgTypes, Num_IM_ArgTypes),
        split_list_from_end(Num_IM_ArgTypes, ArgModes0, FrontModes,
            ArgModes1),
        list.map_corresponding(add_arg_regs_in_proc_arg(ModuleInfo),
            IM_ArgTypes, ArgModes1, ArgModes2),
        ArgModes = FrontModes ++ ArgModes2
    ;
        pred_info_get_arg_types(PredInfo0, ArgTypes),
        list.map_corresponding(add_arg_regs_in_proc_arg(ModuleInfo),
            ArgTypes, ArgModes0, ArgModes)
    ),
    proc_info_set_argmodes(ArgModes, ProcInfo0, ProcInfo),
    pred_info_set_proc_info(ProcId, ProcInfo, PredInfo0, PredInfo).

:- pred add_arg_regs_in_proc_arg(module_info::in, mer_type::in,
    mer_mode::in, mer_mode::out) is det.

add_arg_regs_in_proc_arg(ModuleInfo, RealVarType, ArgMode0, ArgMode) :-
    (
        type_to_ctor_and_args(RealVarType, _TypeCtor, TypeArgs),
        TypeArgs = [_ | _]
    ->
        % Even though a type parameter might be substituted by `float', in
        % another procedure it might be left generic, e.g.
        %
        %   :- type f(T) ---> f(pred(T)).
        %   :- inst f    ---> f(pred(in) is semidet).
        %
        %   :- pred p1(f(float)::in(f), float::in) is semidet.
        %   :- pred p2(f(T)::in(f), T::in) is semidet.
        %
        % The same value may be passed to `p1' and `p2' so the higher-order
        % term contained within must use the same calling convention, namely a
        % regular register for its argument.  Therefore while processing `p1'
        % we must undo the type substitution and treat `f(float)' as if it were
        % `f(T)'.
        %
        % A type parameter may also be substituted by a higher-order type, e.g.
        %
        %   :- type g(T) ---> g(T).
        %   :- inst g    ---> g(pred(in) is semidet).
        %
        %   :- pred q1(g(pred(float))::in(g), float::in) is semidet.
        %   :- pred q2(g(pred(T))::in(g), T::in) is semidet.
        %
        % When processing `q1' we must treat the `g(pred(float))' argument as
        % if it were `g(pred(T))'.

        PolymorphicContext = no,
        make_generic_type(PolymorphicContext, RealVarType, AssumedType),
        add_arg_regs_in_mode(ModuleInfo, AssumedType, ArgMode0, ArgMode)
    ;
        ArgMode = ArgMode0
    ).

:- pred make_generic_type(bool::in, mer_type::in, mer_type::out) is det.

make_generic_type(PolymorphicContext, Type0, Type) :-
    (
        type_is_higher_order_details(Type0, Purity, PredOrFunc, EvalMethod,
            ArgTypes0)
    ->
        list.map(make_generic_type(PolymorphicContext), ArgTypes0, ArgTypes),
        construct_higher_order_type(Purity, PredOrFunc, EvalMethod, ArgTypes,
            Type)
    ;
        type_to_ctor_and_args(Type0, TypeCtor, ArgTypes0)
    ->
        (
            ArgTypes0 = [],
            (
                PolymorphicContext = yes,
                TypeCtor = float_type_ctor
            ->
                % We don't actually need to replace `float' by a type variable.
                % Any other type will do, so long as it forces the argument to
                % be passed via a regular register.
                Type = heap_pointer_type
            ;
                Type = Type0
            )
        ;
            ArgTypes0 = [_ | _],
            list.map(make_generic_type(yes), ArgTypes0, ArgTypes),
            construct_type(TypeCtor, ArgTypes, Type)
        )
    ;
        Type = Type0
    ).

:- pred add_arg_regs_in_mode(module_info::in, mer_type::in,
    mer_mode::in, mer_mode::out) is det.

add_arg_regs_in_mode(ModuleInfo, VarType, ArgMode0, ArgMode) :-
    add_arg_regs_in_mode_2(ModuleInfo, set.init, VarType, ArgMode0, ArgMode).

:- pred add_arg_regs_in_mode_2(module_info::in, set(inst_name)::in,
    mer_type::in, mer_mode::in, mer_mode::out) is det.

add_arg_regs_in_mode_2(ModuleInfo, Seen, VarType, ArgMode0, ArgMode) :-
    mode_get_insts(ModuleInfo, ArgMode0, InitialInst0, FinalInst0),
    add_arg_regs_in_inst(ModuleInfo, Seen, VarType, InitialInst0, InitialInst),
    add_arg_regs_in_inst(ModuleInfo, Seen, VarType, FinalInst0, FinalInst),
    % Avoid expanding insts if unchanged.
    (
        InitialInst = InitialInst0,
        FinalInst = FinalInst0
    ->
        ArgMode = ArgMode0
    ;
        ArgMode = (InitialInst -> FinalInst)
    ).

:- pred add_arg_regs_in_inst(module_info::in, set(inst_name)::in, mer_type::in,
    mer_inst::in, mer_inst::out) is det.

add_arg_regs_in_inst(ModuleInfo, Seen0, Type, Inst0, Inst) :-
    (
        Inst0 = ground(Uniq, higher_order(PredInstInfo0)),
        ( type_is_higher_order_details(Type, _, _, _, ArgTypes) ->
            add_arg_regs_in_pred_inst_info(ModuleInfo, Seen0, ArgTypes,
                PredInstInfo0, PredInstInfo)
        ;
            PredInstInfo = PredInstInfo0
        ),
        Inst = ground(Uniq, higher_order(PredInstInfo))
    ;
        Inst0 = any(Uniq, higher_order(PredInstInfo0)),
        ( type_is_higher_order_details(Type, _, _, _, ArgTypes) ->
            add_arg_regs_in_pred_inst_info(ModuleInfo, Seen0, ArgTypes,
                PredInstInfo0, PredInstInfo)
        ;
            PredInstInfo = PredInstInfo0
        ),
        Inst = any(Uniq, higher_order(PredInstInfo))
    ;
        Inst0 = bound(Uniq, InstResults, BoundInsts0),
        list.map(add_arg_regs_in_bound_inst(ModuleInfo, Seen0, Type),
            BoundInsts0, BoundInsts),
        Inst = bound(Uniq, InstResults, BoundInsts)
    ;
        Inst0 = constrained_inst_vars(InstVarSet, SpecInst0),
        add_arg_regs_in_inst(ModuleInfo, Seen0, Type, SpecInst0, SpecInst),
        Inst = constrained_inst_vars(InstVarSet, SpecInst)
    ;
        Inst0 = defined_inst(InstName),
        % XXX is this correct?
        ( set.contains(Seen0, InstName) ->
            Inst = Inst0
        ;
            set.insert(InstName, Seen0, Seen1),
            inst_lookup(ModuleInfo, InstName, Inst1),
            add_arg_regs_in_inst(ModuleInfo, Seen1, Type, Inst1, Inst2),
            % Avoid expanding insts if unchanged.
            ( Inst1 = Inst2 ->
                Inst = Inst0
            ;
                Inst = Inst2
            )
        )
    ;
        ( Inst0 = ground(_, none)
        ; Inst0 = any(_, none)
        ; Inst0 = free
        ; Inst0 = free(_)
        ; Inst0 = not_reached
        ; Inst0 = inst_var(_)
        ; Inst0 = abstract_inst(_, _)
        ),
        Inst = Inst0
    ).

:- pred add_arg_regs_in_pred_inst_info(module_info::in, set(inst_name)::in,
    list(mer_type)::in, pred_inst_info::in, pred_inst_info::out) is det.

add_arg_regs_in_pred_inst_info(ModuleInfo, Seen, ArgTypes, PredInstInfo0,
        PredInstInfo) :-
    PredInstInfo0 = pred_inst_info(PredOrFunc, Modes0, _, Det),
    list.map_corresponding(add_arg_regs_in_mode_2(ModuleInfo, Seen),
        ArgTypes, Modes0, Modes),
    list.map(ho_arg_reg_for_type, ArgTypes, ArgRegs),
    PredInstInfo = pred_inst_info(PredOrFunc, Modes, arg_reg_types(ArgRegs),
        Det).

:- pred add_arg_regs_in_bound_inst(module_info::in, set(inst_name)::in,
    mer_type::in, bound_inst::in, bound_inst::out) is det.

add_arg_regs_in_bound_inst(ModuleInfo, Seen, Type, BoundInst0, BoundInst) :-
    BoundInst0 = bound_functor(ConsId, ArgInsts0),
    (
        get_cons_id_non_existential_arg_types(ModuleInfo, Type, ConsId,
            ArgTypes)
    ->
        (
            ArgTypes = [],
            % When a foreign type overrides a d.u. type, the inst may have
            % arguments but the foreign type does not.
            ArgInsts = ArgInsts0
        ;
            ArgTypes = [_ | _],
            list.map_corresponding(add_arg_regs_in_inst(ModuleInfo, Seen),
                ArgTypes, ArgInsts0, ArgInsts)
        )
    ;
        % XXX handle existentially typed cons_ids
        trace [compile_time(flag("debug_float_regs"))] (
            sorry($module, $pred, "existentially typed cons_id")
        ),
        ArgInsts = ArgInsts0
    ),
    BoundInst = bound_functor(ConsId, ArgInsts).

:- pred ho_arg_reg_for_type(mer_type::in, ho_arg_reg::out) is det.

ho_arg_reg_for_type(Type, RegType) :-
    ( Type = float_type ->
        RegType = ho_arg_reg_f
    ;
        RegType = ho_arg_reg_r
    ).

%-----------------------------------------------------------------------------%
%
% Second phase
%

:- pred insert_reg_wrappers_pred(pred_id::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_pred(PredId, !ModuleInfo, !Specs) :-
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
    ProcIds = pred_info_procids(PredInfo),
    list.foldl2(insert_reg_wrappers_proc(PredId), ProcIds,
        !ModuleInfo, !Specs).

:- pred insert_reg_wrappers_proc(pred_id::in, proc_id::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_proc(PredId, ProcId, !ModuleInfo, !Specs) :-
    module_info_get_preds(!.ModuleInfo, PredTable0),
    map.lookup(PredTable0, PredId, PredInfo0),
    pred_info_get_procedures(PredInfo0, ProcTable0),
    map.lookup(ProcTable0, ProcId, ProcInfo0),

    insert_reg_wrappers_proc_2(ProcInfo0, ProcInfo, PredInfo0, PredInfo1,
        !ModuleInfo, !Specs),

    pred_info_get_procedures(PredInfo1, ProcTable1),
    map.det_update(ProcId, ProcInfo, ProcTable1, ProcTable),
    pred_info_set_procedures(ProcTable, PredInfo1, PredInfo),
    module_info_get_preds(!.ModuleInfo, PredTable1),
    map.det_update(PredId, PredInfo, PredTable1, PredTable),
    module_info_set_preds(PredTable, !ModuleInfo).

:- pred insert_reg_wrappers_proc_2(proc_info::in, proc_info::out,
    pred_info::in, pred_info::out, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_proc_2(!ProcInfo, !PredInfo, !ModuleInfo, !Specs) :-
    % Grab the appropriate fields from the pred_info and proc_info.
    pred_info_get_typevarset(!.PredInfo, TypeVarSet0),
    proc_info_get_headvars(!.ProcInfo, HeadVars),
    proc_info_get_varset(!.ProcInfo, VarSet0),
    proc_info_get_vartypes(!.ProcInfo, VarTypes0),
    proc_info_get_argmodes(!.ProcInfo, ArgModes),
    proc_info_get_goal(!.ProcInfo, Goal0),
    proc_info_get_initial_instmap(!.ProcInfo, !.ModuleInfo, InstMap0),
    proc_info_get_rtti_varmaps(!.ProcInfo, RttiVarMaps0),
    proc_info_get_inst_varset(!.ProcInfo, InstVarSet0),
    proc_info_get_has_parallel_conj(!.ProcInfo, HasParallelConj),

    % Process the goal.
    init_lambda_info(VarSet0, VarTypes0, TypeVarSet0, InstVarSet0,
        RttiVarMaps0, HasParallelConj, !.PredInfo, !.ModuleInfo, Info0),
    insert_reg_wrappers_proc_body(HeadVars, ArgModes, Goal0, Goal1, InstMap0,
        Info0, Info1, !Specs),
    lambda_info_get_varset(Info1, VarSet1),
    lambda_info_get_vartypes(Info1, VarTypes1),
    lambda_info_get_tvarset(Info1, TypeVarSet),
    lambda_info_get_rtti_varmaps(Info1, RttiVarMaps1),
    lambda_info_get_module_info(Info1, !:ModuleInfo),
    lambda_info_get_recompute_nonlocals(Info1, MustRecomputeNonLocals),

    % Check if we need to requantify.
    (
        MustRecomputeNonLocals = yes,
        implicitly_quantify_clause_body_general(ordinary_nonlocals_no_lambda,
            HeadVars, _Warnings, Goal1, Goal2, VarSet1, VarSet2, VarTypes1,
            VarTypes2, RttiVarMaps1, RttiVarMaps2)
    ;
        MustRecomputeNonLocals = no,
        Goal2 = Goal1,
        VarSet2 = VarSet1,
        VarTypes2 = VarTypes1,
        RttiVarMaps2 = RttiVarMaps1
    ),

    % We recomputed instmap deltas for atomic goals during the second phase,
    % so we only need to recompute instmap deltas for compound goals now.
    recompute_instmap_delta(do_not_recompute_atomic_instmap_deltas,
        Goal2, Goal, VarTypes2, InstVarSet0, InstMap0, !ModuleInfo),

    VarSet = VarSet2,
    VarTypes = VarTypes2,
    RttiVarMaps = RttiVarMaps2,

    % Set the new values of the fields in proc_info and pred_info.
    proc_info_set_goal(Goal, !ProcInfo),
    proc_info_set_varset(VarSet, !ProcInfo),
    proc_info_set_vartypes(VarTypes, !ProcInfo),
    proc_info_set_rtti_varmaps(RttiVarMaps, !ProcInfo),
    proc_info_set_headvars(HeadVars, !ProcInfo),
    ensure_all_headvars_are_named(!ProcInfo),
    pred_info_set_typevarset(TypeVarSet, !PredInfo).

:- pred insert_reg_wrappers_proc_body(list(prog_var)::in, list(mer_mode)::in,
    hlds_goal::in, hlds_goal::out, instmap::in,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_proc_body(HeadVars, ArgModes, Goal0, Goal, InstMap0,
        !Info, !Specs) :-
    insert_reg_wrappers_goal(Goal0, Goal1, InstMap0, InstMap1, !Info, !Specs),
    % Ensure that all arguments match their final insts.
    lambda_info_get_module_info(!.Info, ModuleInfo),
    mode_list_get_final_insts(ModuleInfo, ArgModes, FinalInsts),
    assoc_list.from_corresponding_lists(HeadVars, FinalInsts,
        VarsExpectInsts),
    fix_branching_goal(VarsExpectInsts, Goal1, InstMap1, Goal, !Info,
        !Specs).

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers_goal(hlds_goal::in, hlds_goal::out,
    instmap::in, instmap::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_goal(Goal0, Goal, !InstMap, !Info, !Specs) :-
    ( instmap_is_reachable(!.InstMap) ->
        insert_reg_wrappers_goal_2(Goal0, Goal, !InstMap, !Info, !Specs)
    ;
        Goal = Goal0
    ).

:- pred insert_reg_wrappers_goal_2(hlds_goal::in, hlds_goal::out,
    instmap::in, instmap::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_goal_2(Goal0, Goal, !InstMap, !Info, !Specs) :-
    Goal0 = hlds_goal(GoalExpr0, GoalInfo0),
    (
        GoalExpr0 = unify(_LHS, _RHS, _Mode, _Unification, _Context),
        insert_reg_wrappers_unify_goal(GoalExpr0, GoalInfo0, Goal, !InstMap,
            !Info, !Specs)
    ;
        GoalExpr0 = conj(ConjType, Goals0),
        (
            ConjType = plain_conj,
            insert_reg_wrappers_conj(Goals0, Goals, !InstMap, !Info, !Specs)
        ;
            ConjType = parallel_conj,
            list.map_foldl3(insert_reg_wrappers_goal, Goals0, Goals,
                !InstMap, !Info, !Specs)
        ),
        GoalExpr = conj(ConjType, Goals),
        Goal = hlds_goal(GoalExpr, GoalInfo0),
        % Imported procedures may have a body consisting of an empty
        % conjunction, yet have an `unreachable' instmap delta.
        % Then we must make !:InstMap `unreachable' as well otherwise
        % we will run into problems at fix_branching_goal.
        update_instmap_if_unreachable(Goal, !InstMap)
    ;
        GoalExpr0 = disj(Goals0),
        NonLocals = goal_info_get_nonlocals(GoalInfo0),
        insert_reg_wrappers_disj(Goals0, Goals, NonLocals, !InstMap, !Info,
            !Specs),
        GoalExpr = disj(Goals),
        Goal = hlds_goal(GoalExpr, GoalInfo0)
    ;
        GoalExpr0 = switch(Var, CanFail, Cases0),
        NonLocals = goal_info_get_nonlocals(GoalInfo0),
        insert_reg_wrappers_switch(Var, Cases0, Cases, NonLocals, !InstMap,
            !Info, !Specs),
        GoalExpr = switch(Var, CanFail, Cases),
        Goal = hlds_goal(GoalExpr, GoalInfo0)
    ;
        GoalExpr0 = negation(SubGoal0),
        insert_reg_wrappers_goal(SubGoal0, SubGoal, !.InstMap, _, !Info,
            !Specs),
        GoalExpr = negation(SubGoal),
        Goal = hlds_goal(GoalExpr, GoalInfo0),
        update_instmap_if_unreachable(Goal, !InstMap)
    ;
        GoalExpr0 = scope(Reason, SubGoal0),
        ( Reason = from_ground_term(_, from_ground_term_construct) ->
            % The subgoal cannot construct higher order values.
            GoalExpr = GoalExpr0,
            Goal = hlds_goal(GoalExpr, GoalInfo0),
            update_instmap(Goal, !InstMap)
        ;
            insert_reg_wrappers_goal(SubGoal0, SubGoal, !InstMap, !Info,
                !Specs),
            GoalExpr = scope(Reason, SubGoal),
            Goal = hlds_goal(GoalExpr, GoalInfo0)
        )
    ;
        GoalExpr0 = if_then_else(_, _, _, _),
        NonLocals = goal_info_get_nonlocals(GoalInfo0),
        insert_reg_wrappers_ite(NonLocals, GoalExpr0, GoalExpr, !InstMap,
            !Info, !Specs),
        Goal = hlds_goal(GoalExpr, GoalInfo0)
    ;
        GoalExpr0 = plain_call(PredId, ProcId, Args0, Builtin,
            MaybeUnifyContext, SymName),
        Context = goal_info_get_context(GoalInfo0),
        insert_reg_wrappers_plain_call(PredId, ProcId, Args0, Args, WrapGoals,
            MissingProc, !.InstMap, Context, !Info, !Specs),
        (
            MissingProc = no,
            GoalExpr1 = plain_call(PredId, ProcId, Args, Builtin,
                MaybeUnifyContext, SymName),
            finish_call_goal(WrapGoals, GoalExpr1, GoalInfo0, Goal, !InstMap,
                !Info)
        ;
            MissingProc = yes,
            Goal = Goal0
        )
    ;
        GoalExpr0 = generic_call(GenericCall, Args0, Modes0, _MaybeArgRegs0,
            Determinism),
        (
            GenericCall = higher_order(CallVar, _Purity, _PredOrFunc, _Arity),
            Context = goal_info_get_context(GoalInfo0),
            insert_reg_wrappers_higher_order_call(CallVar, Args0, Args, Modes,
                ArgsRegs, WrapGoals, !.InstMap, Context, !Info, !Specs),
            GoalExpr1 = generic_call(GenericCall, Args, Modes,
                arg_reg_types(ArgsRegs), Determinism),
            finish_call_goal(WrapGoals, GoalExpr1, GoalInfo0, Goal, !InstMap,
                !Info)
        ;
            GenericCall = class_method(_TCIVar, MethodNum, ClassId, _),
            Context = goal_info_get_context(GoalInfo0),
            insert_reg_wrappers_method_call(ClassId, MethodNum, Args0, Args,
                Modes0, Modes, WrapGoals, !.InstMap, Context, !Info, !Specs),
            % Currently we don't use float registers for method calls.
            GoalExpr1 = generic_call(GenericCall, Args, Modes,
                arg_reg_types_unset, Determinism),
            finish_call_goal(WrapGoals, GoalExpr1, GoalInfo0, Goal, !InstMap,
                !Info)
        ;
            ( GenericCall = event_call(_)
            ; GenericCall = cast(_)
            ),
            Goal = Goal0,
            update_instmap(Goal, !InstMap)
        )
    ;
        GoalExpr0 = call_foreign_proc(Attributes, PredId, ProcId, ForeignArgs0,
            ExtraArgs, MaybeTraceRuntimeCond, PragmaImpl),
        Context = goal_info_get_context(GoalInfo0),
        insert_reg_wrappers_foreign_call(PredId, ProcId, ForeignArgs0,
            ForeignArgs, WrapGoals, !.InstMap, Context, !Info, !Specs),
        GoalExpr1 = call_foreign_proc(Attributes, PredId, ProcId, ForeignArgs,
            ExtraArgs, MaybeTraceRuntimeCond, PragmaImpl),
        finish_call_goal(WrapGoals, GoalExpr1, GoalInfo0, Goal, !InstMap,
            !Info)
    ;
        GoalExpr0 = shorthand(_),
        % These should have been expanded out by now.
        unexpected($module, $pred, "shorthand")
    ).

:- pred finish_call_goal(list(hlds_goal)::in, hlds_goal_expr::in,
    hlds_goal_info::in, hlds_goal::out, instmap::in, instmap::out,
    lambda_info::in, lambda_info::out) is det.

finish_call_goal(WrapGoals, CallGoalExpr0, CallGoalInfo0, Goal,
        !InstMap, !Info) :-
    % Recompute the instmap_delta for the call goal to reflect changes to the
    % callee's argument modes that we made in the first phase.
    CallGoal0 = hlds_goal(CallGoalExpr0, CallGoalInfo0),
    do_recompute_atomic_instmap_delta(CallGoal0, CallGoal, !.InstMap, !Info),
    update_instmap(CallGoal, !InstMap),
    CallGoal = hlds_goal(_, CallGoalInfo),
    conj_list_to_goal(WrapGoals ++ [CallGoal], CallGoalInfo, Goal).

:- pred do_recompute_atomic_instmap_delta(hlds_goal::in, hlds_goal::out,
    instmap::in, lambda_info::in, lambda_info::out) is det.

do_recompute_atomic_instmap_delta(Goal0, Goal, InstMap, !Info) :-
    lambda_info_get_vartypes(!.Info, VarTypes),
    lambda_info_get_inst_varset(!.Info, InstVarSet),
    lambda_info_get_module_info(!.Info, ModuleInfo0),
    recompute_instmap_delta(recompute_atomic_instmap_deltas, Goal0, Goal,
        VarTypes, InstVarSet, InstMap, ModuleInfo0, ModuleInfo),
    lambda_info_set_module_info(ModuleInfo, !Info).

:- pred update_instmap_if_unreachable(hlds_goal::in, instmap::in, instmap::out)
    is det.

update_instmap_if_unreachable(Goal, InstMap0, InstMap) :-
    Goal = hlds_goal(_, GoalInfo),
    InstMapDelta = goal_info_get_instmap_delta(GoalInfo),
    ( instmap_delta_is_unreachable(InstMapDelta) ->
        init_unreachable(InstMap)
    ;
        InstMap = InstMap0
    ).

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers_unify_goal(hlds_goal_expr::in(goal_expr_unify),
    hlds_goal_info::in, hlds_goal::out, instmap::in, instmap::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_unify_goal(GoalExpr0, GoalInfo0, Goal, !InstMap, !Info,
        !Specs) :-
    GoalExpr0 = unify(LHS, RHS0, Mode, Unification0, Context),
    (
        Unification0 = construct(CellVar, ConsId, Args0, UniModes0,
            HowToConstruct, IsUnique, SubInfo),
        (
            RHS0 = rhs_functor(_, IsExistConstruct, _)
        ;
            RHS0 = rhs_var(_),
            unexpected($module, $pred, "construct rhs_var")
        ;
            RHS0 = rhs_lambda_goal(_, _, _, _, _, _, _, _, _),
            unexpected($module, $pred, "construct rhs_lambda_goal")
        ),
        (
            Args0 = [],
            lambda_info_get_module_info(!.Info, ModuleInfo),
            update_construct_goal_instmap_delta(ModuleInfo, CellVar, ConsId,
                Args0, GoalInfo0, GoalInfo, !InstMap),
            Goal = hlds_goal(GoalExpr0, GoalInfo)
        ;
            Args0 = [_ | _],
            GoalContext = goal_info_get_context(GoalInfo0),
            insert_reg_wrappers_construct(CellVar, ConsId, Args0, Args,
                UniModes0, UniModes, MaybeWrappedGoals, !.InstMap, GoalContext,
                !Info, !Specs),
            (
                MaybeWrappedGoals = yes(WrapGoals),
                list.foldl(update_instmap, WrapGoals, !InstMap),
                lambda_info_get_module_info(!.Info, ModuleInfo),
                update_construct_goal_instmap_delta(ModuleInfo, CellVar,
                    ConsId, Args, GoalInfo0, GoalInfo1, !InstMap),
                RHS = rhs_functor(ConsId, IsExistConstruct, Args),
                Unification = construct(CellVar, ConsId, Args, UniModes,
                    HowToConstruct, IsUnique, SubInfo),
                GoalExpr1 = unify(LHS, RHS, Mode, Unification, Context),
                Goal1 = hlds_goal(GoalExpr1, GoalInfo1),
                conj_list_to_goal(WrapGoals ++ [Goal1], GoalInfo1, Goal)
            ;
                MaybeWrappedGoals = no,
                lambda_info_get_module_info(!.Info, ModuleInfo),
                update_construct_goal_instmap_delta(ModuleInfo, CellVar,
                    ConsId, Args0, GoalInfo0, GoalInfo, !InstMap),
                Goal = hlds_goal(GoalExpr0, GoalInfo)
            )
        )
    ;
        Unification0 = deconstruct(CellVar, ConsId, Args, UniModes0,
            CanFail, CanCGC),
        % Update the uni_modes of the deconstruction using the current inst of
        % the deconstructed var. Recompute the instmap delta from the new
        % uni_modes if changed.
        lambda_info_get_module_info(!.Info, ModuleInfo),
        list.length(Args, Arity),
        instmap_lookup_var(!.InstMap, CellVar, CellVarInst0),
        inst_expand(ModuleInfo, CellVarInst0, CellVarInst),
        (
            get_arg_insts(CellVarInst, ConsId, Arity, ArgInsts),
            list.map_corresponding(uni_mode_set_rhs_final_inst(ModuleInfo),
                ArgInsts, UniModes0, UniModes),
            UniModes \= UniModes0
        ->
            Unification = deconstruct(CellVar, ConsId, Args, UniModes,
                CanFail, CanCGC),
            GoalExpr1 = unify(LHS, RHS0, Mode, Unification, Context),
            Goal1 = hlds_goal(GoalExpr1, GoalInfo0),
            do_recompute_atomic_instmap_delta(Goal1, Goal, !.InstMap, !Info)
        ;
            Goal = hlds_goal(GoalExpr0, GoalInfo0)
        ),
        update_instmap(Goal, !InstMap)
    ;
        Unification0 = assign(ToVar, FromVar),
        Delta0 = goal_info_get_instmap_delta(GoalInfo0),
        instmap_lookup_var(!.InstMap, FromVar, Inst),
        instmap_delta_set_var(ToVar, Inst, Delta0, Delta),
        goal_info_set_instmap_delta(Delta, GoalInfo0, GoalInfo1),
        Goal = hlds_goal(GoalExpr0, GoalInfo1),
        update_instmap(Goal, !InstMap)
    ;
        Unification0 = simple_test(_, _),
        Goal = hlds_goal(GoalExpr0, GoalInfo0),
        update_instmap(Goal, !InstMap)
    ;
        Unification0 = complicated_unify(_, _, _),
        unexpected($module, $pred, "complicated_unify")
    ).

:- pred insert_reg_wrappers_construct(prog_var::in, cons_id::in,
    list(prog_var)::in, list(prog_var)::out,
    list(uni_mode)::in, list(uni_mode)::out, maybe(list(hlds_goal))::out,
    instmap::in, prog_context::in, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_construct(CellVar, ConsId, OrigVars, Vars,
        UniModes0, UniModes, MaybeWrappedGoals, InstMap0, Context,
        !Info, !Specs) :-
    lambda_info_get_module_info(!.Info, ModuleInfo),
    lambda_info_get_vartypes(!.Info, VarTypes),
    lookup_var_type(VarTypes, CellVar, CellType),
    (
        % Replace all type parameters by phony type variables.
        % See EXAMPLE 3 at the top of the file.
        type_to_ctor_and_args(CellType, TypeCtor, TypeArgs),
        TypeArgs = [_ | _],
        varset.init(TVarSet0),
        list.map_foldl(replace_type_params_by_dummy_vars, TypeArgs,
            PhonyTypeArgs, TVarSet0, _TVarSet),
        construct_type(TypeCtor, PhonyTypeArgs, PhonyCellType),
        get_cons_id_non_existential_arg_types(ModuleInfo, PhonyCellType,
            ConsId, PhonyArgTypes),
        PhonyArgTypes = [_ | _]
    ->
        uni_modes_to_modes(UniModes0, LhsModes0, RhsModes0),
        list.map_corresponding(add_arg_regs_in_mode(ModuleInfo),
            PhonyArgTypes, LhsModes0, LhsModes),
        list.map_corresponding(add_arg_regs_in_mode(ModuleInfo),
            PhonyArgTypes, RhsModes0, RhsModes),
        modes_to_uni_modes(ModuleInfo, LhsModes, RhsModes, UniModes),
        mode_list_get_initial_insts(ModuleInfo, RhsModes, ArgInitialInsts),
        match_args(InstMap0, Context, PhonyArgTypes, ArgInitialInsts,
            OrigVars, Vars, [], WrapGoals, !Info, !Specs),
        MaybeWrappedGoals = yes(WrapGoals)
    ;
        Vars = OrigVars,
        UniModes = UniModes0,
        MaybeWrappedGoals = no
    ).

:- pred replace_type_params_by_dummy_vars(mer_type::in, mer_type::out,
    tvarset::in, tvarset::out) is det.

replace_type_params_by_dummy_vars(Type0, Type, !TVarSet) :-
    (
        type_is_higher_order_details(Type0, Purity, PredOrFunc, EvalMethod,
            ArgTypes0)
    ->
        list.map_foldl(replace_type_params_by_dummy_vars, ArgTypes0, ArgTypes,
            !TVarSet),
        construct_higher_order_type(Purity, PredOrFunc, EvalMethod, ArgTypes,
            Type)
    ;
        varset.new_var(TVar, !TVarSet),
        Type = type_variable(TVar, kind_star)
    ).

:- pred uni_modes_to_modes(list(uni_mode)::in, list(mer_mode)::out,
    list(mer_mode)::out) is det.

uni_modes_to_modes([], [], []).
uni_modes_to_modes([UniMode | UniModes], [L | Ls], [R | Rs]) :-
    UniMode = ((LI - RI) -> (LF - RF)),
    L = (LI -> LF),
    R = (RI -> RF),
    uni_modes_to_modes(UniModes, Ls, Rs).

:- pred update_construct_goal_instmap_delta(module_info::in, prog_var::in,
    cons_id::in, list(prog_var)::in, hlds_goal_info::in, hlds_goal_info::out,
    instmap::in, instmap::out) is det.

update_construct_goal_instmap_delta(ModuleInfo, CellVar, ConsId, Args,
        GoalInfo0, GoalInfo, !InstMap) :-
    Delta0 = goal_info_get_instmap_delta(GoalInfo0),
    ( instmap_delta_search_var(Delta0, CellVar, CellInst0) ->
        rebuild_cell_inst(ModuleInfo, !.InstMap, ConsId, Args,
            CellInst0, CellInst),
        instmap_delta_set_var(CellVar, CellInst, Delta0, Delta),
        goal_info_set_instmap_delta(Delta, GoalInfo0, GoalInfo),
        apply_instmap_delta_sv(Delta, !InstMap)
    ;
        GoalInfo = GoalInfo0,
        apply_instmap_delta_sv(Delta0, !InstMap)
    ).

:- pred rebuild_cell_inst(module_info::in, instmap::in, cons_id::in,
    list(prog_var)::in, mer_inst::in, mer_inst::out) is det.

rebuild_cell_inst(ModuleInfo, InstMap, ConsId, Args, Inst0, Inst) :-
    (
        Inst0 = bound(Uniq, InstResults, BoundInsts0),
        list.map(rebuild_cell_bound_inst(InstMap, ConsId, Args),
            BoundInsts0, BoundInsts),
        Inst = bound(Uniq, InstResults, BoundInsts)
    ;
        (
            Inst0 = ground(Uniq, higher_order(PredInstInfo0))
        ;
            Inst0 = any(Uniq, higher_order(PredInstInfo0))
        ),
        PredInstInfo0 = pred_inst_info(PredOrFunc, Modes, _, Determinism),
        ( ConsId = closure_cons(ShroudedPredProcId, _EvalMethod) ->
            proc(PredId, _) = unshroud_pred_proc_id(ShroudedPredProcId),
            module_info_pred_info(ModuleInfo, PredId, PredInfo),
            pred_info_get_arg_types(PredInfo, ArgTypes),
            list.length(Args, NumArgs),
            list.det_drop(NumArgs, ArgTypes, MissingArgTypes),
            list.map(ho_arg_reg_for_type, MissingArgTypes, ArgRegs),
            PredInstInfo = pred_inst_info(PredOrFunc, Modes,
                arg_reg_types(ArgRegs), Determinism),
            (
                Inst0 = ground(_, _),
                Inst = ground(Uniq, higher_order(PredInstInfo))
            ;
                Inst0 = any(_, _),
                Inst = any(Uniq, higher_order(PredInstInfo))
            )
        ;
            Inst = Inst0
        )
    ;
        Inst0 = constrained_inst_vars(InstVarSet, SpecInst0),
        rebuild_cell_inst(ModuleInfo, InstMap, ConsId, Args,
            SpecInst0, SpecInst),
        Inst = constrained_inst_vars(InstVarSet, SpecInst)
    ;
        % XXX do we need to handle any of these other cases?
        ( Inst0 = free
        ; Inst0 = free(_)
        ; Inst0 = any(_, none)
        ; Inst0 = ground(_, none)
        ; Inst0 = not_reached
        ; Inst0 = defined_inst(_)
        ),
        Inst = Inst0
    ;
        Inst0 = abstract_inst(_, _),
        unexpected($module, $pred, "abstract_inst")
    ;
        Inst0 = inst_var(_),
        unexpected($module, $pred, "inst_var")
    ).

:- pred rebuild_cell_bound_inst(instmap::in, cons_id::in, list(prog_var)::in,
    bound_inst::in, bound_inst::out) is det.

rebuild_cell_bound_inst(InstMap, ConsId, Args, Inst0, Inst) :-
    Inst0 = bound_functor(BoundConsId, ArgInsts0),
    ( equivalent_cons_ids(ConsId, BoundConsId) ->
        list.map_corresponding(rebuild_cell_bound_inst_arg(InstMap),
            Args, ArgInsts0, ArgInsts),
        Inst = bound_functor(BoundConsId, ArgInsts)
    ;
        Inst = Inst0
    ).

:- pred rebuild_cell_bound_inst_arg(instmap::in, prog_var::in,
    mer_inst::in, mer_inst::out) is det.

rebuild_cell_bound_inst_arg(InstMap, Var, ArgInst0, ArgInst) :-
    instmap_lookup_var(InstMap, Var, VarInst),
    % To cope with LCO.
    ( VarInst = free_inst ->
        ArgInst = ArgInst0
    ;
        ArgInst = VarInst
    ).

:- pred uni_mode_set_rhs_final_inst(module_info::in, mer_inst::in,
    uni_mode::in, uni_mode::out) is det.

uni_mode_set_rhs_final_inst(ModuleInfo, ArgInst, UniMode0, UniMode) :-
    UniMode0 = ((LI - RI) -> (LF - RF)),
    % Only when deconstructing to produce the right variable.
    (
        inst_is_free(ModuleInfo, RI),
        inst_is_bound(ModuleInfo, RF)
    ->
        UniMode = ((LI - RI) -> (LF - ArgInst))
    ;
        UniMode = UniMode0
    ).

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers_conj(list(hlds_goal)::in, list(hlds_goal)::out,
    instmap::in, instmap::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_conj([], [], !InstMap, !Info, !Specs).
insert_reg_wrappers_conj([Goal0 | Goals0], Goals, !InstMap, !Info, !Specs) :-
    % Flatten the conjunction as we go.
    insert_reg_wrappers_goal(Goal0, Goal1, !InstMap, !Info, !Specs),
    goal_to_conj_list(Goal1, Goal1List),
    insert_reg_wrappers_conj(Goals0, Goals1, !InstMap, !Info, !Specs),
    list.append(Goal1List, Goals1, Goals).

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers_disj(list(hlds_goal)::in, list(hlds_goal)::out,
    set_of_progvar::in, instmap::in, instmap::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_disj(Goals0, Goals, NonLocals, InstMap0, InstMap, !Info,
        !Specs) :-
    list.map2_foldl2(insert_reg_wrappers_disjunct(InstMap0),
        Goals0, Goals1, InstMaps1, !Info, !Specs),
    common_instmap_delta(InstMap0, NonLocals, InstMaps1, CommonDelta, !Info),
    ( instmap_delta_is_reachable(CommonDelta) ->
        instmap_delta_to_assoc_list(CommonDelta, VarsExpectInsts),
        list.map_corresponding_foldl2(fix_branching_goal(VarsExpectInsts),
            Goals1, InstMaps1, Goals, !Info, !Specs)
    ;
        Goals = Goals1
    ),
    apply_instmap_delta(InstMap0, CommonDelta, InstMap).

:- pred insert_reg_wrappers_disjunct(instmap::in,
    hlds_goal::in, hlds_goal::out, instmap::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_disjunct(InstMap0, Goal0, Goal, InstMap, !Info, !Specs) :-
    insert_reg_wrappers_goal(Goal0, Goal, InstMap0, InstMap, !Info, !Specs).

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers_switch(prog_var::in,
    list(case)::in, list(case)::out, set_of_progvar::in,
    instmap::in, instmap::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_switch(Var, Cases0, Cases, NonLocals, InstMap0, InstMap,
        !Info, !Specs) :-
    lambda_info_get_vartypes(!.Info, VarTypes),
    lookup_var_type(VarTypes, Var, Type),
    list.map2_foldl2(insert_reg_wrappers_case(Var, Type, InstMap0),
        Cases0, Cases1, InstMaps1, !Info, !Specs),
    common_instmap_delta(InstMap0, NonLocals, InstMaps1, CommonDelta, !Info),
    ( instmap_delta_is_reachable(CommonDelta) ->
        instmap_delta_to_assoc_list(CommonDelta, VarsExpectInsts),
        list.map_corresponding_foldl2(fix_case_goal(VarsExpectInsts),
            Cases1, InstMaps1, Cases, !Info, !Specs)
    ;
        Cases = Cases1
    ),
    apply_instmap_delta(InstMap0, CommonDelta, InstMap).

:- pred insert_reg_wrappers_case(prog_var::in, mer_type::in, instmap::in,
    case::in, case::out, instmap::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_case(Var, Type, InstMap0, Case0, Case, InstMap, !Info,
        !Specs) :-
    Case0 = case(MainConsId, OtherConsIds, Goal0),
    lambda_info_get_module_info(!.Info, ModuleInfo0),
    bind_var_to_functors(Var, Type, MainConsId, OtherConsIds,
        InstMap0, InstMap1, ModuleInfo0, ModuleInfo1),
    lambda_info_set_module_info(ModuleInfo1, !Info),
    insert_reg_wrappers_goal(Goal0, Goal, InstMap1, InstMap, !Info, !Specs),
    Case = case(MainConsId, OtherConsIds, Goal).

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers_ite(set_of_progvar::in,
    hlds_goal_expr::in(goal_expr_ite), hlds_goal_expr::out(goal_expr_ite),
    instmap::in, instmap::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_ite(NonLocals, GoalExpr0, GoalExpr, InstMap0, InstMap,
        !Info, !Specs) :-
    GoalExpr0 = if_then_else(Vars, Cond0, Then0, Else0),
    insert_reg_wrappers_goal(Cond0, Cond, InstMap0, InstMapCond,
        !Info, !Specs),
    insert_reg_wrappers_goal(Then0, Then1, InstMapCond, InstMapThen,
        !Info, !Specs),
    insert_reg_wrappers_goal(Else0, Else1, InstMap0, InstMapElse,
        !Info, !Specs),

    common_instmap_delta(InstMap0, NonLocals, [InstMapThen, InstMapElse],
        CommonDelta, !Info),
    ( instmap_delta_is_reachable(CommonDelta) ->
        instmap_delta_to_assoc_list(CommonDelta, VarsExpectInsts),
        fix_branching_goal(VarsExpectInsts, Then1, InstMapThen, Then,
            !Info, !Specs),
        fix_branching_goal(VarsExpectInsts, Else1, InstMapElse, Else,
            !Info, !Specs)
    ;
        Then = Then1,
        Else = Else1
    ),
    apply_instmap_delta(InstMap0, CommonDelta, InstMap),
    GoalExpr = if_then_else(Vars, Cond, Then, Else).

%-----------------------------------------------------------------------------%

:- pred insert_reg_wrappers_plain_call(pred_id::in, proc_id::in,
    list(prog_var)::in, list(prog_var)::out, list(hlds_goal)::out, bool::out,
    instmap::in, prog_context::in, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_plain_call(PredId, ProcId, Vars0, Vars, WrapGoals,
        MissingProc, InstMap0, Context, !Info, !Specs) :-
    lambda_info_get_module_info(!.Info, ModuleInfo),
    module_info_pred_info(ModuleInfo, PredId, PredInfo),
    pred_info_get_procedures(PredInfo, ProcTable),
    ( map.search(ProcTable, ProcId, ProcInfo) ->
        pred_info_get_arg_types(PredInfo, ArgTypes),
        proc_info_get_argmodes(ProcInfo, ArgModes),
        match_args_for_call(InstMap0, Context, ArgTypes, ArgModes, Vars0, Vars,
            WrapGoals, !Info, !Specs),
        MissingProc = no
    ;
        % XXX After the dep_par_conj pass, some dead procedures are removed
        % but calls to them (from also dead procedures?) remain.
        trace [compile_time(flag("debug_float_regs")), io(!IO)] (
            write_proc_progress_message(
                "% Ignoring call to missing procedure ", PredId, ProcId,
                ModuleInfo, !IO)
        ),
        Vars = Vars0,
        WrapGoals = [],
        MissingProc = yes
    ).

:- pred insert_reg_wrappers_higher_order_call(prog_var::in,
    list(prog_var)::in, list(prog_var)::out, list(mer_mode)::out,
    list(ho_arg_reg)::out, list(hlds_goal)::out, instmap::in, prog_context::in,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_higher_order_call(CallVar, Vars0, Vars, ArgModes, ArgRegs,
        WrapGoals, InstMap0, Context, !Info, !Specs) :-
    lambda_info_get_module_info(!.Info, ModuleInfo),
    lambda_info_get_vartypes(!.Info, VarTypes),
    lookup_var_type(VarTypes, CallVar, CallVarType),
    instmap_lookup_var(InstMap0, CallVar, CallVarInst),
    type_is_higher_order_details_det(CallVarType, _, PredOrFunc, _, ArgTypes),
    list.length(ArgTypes, Arity),
    lookup_pred_inst_info(ModuleInfo, CallVarInst, PredOrFunc, Arity,
        CallVarPredInstInfo),
    CallVarPredInstInfo = pred_inst_info(_, ArgModes, _, _),
    get_ho_arg_regs(CallVarPredInstInfo, ArgTypes, ArgRegs),
    match_args_for_call(InstMap0, Context, ArgTypes, ArgModes, Vars0, Vars,
        WrapGoals, !Info, !Specs).

:- pred insert_reg_wrappers_method_call(class_id::in, int::in,
    list(prog_var)::in, list(prog_var)::out,
    list(mer_mode)::in, list(mer_mode)::out, list(hlds_goal)::out,
    instmap::in, prog_context::in, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_method_call(ClassId, MethodNum, Vars0, Vars,
        Modes0, Modes, WrapGoals, InstMap0, Context, !Info, !Specs) :-
    lambda_info_get_module_info(!.Info, ModuleInfo),
    module_info_get_class_table(ModuleInfo, Classes),
    map.lookup(Classes, ClassId, ClassDefn),
    ClassInterface = ClassDefn ^ class_hlds_interface,
    list.det_index1(ClassInterface, MethodNum, ClassProc),
    ClassProc = hlds_class_proc(PredId, ProcId),
    module_info_pred_proc_info(ModuleInfo, PredId, ProcId, PredInfo, ProcInfo),
    pred_info_get_arg_types(PredInfo, ArgTypes),
    proc_info_get_argmodes(ProcInfo, ProcArgModes),

    % We need to update the modes in the generic_call using the modes from the
    % proc_info because we may have changed them during the first phase.
    % Vars0 is missing the typeclass_info variable, whereas the ArgTypes and
    % ProcArgModes *do* include the respective data for that variable.
    % The problem is, we don't know which argument position the typeclass_info
    % variable appears at, and it's not easy to find out.
    %
    % match_args_for_call has no effect on typeclass_info nor type_info
    % variables, and we know those variables must appear at the head of the
    % argument list. Therefore we can just call match_args_for_call on the
    % non typeclass_info/type_info variables at the tail of Vars0, using the
    % corresponding tails of ArgTypes and ProcArgModes.

    take_non_rtti_types_from_tail(ArgTypes, EndTypes),
    list.length(EndTypes, N),
    split_list_from_end(N, Vars0, StartVars, EndVars0),
    split_list_from_end(N, Modes0, StartModes, _),
    split_list_from_end(N, ProcArgModes, _, EndProcArgModes),

    match_args_for_call(InstMap0, Context, EndTypes, EndProcArgModes,
        EndVars0, EndVars, WrapGoals, !Info, !Specs),

    Vars = StartVars ++ EndVars,
    Modes = StartModes ++ EndProcArgModes.

:- pred take_non_rtti_types_from_tail(list(mer_type)::in, list(mer_type)::out)
    is det.

take_non_rtti_types_from_tail([], []).
take_non_rtti_types_from_tail([Type | Types0], Types) :-
    take_non_rtti_types_from_tail(Types0, Types1),
    (
        ( polymorphism.type_is_typeclass_info(Type)
        ; Type = type_info_type
        )
    ->
        Types = Types1
    ;
        Types = [Type | Types1]
    ).

:- pred insert_reg_wrappers_foreign_call(pred_id::in, proc_id::in,
    list(foreign_arg)::in, list(foreign_arg)::out, list(hlds_goal)::out,
    instmap::in, prog_context::in, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

insert_reg_wrappers_foreign_call(PredId, ProcId, ForeignArgs0, ForeignArgs,
        WrapGoals, InstMap0, Context, !Info, !Specs) :-
    Vars0 = list.map(foreign_arg_var, ForeignArgs0),
    insert_reg_wrappers_plain_call(PredId, ProcId, Vars0, Vars, WrapGoals,
        _MissingProc, InstMap0, Context, !Info, !Specs),
    list.map_corresponding(set_foreign_arg_var, Vars, ForeignArgs0,
        ForeignArgs).

:- pred set_foreign_arg_var(prog_var::in, foreign_arg::in, foreign_arg::out)
    is det.

set_foreign_arg_var(Var, !ForeignArg) :-
    !ForeignArg ^ arg_var := Var.

%-----------------------------------------------------------------------------%

:- pred match_args_for_call(instmap::in, prog_context::in, list(mer_type)::in,
    list(mer_mode)::in, list(prog_var)::in, list(prog_var)::out,
    list(hlds_goal)::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

match_args_for_call(InstMap0, Context, ArgTypes, ArgModes, OrigVars, Vars,
        WrapGoals, !Info, !Specs) :-
    lambda_info_get_module_info(!.Info, ModuleInfo),
    mode_list_get_initial_insts(ModuleInfo, ArgModes, InitialInsts),
    match_args(InstMap0, Context, ArgTypes, InitialInsts, OrigVars, Vars,
        [], WrapGoals, !Info, !Specs).

:- pred match_args(instmap::in, prog_context::in, list(mer_type)::in,
    list(mer_inst)::in, list(prog_var)::in, list(prog_var)::out,
    list(hlds_goal)::in, list(hlds_goal)::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

match_args(InstMap0, Context, ArgTypes, Insts, OrigVars, Vars, !WrapGoals,
        !Info, !Specs) :-
    (
        ArgTypes = [],
        Insts = [],
        OrigVars = []
    ->
        Vars = []
    ;
        ArgTypes = [AT | ATs],
        Insts = [I | Is],
        OrigVars = [OV | OVs]
    ->
        match_arg(InstMap0, Context, AT, I, OV, V, !WrapGoals, !Info, !Specs),
        match_args(InstMap0, Context, ATs, Is, OVs, Vs, !WrapGoals, !Info,
            !Specs),
        Vars = [V | Vs]
    ;
        unexpected($module, $pred, "length mismatch")
    ).

:- pred match_arg(instmap::in, prog_context::in, mer_type::in, mer_inst::in,
    prog_var::in, prog_var::out, list(hlds_goal)::in, list(hlds_goal)::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

match_arg(InstMapBefore, Context, ArgType, ExpectInst, OrigVar, Var,
        !WrapGoals, !Info, !Specs) :-
    lambda_info_get_module_info(!.Info, ModuleInfo),
    lambda_info_get_vartypes(!.Info, VarTypes),
    (
        inst_is_bound(ModuleInfo, ExpectInst),
        type_is_higher_order_details(ArgType, _, PredOrFunc, _,
            ArgPredArgTypes),
        ArgPredArgTypes = [_ | _]
    ->
        lookup_var_type(VarTypes, OrigVar, OrigVarType),
        type_is_higher_order_details_det(OrigVarType, _, _, _,
            OrigPredArgTypes),
        list.length(OrigPredArgTypes, Arity),
        (
            search_pred_inst_info(ModuleInfo, ExpectInst, PredOrFunc, Arity,
                ExpectPredInstInfo)
        ->
            instmap_lookup_var(InstMapBefore, OrigVar, OrigVarInst),
            lookup_pred_inst_info(ModuleInfo, OrigVarInst, PredOrFunc, Arity,
                OrigPredInstInfo),
            get_ho_arg_regs(ExpectPredInstInfo, ArgPredArgTypes,
                ExpectArgRegs),
            get_ho_arg_regs(OrigPredInstInfo, OrigPredArgTypes,
                OrigArgRegs),
            ( OrigArgRegs = ExpectArgRegs ->
                Var = OrigVar
            ;
                create_reg_wrapper(OrigVar, OrigPredInstInfo, ExpectArgRegs,
                    OrigArgRegs, Context, Var, UnifyGoal, !Info),
                list.cons(UnifyGoal, !WrapGoals)
            )
        ;
            lambda_info_get_pred_info(!.Info, PredInfo),
            lambda_info_get_varset(!.Info, VarSet),
            maybe_report_missing_pred_inst(PredInfo, VarSet, OrigVar, Context,
                OrigPredArgTypes, ArgPredArgTypes, !Specs),
            Var = OrigVar
        )
    ;
        Var = OrigVar
    ).

:- pred lookup_pred_inst_info(module_info::in, mer_inst::in, pred_or_func::in,
    int::in, pred_inst_info::out) is det.

lookup_pred_inst_info(ModuleInfo, Inst, PredOrFunc, Arity, PredInstInfo) :-
    (
        search_pred_inst_info(ModuleInfo, Inst, PredOrFunc, Arity,
            PredInstInfo0)
    ->
        PredInstInfo = PredInstInfo0
    ;
        unexpected($module, $pred, "no higher order inst")
    ).

:- pred search_pred_inst_info(module_info::in, mer_inst::in, pred_or_func::in,
    int::in, pred_inst_info::out) is semidet.

search_pred_inst_info(ModuleInfo, Inst, PredOrFunc, Arity, PredInstInfo) :-
    ( search_pred_inst_info_2(ModuleInfo, Inst, PredInstInfo0) ->
        PredInstInfo = PredInstInfo0
    ;
        PredOrFunc = pf_function,
        PredInstInfo = pred_inst_info_standard_func_mode(Arity)
    ).

:- pred search_pred_inst_info_2(module_info::in, mer_inst::in,
    pred_inst_info::out) is semidet.

search_pred_inst_info_2(ModuleInfo, Inst, PredInstInfo) :-
    (
        Inst = any(_, higher_order(PredInstInfo))
    ;
        Inst = ground(_, higher_order(PredInstInfo))
    ;
        Inst = defined_inst(InstName),
        inst_lookup(ModuleInfo, InstName, InstB),
        search_pred_inst_info_2(ModuleInfo, InstB, PredInstInfo)
    ).

:- pred get_ho_arg_regs(pred_inst_info::in, list(mer_type)::in,
    list(ho_arg_reg)::out) is det.

get_ho_arg_regs(PredInstInfo, ArgTypes, ArgRegs) :-
    PredInstInfo = pred_inst_info(_, _, MaybeArgRegs, _),
    (
        MaybeArgRegs = arg_reg_types(ArgRegs)
    ;
        MaybeArgRegs = arg_reg_types_unset,
        list.map(ho_arg_reg_for_type, ArgTypes, ArgRegs)
    ).

    % Emit an error if a higher-order inst cannot be found for the variable,
    % but only if any of its arguments are floats.  We want to avoid reporting
    % errors for code which simply copies a higher-order term when updating an
    % unrelated structure field.
    %
    % XXX improve the conditions for which an error is reported
    %
:- pred maybe_report_missing_pred_inst(pred_info::in, prog_varset::in,
    prog_var::in, prog_context::in, list(mer_type)::in, list(mer_type)::in,
    list(error_spec)::in, list(error_spec)::out) is det.

maybe_report_missing_pred_inst(PredInfo, VarSet, Var, Context,
        ArgTypesA, ArgTypesB, !Specs) :-
    (
        ( list.member(float_type, ArgTypesA)
        ; list.member(float_type, ArgTypesB)
        ),
        % Ignore special predicates.
        not pred_info_get_origin(PredInfo, origin_special_pred(_))
    ->
        Spec = report_missing_higher_order_inst(PredInfo, VarSet, Var,
            Context),
        list.cons(Spec, !Specs)
    ;
        true
    ).

:- func report_missing_higher_order_inst(pred_info, prog_varset, prog_var,
    prog_context) = error_spec.

report_missing_higher_order_inst(PredInfo, VarSet, Var, Context) = Spec :-
    PredPieces = describe_one_pred_info_name(should_module_qualify, PredInfo),
    varset.lookup_name(VarSet, Var, VarName),
    InPieces = [words("In") | PredPieces] ++ [suffix(":"), nl],
    ErrorPieces = [
        words("error: missing higher-order inst for variable"), quote(VarName),
        suffix("."), nl
    ],
    VerbosePieces = [
        words("Please provide the higher-order inst to ensure correctness"),
        words("of the generated code in this grade.")
    ],
    Msg = simple_msg(Context, [
        always(InPieces),
        always(ErrorPieces),
        verbose_only(VerbosePieces)
    ]),
    Spec = error_spec(severity_error, phase_code_gen, [Msg]).

%-----------------------------------------------------------------------------%

    % At the end of a branching goal, non-local variables bound to higher-order
    % terms must agree on the calling convention across all branches.
    % When there is disagreement for a variable, we simply choose one calling
    % convention, then create wrappers in each branch to make that conform to
    % the chosen calling convention.
    %
    % Currently the choice of calling convention is arbitrary and may lead to
    % more wrappers, or more boxing of floats, than if we had chosen another
    % calling convention.  This kind of code should be rare.
    %
:- pred common_instmap_delta(instmap::in, set_of_progvar::in,
    list(instmap)::in, instmap_delta::out, lambda_info::in, lambda_info::out)
    is det.

common_instmap_delta(InstMap0, NonLocals, InstMaps, CommonDelta, !Info) :-
    list.filter_map(
        (pred(InstMap::in, Delta::out) is semidet :-
            instmap_is_reachable(InstMap),
            compute_instmap_delta(InstMap0, InstMap, NonLocals, Delta)
        ), InstMaps, InstMapDeltas),
    (
        InstMapDeltas = [],
        instmap_delta_init_unreachable(CommonDelta)
    ;
        InstMapDeltas = [_ | _],
        lambda_info_get_vartypes(!.Info, VarTypes),
        lambda_info_get_module_info(!.Info, ModuleInfo0),
        merge_instmap_deltas(InstMap0, NonLocals, VarTypes, InstMapDeltas,
            CommonDelta, ModuleInfo0, ModuleInfo),
        lambda_info_set_module_info(ModuleInfo, !Info)
    ).

:- pred fix_branching_goal(assoc_list(prog_var, mer_inst)::in,
    hlds_goal::in, instmap::in, hlds_goal::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

fix_branching_goal(VarsExpectInsts, Goal0, GoalInstMap0, Goal, !Info,
        !Specs) :-
    ( instmap_is_reachable(GoalInstMap0) ->
        % GoalInstMap0 is the instmap at the end of Goal0.
        Goal0 = hlds_goal(_, GoalInfo0),
        Context = goal_info_get_context(GoalInfo0),
        match_vars_insts(VarsExpectInsts, GoalInstMap0, Context,
            map.init, Renaming, [], WrapGoals0, !Info, !Specs),
        (
            WrapGoals0 = [],
            Goal = Goal0
        ;
            WrapGoals0 = [_ | _],
            conjoin_goal_and_goal_list(Goal0, WrapGoals0, Goal1),
            rename_some_vars_in_goal(Renaming, Goal1, Goal)
        )
    ;
        Goal = Goal0
    ).

:- pred fix_case_goal(assoc_list(prog_var, mer_inst)::in,
    case::in, instmap::in, case::out, lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

fix_case_goal(VarsExpectInsts, Case0, GoalInstMap0, Case, !Info, !Specs) :-
    Case0 = case(MainConsId, OtherConsIds, Goal0),
    fix_branching_goal(VarsExpectInsts, Goal0, GoalInstMap0, Goal, !Info,
        !Specs),
    Case = case(MainConsId, OtherConsIds, Goal).

:- pred match_vars_insts(assoc_list(prog_var, mer_inst)::in, instmap::in,
    prog_context::in, prog_var_renaming::in, prog_var_renaming::out,
    list(hlds_goal)::in, list(hlds_goal)::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

match_vars_insts(VarsExpectInsts, InstMap0, Context, !Renaming, !WrapGoals,
        !Info, !Specs) :-
    (
        VarsExpectInsts = []
    ;
        VarsExpectInsts = [Var - Inst | Tail],
        match_var_inst(Var, Inst, InstMap0, Context,
            !Renaming, !WrapGoals, !Info, !Specs),
        match_vars_insts(Tail, InstMap0, Context,
            !Renaming, !WrapGoals, !Info, !Specs)
    ).

:- pred match_var_inst(prog_var::in, mer_inst::in, instmap::in,
    prog_context::in, prog_var_renaming::in, prog_var_renaming::out,
    list(hlds_goal)::in, list(hlds_goal)::out,
    lambda_info::in, lambda_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

match_var_inst(Var, ExpectInst, InstMap0, Context, !Renaming, !WrapGoals,
        !Info, !Specs) :-
    lambda_info_get_module_info(!.Info, ModuleInfo),
    lambda_info_get_vartypes(!.Info, VarTypes),
    ( inst_is_free(ModuleInfo, ExpectInst) ->
        true
    ;
        lookup_var_type(VarTypes, Var, VarType),
        match_arg(InstMap0, Context, VarType, ExpectInst, Var, SubstVar,
            [], WrapGoals, !Info, !Specs),
        ( Var = SubstVar ->
            true
        ;
            map.det_insert(Var, SubstVar, !Renaming),
            map.det_insert(SubstVar, Var, !Renaming),
            list.append(WrapGoals, !WrapGoals)
        )
    ).

%-----------------------------------------------------------------------------%

:- pred create_reg_wrapper(prog_var::in, pred_inst_info::in,
    list(ho_arg_reg)::in, list(ho_arg_reg)::in, prog_context::in,
    prog_var::out, hlds_goal::out, lambda_info::in, lambda_info::out) is det.

create_reg_wrapper(OrigVar, OrigVarPredInstInfo, OuterArgRegs, InnerArgRegs,
        Context, Var, UnifyGoal, !Info) :-
    lambda_info_get_varset(!.Info, VarSet0),
    lambda_info_get_vartypes(!.Info, VarTypes0),
    lambda_info_get_module_info(!.Info, ModuleInfo0),

    lookup_var_type(VarTypes0, OrigVar, OrigVarType),
    type_is_higher_order_details_det(OrigVarType, Purity, PredOrFunc,
        EvalMethod, PredArgTypes),

    % Create variables for the head variables of the wrapper procedure.
    % These are also the variables in the call in the procedure body.
    create_fresh_vars(PredArgTypes, CallVars, VarSet0, VarSet1,
        VarTypes0, VarTypes1),
    list.length(CallVars, Arity),

    % Create the in the body of the wrapper procedure.
    CallVar = OrigVar,
    OrigVarPredInstInfo = pred_inst_info(_, ArgModes, _, Determinism),
    GenericCall = higher_order(CallVar, Purity, PredOrFunc, Arity),
    CallGoalExpr = generic_call(GenericCall, CallVars, ArgModes,
        arg_reg_types(InnerArgRegs), Determinism),
    CallNonLocals = set_of_var.list_to_set([CallVar | CallVars]),
    instmap_delta_from_mode_list(CallVars, ArgModes, ModuleInfo0,
        CallInstMapDelta),
    goal_info_init(CallNonLocals, CallInstMapDelta, Determinism, Purity,
        Context, CallGoalInfo),
    CallGoal = hlds_goal(CallGoalExpr, CallGoalInfo),

    % Create the replacement variable Var.
    varset.new_var(Var, VarSet1, VarSet),
    add_var_type(Var, OrigVarType, VarTypes1, VarTypes),
    lambda_info_set_varset(VarSet, !Info),
    lambda_info_set_vartypes(VarTypes, !Info),

    % RegR_HeadVars are the wrapper procedure's headvars which must use regular
    % registers.
    list.foldl_corresponding(make_reg_r_headvars(VarTypes),
        CallVars, OuterArgRegs, set_of_var.init, RegR_HeadVars),

    % Create the wrapper procedure.
    DummyPPId = proc(invalid_pred_id, invalid_proc_id),
    DummyShroudedPPId = shroud_pred_proc_id(DummyPPId),
    ConsId = closure_cons(DummyShroudedPPId, EvalMethod),
    InInst = ground(shared, higher_order(OrigVarPredInstInfo)),
    UniModes0 = [(InInst - InInst) -> (InInst - InInst)],
    Unification0 = construct(Var, ConsId, LambdaNonLocals, UniModes0,
        construct_dynamically, cell_is_shared, no_construct_sub_info),
    LambdaNonLocals = [CallVar],
    lambda.expand_lambda(Purity, ho_ground, PredOrFunc, EvalMethod,
        reg_wrapper_proc(RegR_HeadVars), CallVars, ArgModes, Determinism,
        LambdaNonLocals, CallGoal, Unification0, Functor, Unification, !Info),

    % Create the unification goal for Var.
    UnifyMode = (out_mode - in_mode),
    MainContext = umc_implicit("reg_wrapper"),
    UnifyContext = unify_context(MainContext, []),
    UnifyGoalExpr = unify(Var, Functor, UnifyMode, Unification, UnifyContext),
    UnifyNonLocals = set_of_var.make_singleton(Var),
    UnifyPredInstInfo = pred_inst_info(PredOrFunc, ArgModes,
        arg_reg_types(OuterArgRegs), Determinism),
    UnifyPredVarInst = ground(shared, higher_order(UnifyPredInstInfo)),
    UnifyInstMapDelta = instmap_delta_from_assoc_list([
        Var - UnifyPredVarInst]),
    goal_info_init(UnifyNonLocals, UnifyInstMapDelta, detism_det,
        purity_pure, UnifyGoalInfo),
    UnifyGoal = hlds_goal(UnifyGoalExpr, UnifyGoalInfo),

    lambda_info_set_recompute_nonlocals(yes, !Info).

:- pred create_fresh_vars(list(mer_type)::in, list(prog_var)::out,
    prog_varset::in, prog_varset::out, vartypes::in, vartypes::out) is det.

create_fresh_vars([], [], !VarSet, !VarTypes).
create_fresh_vars([Type | Types], [Var | Vars], !VarSet, !VarTypes) :-
    varset.new_var(Var, !VarSet),
    add_var_type(Var, Type, !VarTypes),
    create_fresh_vars(Types, Vars, !VarSet, !VarTypes).

:- pred make_reg_r_headvars(vartypes::in, prog_var::in, ho_arg_reg::in,
    set_of_progvar::in, set_of_progvar::out) is det.

make_reg_r_headvars(VarTypes, Var, RegType, !RegR_HeadVars) :-
    (
        RegType = ho_arg_reg_r,
        lookup_var_type(VarTypes, Var, VarType),
        ( VarType = float_type ->
            set_of_var.insert(Var, !RegR_HeadVars)
        ;
            true
        )
    ;
        RegType = ho_arg_reg_f
    ).

%-----------------------------------------------------------------------------%

:- pred split_list_from_end(int::in, list(T)::in, list(T)::out, list(T)::out)
    is det.

split_list_from_end(EndLen, List, Start, End) :-
    list.length(List, Len),
    StartLen = Len - EndLen,
    ( StartLen = 0 ->
        Start = [],
        End = List
    ; StartLen > 0 ->
        list.det_split_list(StartLen, List, Start, End)
    ;
        unexpected($module, $pred, "list too short")
    ).

%-----------------------------------------------------------------------------%
:- end_module transform_hlds.float_regs.
%-----------------------------------------------------------------------------%
