%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module follow_vars.
% Main author: conway.

% This module traverses the goal for every procedure, filling in the
% follow_vars field for call(...) goals, and filling in the initial
% follow_vars in the proc_info.  These follow_vars fields are
% a map(var, lval) which constitute an advisory indication to the code
% generator as to which register each variable should be placed in.
%
% They are computed by traversing the goal BACKWARDS.
% At the end of the goal, we want the output variables to go into their
% corresponding registers, so we initialize the follow_vars accordingly.
% As we traverse throught the goal, at each call(...) we attach the 
% follow_vars map we have computed, and start computing a new one to
% be attatch to the preceding call.  When we finish traversing the goal,
% we attatch the last computed follow_vars to the proc_info.

%-----------------------------------------------------------------------------%

:- interface.
:- import_module hlds, llds.

:- pred find_follow_vars(module_info, module_info).
:- mode find_follow_vars(in, out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module list, map, set, std_util.
:- import_module mode_util, term, require.
:- import_module code_util, quantification, arg_info.

%-----------------------------------------------------------------------------%

	% Traverse the module structure, calling `find_follow_vars_in_goal'
	% for each procedure body.

find_follow_vars(ModuleInfo0, ModuleInfo1) :-
	module_info_predids(ModuleInfo0, PredIds),
	find_follow_vars_in_preds(PredIds, ModuleInfo0, ModuleInfo1).

:- pred find_follow_vars_in_preds(list(pred_id), module_info, module_info).
:- mode find_follow_vars_in_preds(in, in, out) is det.

find_follow_vars_in_preds([], ModuleInfo, ModuleInfo).
find_follow_vars_in_preds([PredId | PredIds], ModuleInfo0, ModuleInfo) :-
	module_info_preds(ModuleInfo0, PredTable),
	map__lookup(PredTable, PredId, PredInfo),
	( pred_info_is_imported(PredInfo) ->
		ModuleInfo1 = ModuleInfo0
	;
		pred_info_procids(PredInfo, ProcIds),
		find_follow_vars_in_procs(ProcIds, PredId, ModuleInfo0,
			ModuleInfo1)
	),
	find_follow_vars_in_preds(PredIds, ModuleInfo1, ModuleInfo).

:- pred find_follow_vars_in_procs(list(proc_id), pred_id, module_info,
					module_info).
:- mode find_follow_vars_in_procs(in, in, in, out) is det.

find_follow_vars_in_procs([], _PredId, ModuleInfo, ModuleInfo).
find_follow_vars_in_procs([ProcId | ProcIds], PredId, ModuleInfo0,
					ModuleInfo) :-
	module_info_preds(ModuleInfo0, PredTable0),
	map__lookup(PredTable0, PredId, PredInfo0),
	pred_info_procedures(PredInfo0, ProcTable0),
	map__lookup(ProcTable0, ProcId, ProcInfo0),

	proc_info_goal(ProcInfo0, Goal0),

	find_final_follow_vars(ProcInfo0, FollowVars0),
	find_follow_vars_in_goal(Goal0, ModuleInfo0,
				FollowVars0, Goal, FollowVars),

	proc_info_set_follow_vars(ProcInfo0, FollowVars, ProcInfo1),
	proc_info_set_goal(ProcInfo1, Goal, ProcInfo),

	map__set(ProcTable0, ProcId, ProcInfo, ProcTable),
	pred_info_set_procedures(PredInfo0, ProcTable, PredInfo),
	map__set(PredTable0, PredId, PredInfo, PredTable),
	module_info_set_preds(ModuleInfo0, PredTable, ModuleInfo1),
	find_follow_vars_in_procs(ProcIds, PredId, ModuleInfo1, ModuleInfo).

%-----------------------------------------------------------------------------%

:- pred find_final_follow_vars(proc_info, follow_vars).
:- mode find_final_follow_vars(in, out) is det.

find_final_follow_vars(ProcInfo, Follow) :-
	proc_info_arg_info(ProcInfo, ArgInfo),
	proc_info_headvars(ProcInfo, HeadVars),
	map__init(Follow0),
	( find_final_follow_vars_2(ArgInfo, HeadVars, Follow0, Follow1) ->
		Follow = Follow1
	;
		error("find_final_follow_vars: failed")
	).

:- pred find_final_follow_vars_2(list(arg_info), list(var),
						follow_vars, follow_vars).
:- mode find_final_follow_vars_2(in, in, in, out) is semidet.

find_final_follow_vars_2([], [], Follow, Follow).
find_final_follow_vars_2([arg_info(Loc, Mode)|Args], [Var|Vars],
							Follow0, Follow) :-
	code_util__arg_loc_to_register(Loc, Reg),
	(
		Mode = top_out
	->
		map__set(Follow0, Var, reg(Reg), Follow1)
	;
		Follow0 = Follow1
	),
	find_final_follow_vars_2(Args, Vars, Follow1, Follow).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pred find_follow_vars_in_goal(hlds__goal, module_info, follow_vars,
						hlds__goal, follow_vars).
:- mode find_follow_vars_in_goal(in, in, in, out, out) is det.

find_follow_vars_in_goal(Goal0 - GoalInfo, ModuleInfo, FollowVars0,
					Goal - GoalInfo, FollowVars) :-
	find_follow_vars_in_goal_2(Goal0, ModuleInfo, FollowVars0,
							Goal, FollowVars).

%-----------------------------------------------------------------------------%

:- pred find_follow_vars_in_goal_2(hlds__goal_expr, module_info, follow_vars,
					hlds__goal_expr, follow_vars).
:- mode find_follow_vars_in_goal_2(in, in, in, out, out) is det.

find_follow_vars_in_goal_2(conj(Goals0), ModuleInfo, FollowVars0,
						conj(Goals), FollowVars) :-
	find_follow_vars_in_conj(Goals0, ModuleInfo, FollowVars0, Goals,
			FollowVars).

find_follow_vars_in_goal_2(disj(Goals0), ModuleInfo, FollowVars0,
						disj(Goals), FollowVars) :-
	find_follow_vars_in_disj(Goals0, ModuleInfo, FollowVars0, Goals,
			FollowVars).

find_follow_vars_in_goal_2(not(Vars, Goal0), ModuleInfo, FollowVars0,
						not(Vars, Goal), FollowVars) :-
	find_follow_vars_in_goal(Goal0, ModuleInfo, FollowVars0, Goal,
			FollowVars).

find_follow_vars_in_goal_2(switch(Var, Det, Cases0), 
		ModuleInfo, FollowVars0, switch(Var, Det, Cases), FollowVars) :-
	find_follow_vars_in_cases(Cases0, ModuleInfo, FollowVars0,
			Cases, FollowVars).

find_follow_vars_in_goal_2(if_then_else(Vars, Cond0, Then0, Else0),
			ModuleInfo, FollowVars0,
			if_then_else(Vars, Cond, Then, Else), FollowVars) :-
	find_follow_vars_in_goal(Then0, ModuleInfo, FollowVars0, Then,
			FollowVars1),
	find_follow_vars_in_goal(Cond0, ModuleInfo, FollowVars1, Cond,
			FollowVars),
		% To a first approximation, ignore the else branch.
	find_follow_vars_in_goal(Else0, ModuleInfo, FollowVars0, Else,
		_FollowVars1A).

find_follow_vars_in_goal_2(some(Vars, Goal0), ModuleInfo, FollowVars0,
						some(Vars, Goal), FollowVars) :-
	find_follow_vars_in_goal(Goal0, ModuleInfo, FollowVars0, Goal,
		FollowVars).

find_follow_vars_in_goal_2(call(A,B,C,D,E,_F), ModuleInfo, FollowVars0,
				call(A,B,C,D,E, FollowVars0), FollowVars) :-
	(
		D = is_builtin
	->
		FollowVars = FollowVars0
	;
		find_follow_vars_in_call(A,B, C, ModuleInfo,
						FollowVars0, FollowVars)
	).

find_follow_vars_in_goal_2(unify(A,B,C,D0,E), _ModuleInfo, FollowVars0,
					unify(A,B,C,D,E), FollowVars) :-
	(
		A = term__variable(Var1),
		B = term__variable(Var2),
		D0 = complicated_unify(Mode, Det, _F),
		map__init(Follow0),
		arg_info__unify_arg_info(Det, ArgInfo),
		find_follow_vars_in_call_2(ArgInfo, [Var1, Var2],
						Follow0, FollowVars1)
	->
		D = complicated_unify(Mode, Det, FollowVars0),
		FollowVars = FollowVars1
	;
		D = D0,
		FollowVars = FollowVars0
	).

%-----------------------------------------------------------------------------%

:- pred find_follow_vars_in_call(pred_id, proc_id, list(term), module_info,
						follow_vars, follow_vars).
:- mode find_follow_vars_in_call(in, in, in, in, in, out) is det.

find_follow_vars_in_call(PredId, ProcId, Args0, ModuleInfo, _Follow, Follow) :-
	module_info_preds(ModuleInfo, PredTable),
	map__lookup(PredTable, PredId, PredInfo),
	pred_info_procedures(PredInfo, ProcTable),
	map__lookup(ProcTable, ProcId, ProcInfo),
	proc_info_arg_info(ProcInfo, ArgInfo),
	term__vars_list(Args0, Args),
	map__init(Follow0),
	(
		find_follow_vars_in_call_2(ArgInfo, Args, Follow0, Follow1)
	->
		Follow = Follow1
	;
		error("find_follow_vars_in_call: failed")
	).

:- pred find_follow_vars_in_call_2(list(arg_info), list(var),
						follow_vars, follow_vars).
:- mode find_follow_vars_in_call_2(in, in, in, out) is semidet.

find_follow_vars_in_call_2([], [], Follow, Follow).
find_follow_vars_in_call_2([arg_info(Loc, Mode)|Args], [Var|Vars],
							Follow0, Follow) :-
	code_util__arg_loc_to_register(Loc, Reg),
	(
		Mode = top_in
	->
		map__set(Follow0, Var, reg(Reg), Follow1)
	;
		Follow0 = Follow1
	),
	find_follow_vars_in_call_2(Args, Vars, Follow1, Follow).

%-----------------------------------------------------------------------------%

:- pred find_follow_vars_in_disj(list(hlds__goal), module_info, follow_vars,
					list(hlds__goal), follow_vars).
:- mode find_follow_vars_in_disj(in, in, in, out, out) is det.

find_follow_vars_in_disj([], _ModuleInfo, FollowVars, [], FollowVars).
find_follow_vars_in_disj([Goal0|Goals0], ModuleInfo, FollowVars0,
						[Goal|Goals], FollowVars) :-
	find_follow_vars_in_goal(Goal0, ModuleInfo, FollowVars0, Goal,
		FollowVars),
	find_follow_vars_in_disj(Goals0, ModuleInfo, FollowVars0,
		Goals, _FollowVars1).

%-----------------------------------------------------------------------------%

:- pred find_follow_vars_in_cases(list(case), module_info, follow_vars,
						list(case), follow_vars).
:- mode find_follow_vars_in_cases(in, in, in, out, out) is det.

find_follow_vars_in_cases([], _ModuleInfo, FollowVars, [], FollowVars).
find_follow_vars_in_cases([case(Cons, Goal0)|Goals0], ModuleInfo, FollowVars0,
					[case(Cons, Goal)|Goals], FollowVars) :-
	find_follow_vars_in_goal(Goal0, ModuleInfo, FollowVars0, Goal,
		FollowVars),
	find_follow_vars_in_cases(Goals0, ModuleInfo, FollowVars0, Goals,
		_FollowVars1).

%-----------------------------------------------------------------------------%

:- pred find_follow_vars_in_conj(list(hlds__goal), module_info, follow_vars,
						list(hlds__goal), follow_vars).
:- mode find_follow_vars_in_conj(in, in, in, out, out) is det.

find_follow_vars_in_conj([], _ModuleInfo, FollowVars, [], FollowVars).
find_follow_vars_in_conj([Goal0 | Goals0], ModuleInfo, FollowVars0,
						[Goal | Goals], FollowVars) :-
	find_follow_vars_in_conj(Goals0, ModuleInfo, FollowVars0, Goals,
		FollowVars1),
	find_follow_vars_in_goal(Goal0, ModuleInfo, FollowVars1, Goal,
		FollowVars).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
