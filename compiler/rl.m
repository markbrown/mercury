%-----------------------------------------------------------------------------%
% Copyright (C) 1998-1999 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
% File: rl.m
% Main author: stayl
%
% Intermediate form used for optimization of Aditi-RL code.
%
% Generated by rl_gen.m.
% Human readable debugging output by rl_dump.m.
% Output to RL bytecodes by rl_out.m.
%
%-----------------------------------------------------------------------------%
:- module rl. 

:- interface.

:- import_module hlds_data, hlds_goal, hlds_module, hlds_pred.
:- import_module instmap, prog_data.
:- import_module assoc_list, list, std_util, map, set.

%-----------------------------------------------------------------------------%

:- type rl_code		==	list(rl_proc).

:- type rl_proc	
	---> rl_proc(
		rl_proc_name,
		list(relation_id),	% input argument relations
		list(relation_id),	% output argument relations
		set(relation_id),	% memoed relations
		relation_info_map,	% all relations used by the procedure
		list(rl_instruction),
		list(pred_proc_id)	% list of Mercury procedures contained
					% in this RL procedure
	).

:- type rl_proc_name
	---> rl_proc_name(
		string,			% user
		string,			% module
		string,			% name
		int			% arity
	).

%-----------------------------------------------------------------------------%

:- type relation_id == int.

:- type relation_info_map == map(relation_id, relation_info).

:- type relation_info
	---> relation_info(
		relation_type,
		list(type),		% schema
		list(index_spec),
			% Only used for base relations - other relations
			% may have different indexes at different times.
		string			% name
	).

:- type relation_type
	--->	permanent(pred_proc_id)
	;	temporary(relation_state).

	% It may be possible that we only want to materialise a relation
	% along certain branches. That should be fairly simple to fix later
	% if it is necessary.
:- type relation_state
	--->	materialised
	;	stream.

%-----------------------------------------------------------------------------%

	% A key range gives an upper and lower bound for the part of the
	% indexed relation to search. For example, a simple B-tree join
	% algorithm takes a tuple from first relation and uses it to build
	% a key-range for the (indexed) second relation. The join condition
	% is then applied to the tuple from the first relation and every tuple
	% in the second which falls within the key range.
:- type key_range
	---> key_range(
		bounding_tuple,		% lower bound
		bounding_tuple,		% upper bound
		maybe(list(type)),	% schema of the tuple used to generate
					% the key range - there isn't one
					% for selects.
		list(type)		% schema of the tuple used to search
					% the B-tree index
	).

:- type bounding_tuple
	--->	infinity		% -infinity for lower bound,
					% +infinity for upper bound
	;	bound(
			assoc_list(int, key_attr)
					% attributes of the key tuple, the
					% associated integer is the index
					% in a full tuple for that index
					% attribute.
		)
	.

:- type key_attr
	--->	functor(cons_id, (type), list(key_attr))
	;	infinity		% -infinity for lower bound,
					% +infinity for upper
					% This is currently not supported,
					% since there may not be a way to
					% construct a term representing
					% infinity.
	;	input_field(int)
	.

%-----------------------------------------------------------------------------%

		% instruction and a comment. 
:- type rl_instruction	==	pair(rl_instr, string).

:- type rl_instr
	--->
		join(
			output_rel,		% output
			relation_id,		% input 1
			relation_id,		% input 2
			join_type,
			rl_goal			% join condition
		)
	;
		subtract(	% output = input 1 - input 2
			output_rel,		% output
			relation_id,		% input 1
			relation_id,		% input 2
			subtract_type,
			rl_goal			% subtraction condition
		)
	;
		% A difference is just a special case of subtract.
		% The inputs must be sorted and have the same schema.	
		difference(	% output = input 1 - input 2
			output_rel,		% output
			relation_id,		% input 1
			relation_id,		% input 2
			difference_type
		)
	;
		% A projection may have any number of output relations to
		% avoid multiple traversals over the input relation.
		% This also does selection - the expressions are allowed to
		% fail.
		% All but one of the outputs must be materialised - at the
		% moment we materialise them all because it is difficult
		% to ensure correctness for streams with side-effects.
		project(
			output_rel,		% output (may be a stream)
			relation_id,		% input
			rl_goal,		% projection expression for
						% stream output
			assoc_list(output_rel, rl_goal),
						% other outputs (materialised)
			project_type
		)		
	;
		union(
			output_rel,		% output
			list(relation_id),	% inputs
			union_type
		)
	;
		% Output = Input1 U Input2, Difference = Input1 - Input2
		% Input1 must have a B-tree index, and is destructively
		% updated to create Output.
		union_diff(
			relation_id,	% output (uo) (same indexes as input 1)
			relation_id,	% input 1 (di)
			relation_id, 	% input 2 (in)
			output_rel,	% difference (out)
			index_spec,
			maybe(output_rel)
				% Used by rl_liveness.m to make sure that
				% the di input has a single reference. The
				% relation_id is used to hold a copy of the
				% di relation if required. The indexes should
				% be added to the copy if it is made.
		)	
	;
		% Insert a relation into another relation.
		% The input relation is destructively updated.
		insert(
			relation_id,	% output (uo) (same indexes as di input)
			relation_id,	% relation to be inserted into (di)
			relation_id,	% relation to insert (in)
			insert_type,
			maybe(output_rel)
				% Used by rl_liveness.m to make sure that
				% the di input has a single reference. The
				% relation_id is used to hold a copy of the
				% di relation if required. The indexes should
				% be added to the copy if it is made.
		)
	;
		sort(
			output_rel,		% output
			relation_id,		% input
			sort_attrs		% attributes to sort on
		)
	;
		% Make the output variable refer to the same relation
		% as the input without copying.
		ref(
			relation_id,		% output
			relation_id 		% input
		)
	;
		% Make a copy of the input relation, making sure the
		% output has the given set of indexes.
		% This could be a bit slow, because the system can't just
		% copy the files, but has to do a full 
		copy(
			output_rel,		% output
			relation_id		% input
		)
	;
		% If there are multiple references to the input, copy the
		% input to the output, otherwise make the output a reference
		% to the input. To introduce this, the compiler must know that
		% there are no later references in the code to the input
		% relation.
		% Make sure the output has the given set of indexes, even
		% if it isn't copied.
		make_unique(
			output_rel,		% output
			relation_id		% input
		)
	;
		% Create an empty relation.
		init(output_rel)
	;
		% add a tuple to a relation.
		insert_tuple(	
			output_rel,		% output
			relation_id,		% input
			rl_goal
		)
	;
		% call an RL procedure
		call(
			rl_proc_name,		% called procedure
			list(relation_id),	% input argument relations
			list(output_rel),	% output argument relations
			set(relation_id)	% subset of the inputs which
						% must be saved across the call,
						% filled in by rl_liveness.m.
		)
	;
		aggregate(
			output_rel,		% output relation
			relation_id,		% input relation
			pred_proc_id,		% predicate to produce the
						% initial accumulator for
						% each group
			pred_proc_id		% predicate to update the
						% accumulator for each tuple.
		)	
	;
		% Make sure the relation has the given index.
		% We don't include a remove_index operation because it
		% would be very expensive and probably not very useful.
		add_index(output_rel)
	;
		% Empty a relation. This will be expensive for permanent
		% relations due to logging.
		clear(relation_id)
	;
		% Drop a pointer to a temporary relation. The relation
		% is left unchanged, but may be garbage collected if
		% there are no references to it.
		unset(relation_id)
	;
		label(label_id)
	;
		conditional_goto(goto_cond, label_id)
	;
		goto(label_id)
	;
		comment
	.

	% An output relation first clears the initial contents of the
	% relation, then initialises the relation with the given set
	% of indexes.
:- type output_rel
	---> output_rel(
		relation_id,
		list(index_spec)
	).

:- type goto_cond
	--->	empty(relation_id)
	;	and(goto_cond, goto_cond)
	;	or(goto_cond, goto_cond)
	;	not(goto_cond).

:- type join_type
	--->	nested_loop
	;	sort_merge(sort_spec, sort_spec)
	;	index(index_spec, key_range)
				% The second relation is indexed.
				% Each tuple in the first relation
				% is used to create a key range
				% for accessing the second. The goal
				% builds the lower and upper bounds
				% on the key range from the input
				% tuple from the first relation.
	;	cross
	;	semi		% The output tuple is copied from the
				% first input tuple. An output projection
				% must be done as a separate operation.
	.

:- type subtract_type
	--->	nested_loop
	;	semi		% The output tuple is copied from the
				% first input tuple. An output projection
				% must be done as a separate operation.
	;	sort_merge(sort_spec, sort_spec)
	;	index(index_spec, key_range)
	.

:- type difference_type
	--->	sort_merge(sort_spec)
	.
		
:- type project_type
	--->	filter
	;	index(index_spec, key_range)
	.

:- type union_type
	--->	sort_merge(sort_spec)
	.

:- type insert_type
	--->	append
	;	index(index_spec).

%-----------------------------------------------------------------------------%

:- type sort_spec
	--->	sort_var(int)		% Some operations, such as union,
					% expect their inputs to be sorted
					% on all attributes, but don't care
					% in which order or direction.
	;	attributes(sort_attrs)
					% Sort on the given attributes.
	.

:- type sort_attrs == assoc_list(int, sort_dir).

:- type sort_dir
	--->	ascending
	;	descending
	.

%-----------------------------------------------------------------------------%

	% We delay converting join conditions to the lower level representation
	% for as long as possible because they are easier to deal with in
	% hlds_goal form.
:- type rl_goal
	---> rl_goal(
		maybe(pred_proc_id),	
				% Predicate from which the expression was
				% taken - used to avoid unnecessarily merging 
				% varsets. Should be `no' if the varset
				% contains vars from multiple procs.
		prog_varset,
		map(prog_var, type),
		instmap,	% instmap before goal
		rl_goal_inputs,
		rl_goal_outputs,
		list(hlds_goal),
		list(rl_var_bounds)
	).

:- type rl_goal_inputs
	--->	no_inputs
	;	one_input(list(prog_var))
	;	two_inputs(list(prog_var), list(prog_var))
	.

:- type rl_goal_outputs == maybe(list(prog_var)).

	% A key_term is an intermediate form of a key_attr which keeps
	% aliasing information. This can be converted into a key_range
	% later. The set of variables attached to each node is the
	% set of all variables in the goal which were found by rl_key.m
	% to have that value.
:- type key_term == pair(key_term_node, set(prog_var)).
:- type key_term_node
        --->    functor(cons_id, (type), list(key_term))
        ;       var
        .

:- type rl_var_bounds == map(prog_var, pair(key_term)).

%-----------------------------------------------------------------------------%

:- type label_id == int.

%-----------------------------------------------------------------------------%

:- pred rl__default_temporary_state(module_info::in,
		relation_state::out) is det.

	% rl__instr_relations(Instr, InputRels, OutputRels).
:- pred rl__instr_relations(rl_instruction::in, 
		list(relation_id)::out, list(relation_id)::out) is det.

	% Return all relations referenced by a goto condition.
:- pred rl__goto_cond_relations(goto_cond::in, 
		list(relation_id)::out) is det.

	% Is the instructions a label, goto or conditional goto.
:- pred rl__instr_ends_block(rl_instruction).
:- mode rl__instr_ends_block(in) is semidet.

	% Strip off the index specification from an output relation.
:- pred rl__output_rel_relation(output_rel::in, relation_id::out) is det.

	% Get a sort specification sorting ascending on all attributes.	
:- pred rl__ascending_sort_spec(list(type)::in, sort_attrs::out) is det.

	% Get a list of all attributes for a given schema.
:- pred rl__attr_list(list(T)::in, list(int)::out) is det.

	% Succeed if the goal contain any of the variables corresponding
	% to the attributes of the given input tuple.
:- pred rl__goal_is_independent_of_input(tuple_num::in,
		rl_goal::in, rl_goal::out) is semidet.

	% Swap the inputs of a goal such as a join condition which
	% as two input relations.
:- pred rl__swap_goal_inputs(rl_goal::in, rl_goal::out) is det.

	% Succeed if the goal produces an output tuple.
:- pred rl__goal_produces_tuple(rl_goal::in) is semidet.

:- type tuple_num
	--->	one
	;	two
	.

%-----------------------------------------------------------------------------%

	% Find out the name of the RL procedure corresponding
	% to the given Mercury procedure.
:- pred rl__get_entry_proc_name(module_info, pred_proc_id, rl_proc_name).
:- mode rl__get_entry_proc_name(in, in, out) is det.

	% Work out the name for a permanent relation.
:- pred rl__permanent_relation_name(module_info::in,
		pred_id::in, string::out) is det.

	% rl__get_permanent_relation_info(ModuleInfo, PredId,
	% 	Owner, Module, Name, Arity, RelationName, SchemaString).
:- pred rl__get_permanent_relation_info(module_info::in, pred_id::in,
		string::out, string::out, string::out, int::out,
		string::out, string::out) is det.

%-----------------------------------------------------------------------------%

:- pred rl__proc_name_to_string(rl_proc_name::in, string::out) is det.
:- pred rl__label_id_to_string(label_id::in, string::out) is det.
:- pred rl__relation_id_to_string(relation_id::in, string::out) is det.

%-----------------------------------------------------------------------------%

	% rl__schemas_to_strings(ModuleInfo, SchemaLists,
	%	TypeDecls, SchemaStrings)
	% 
	% Convert a list of lists of types to a list of schema strings,
	% with the declarations for the types used in TypeDecls.
:- pred rl__schemas_to_strings(module_info::in,
		list(list(type))::in, string::out, list(string)::out) is det.
			
	% Convert a list of types to a schema string.
:- pred rl__schema_to_string(module_info::in,
		list(type)::in, string::out) is det.

	% Produce names acceptable to Aditi (just wrap single
	% quotes around non-alphanumeric-and-underscore names).
:- pred rl__mangle_and_quote_type_name(type_id::in, list(type)::in,
		string::out) is det.
:- pred rl__mangle_and_quote_ctor_name(sym_name::in,
		int::in, string::out) is det.

	% The expression stuff expects that constructor
	% and type names are unquoted.
:- pred rl__mangle_type_name(type_id::in, list(type)::in,
		string::out) is det.
:- pred rl__mangle_ctor_name(sym_name::in, int::in, string::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module code_util, globals, llds_out, options, prog_out.
:- import_module prog_util, type_util.
:- import_module bool, int, require, string.

rl__default_temporary_state(ModuleInfo, TmpState) :-
	module_info_globals(ModuleInfo, Globals),
	globals__lookup_bool_option(Globals, detect_rl_streams, Streams),
	(
		Streams = yes,
		TmpState = stream
	;
		Streams = no,
		% We have to assume that everything must be materialised.
		TmpState = materialised
	).

%-----------------------------------------------------------------------------%

rl__instr_relations(join(output_rel(Output, _), Input1, Input2, _, _) - _, 
		[Input1, Input2], [Output]).
rl__instr_relations(subtract(output_rel(Output, _),
		Input1, Input2, _, _) - _, [Input1, Input2], [Output]).
rl__instr_relations(difference(output_rel(Output, _),
		Input1, Input2, _) - _, [Input1, Input2], [Output]).
rl__instr_relations(project(OutputRel,
		Input, _, OtherOutputRels, _) - _,
		[Input], Outputs) :-
	assoc_list__keys(OtherOutputRels, OutputRels),
	list__map(rl__output_rel_relation, 
		 [OutputRel | OutputRels], Outputs).
rl__instr_relations(union(OutputRel, Inputs, _) - _, Inputs, [Output]) :-
	rl__output_rel_relation(OutputRel, Output).
rl__instr_relations(union_diff(UoOutput, DiInput, Input,
		output_rel(Diff, _), _, _) - _, 
		[DiInput, Input], [UoOutput, Diff]).
rl__instr_relations(insert(DiOutput, DiInput, Input, _, _) - _,
		[DiInput, Input], [DiOutput]).
rl__instr_relations(sort(output_rel(Output, _), Input, _) - _,
		[Input], [Output]).
rl__instr_relations(init(output_rel(Rel, _)) - _, [], [Rel]).
rl__instr_relations(insert_tuple(output_rel(Output, _), Input, _) - _,
		[Input], [Output]).
rl__instr_relations(add_index(output_rel(Rel, _)) - _, [Rel], [Rel]).
rl__instr_relations(clear(Rel) - _, [], [Rel]).
rl__instr_relations(unset(Rel) - _, [], [Rel]).
rl__instr_relations(label(_) - _, [], []).
rl__instr_relations(goto(_) - _, [], []).
rl__instr_relations(comment - _, [], []).
rl__instr_relations(conditional_goto(Cond, _) - _, Inputs, []) :-
	rl__goto_cond_relations(Cond, Inputs).
rl__instr_relations(ref(Output, Input) - _, [Input], [Output]).
rl__instr_relations(copy(output_rel(Output, _), Input) - _,
		[Input], [Output]).
rl__instr_relations(make_unique(output_rel(Output, _), Input) - _,
		[Input], [Output]).
rl__instr_relations(aggregate(output_rel(Output, _), Input, _, _) - _,
		[Input], [Output]).
rl__instr_relations(call(_, Inputs, OutputRels, _) - _,
		Inputs, Outputs) :-
	list__map(rl__output_rel_relation, OutputRels, Outputs).

%-----------------------------------------------------------------------------%

rl__instr_ends_block(goto(_) - _).
rl__instr_ends_block(label(_) - _).
rl__instr_ends_block(conditional_goto(_, _) - _).

%-----------------------------------------------------------------------------%

rl__output_rel_relation(output_rel(Output, _), Output).

%-----------------------------------------------------------------------------%

rl__goto_cond_relations(empty(Rel), [Rel]).
rl__goto_cond_relations(and(Cond1, Cond2), Rels) :-
	rl__goto_cond_relations(Cond1, Rels1),
	rl__goto_cond_relations(Cond2, Rels2),
	list__append(Rels1, Rels2, Rels).
rl__goto_cond_relations(or(Cond1, Cond2), Rels) :-
	rl__goto_cond_relations(Cond1, Rels1),
	rl__goto_cond_relations(Cond2, Rels2),
	list__append(Rels1, Rels2, Rels).
rl__goto_cond_relations(not(Cond), Rels) :-
	rl__goto_cond_relations(Cond, Rels).

%-----------------------------------------------------------------------------%

rl__ascending_sort_spec(Schema, Attrs) :-
	GetAttr =
		lambda([_::in, Attr::out, Index0::in, Index::out] is det, (
			Attr = Index0 - ascending,
			Index is Index0 + 1
		)),
	list__map_foldl(GetAttr, Schema, Attrs, 0, _).

rl__attr_list(Schema, Attrs) :-
	rl__attr_list_2(0, Schema, Attrs).

:- pred rl__attr_list_2(int::in, list(T)::in,
		list(int)::out) is det.

rl__attr_list_2(_, [], []).
rl__attr_list_2(Index, [_ | Types], [Index | Attrs]) :-
	NextIndex is Index + 1,
	rl__attr_list_2(NextIndex, Types, Attrs).

%-----------------------------------------------------------------------------%

rl__goal_is_independent_of_input(InputNo, RLGoal0, RLGoal) :-
	RLGoal0 = rl_goal(A, B, C, D, Inputs0, MaybeOutputs, Goals, H),
	rl__select_input_args(InputNo, Inputs0, Inputs, InputArgs),
	set__list_to_set(InputArgs, InputArgSet),
	\+ (
		MaybeOutputs = yes(Outputs),
		set__list_to_set(Outputs, OutputSet),
		set__intersect(OutputSet, InputArgSet, OutputIntersection),
		\+ set__empty(OutputIntersection)  
	),
	\+ (
		list__member(Goal, Goals),
		Goal = _ - GoalInfo,
		goal_info_get_nonlocals(GoalInfo, NonLocals),
		set__intersect(NonLocals, InputArgSet, Intersection),
		\+ set__empty(Intersection)  
	),
	RLGoal = rl_goal(A, B, C, D, Inputs, MaybeOutputs, Goals, H).

:- pred rl__select_input_args(tuple_num::in, rl_goal_inputs::in,
		rl_goal_inputs::out, list(prog_var)::out) is det.

rl__select_input_args(_, no_inputs, _, _) :-
	error("rl__select_input_args").
rl__select_input_args(one, one_input(Args), no_inputs, Args).
rl__select_input_args(two, one_input(_), _, _) :-
	error("rl__select_input_args").
rl__select_input_args(one, two_inputs(Args, Args2),
		one_input(Args2), Args).
rl__select_input_args(two, two_inputs(Args1, Args),
		one_input(Args1), Args).

rl__swap_goal_inputs(RLGoal0, RLGoal) :-
	RLGoal0 = rl_goal(A, B, C, D, Inputs0, F, G, H),
	( Inputs0 = two_inputs(Inputs1, Inputs2) ->
		RLGoal = rl_goal(A, B, C, D, two_inputs(Inputs2, Inputs1),
			F, G, H)
	;
		error("rl__swap_inputs: goal does not have two inputs to swap")
	).

rl__goal_produces_tuple(RLGoal) :-
	RLGoal = rl_goal(_, _, _, _, _, yes(_), _, _).

%-----------------------------------------------------------------------------%

rl__get_entry_proc_name(ModuleInfo, proc(PredId, ProcId), ProcName) :-
	code_util__make_proc_label(ModuleInfo, PredId, ProcId, Label),
	llds_out__get_proc_label(Label, no, ProcLabel),
	module_info_pred_info(ModuleInfo, PredId, PredInfo),
	pred_info_module(PredInfo, PredModule0),
	pred_info_get_aditi_owner(PredInfo, Owner),
	prog_out__sym_name_to_string(PredModule0, PredModule),
	ProcName = rl_proc_name(Owner, PredModule, ProcLabel, 2).

rl__permanent_relation_name(ModuleInfo, PredId, ProcName) :-
	rl__get_permanent_relation_info(ModuleInfo, PredId, Owner,
		Module, _, _, Name, _),
	string__format("%s/%s/%s", [s(Owner), s(Module), s(Name)],
		ProcName).

rl__get_permanent_relation_info(ModuleInfo, PredId, Owner, PredModule,
		PredName, PredArity, RelName, SchemaString) :-
	module_info_pred_info(ModuleInfo, PredId, PredInfo),
	pred_info_name(PredInfo, PredName),
	pred_info_module(PredInfo, PredModule0),
	prog_out__sym_name_to_string(PredModule0, PredModule),
	pred_info_get_aditi_owner(PredInfo, Owner),
	pred_info_arity(PredInfo, PredArity),
	string__format("%s__%i", [s(PredName), i(PredArity)], RelName),
	pred_info_arg_types(PredInfo, ArgTypes0),
	type_util__remove_aditi_state(ArgTypes0, ArgTypes0, ArgTypes),
	rl__schema_to_string(ModuleInfo, ArgTypes, SchemaString).

%-----------------------------------------------------------------------------%

rl__proc_name_to_string(rl_proc_name(User, Module, Pred, Arity), Str) :-
	string__int_to_string(Arity, ArStr),
	string__append_list([User, "/", Module, "/", Pred, "/", ArStr], Str).

rl__label_id_to_string(Label, Str) :-
	string__int_to_string(Label, Str0),
	string__append("label", Str0, Str).

rl__relation_id_to_string(RelationId, Str) :-
	string__int_to_string(RelationId, Str0),
	string__append("Rel", Str0, Str).

%-----------------------------------------------------------------------------%


rl__schemas_to_strings(ModuleInfo, SchemaList, TypeDecls, SchemaStrings) :-
	map__init(GatheredTypes0),
	set__init(RecursiveTypes0),
	rl__schemas_to_strings_2(ModuleInfo, GatheredTypes0, RecursiveTypes0,
		SchemaList, "", TypeDecls, [], SchemaStrings).

:- pred rl__schemas_to_strings_2(module_info::in, gathered_types::in,
	set(full_type_id)::in, list(list(type))::in,
	string::in, string::out, list(string)::in, list(string)::out) is det.

rl__schemas_to_strings_2(_, _, _, [], TypeDecls, TypeDecls,
		SchemaStrings0, SchemaStrings) :-
	list__reverse(SchemaStrings0, SchemaStrings).
rl__schemas_to_strings_2(ModuleInfo, GatheredTypes0, RecursiveTypes0,
		[Schema0 | Schemas], TypeDecls0, TypeDecls,
		SchemaStrings0, SchemaStrings) :-
	strip_prog_contexts(Schema0, Schema),
	set__init(Parents0),
	rl__gather_types(ModuleInfo, Parents0, Schema,
		GatheredTypes0, GatheredTypes1,
		RecursiveTypes0, RecursiveTypes1,
		TypeDecls0, TypeDecls1,
		"", SchemaString),
	rl__schemas_to_strings_2(ModuleInfo, GatheredTypes1, RecursiveTypes1,
		Schemas, TypeDecls1, TypeDecls,
		[SchemaString | SchemaStrings0], SchemaStrings).

rl__schema_to_string(ModuleInfo, Types0, SchemaString) :-
	map__init(GatheredTypes0),
	set__init(RecursiveTypes0),
	set__init(Parents0),
	strip_prog_contexts(Types0, Types),
	rl__gather_types(ModuleInfo, Parents0, Types,
		GatheredTypes0, _, RecursiveTypes0, _, "", Decls,
		"", SchemaString0),
	string__append_list([Decls, "(", SchemaString0, ")"], SchemaString).

	% Map from type to name and type definition string
:- type gathered_types == map(pair(type_id, list(type)), string).
:- type full_type_id == pair(type_id, list(type)).

	% Go over a list of types collecting declarations for all the
	% types used in the list.
:- pred rl__gather_types(module_info::in, set(full_type_id)::in, 
		list(type)::in, gathered_types::in, gathered_types::out, 
		set(full_type_id)::in, set(full_type_id)::out, 
		string::in, string::out, string::in, string::out) is det.

rl__gather_types(_, _, [], GatheredTypes, GatheredTypes, 
		RecursiveTypes, RecursiveTypes, Decls, Decls,
		TypeString, TypeString).
rl__gather_types(ModuleInfo, Parents, [Type | Types], GatheredTypes0, 
		GatheredTypes, RecursiveTypes0, RecursiveTypes, 
		Decls0, Decls, TypeString0, TypeString) :-
	rl__gather_type(ModuleInfo, Parents, Type, GatheredTypes0,
		GatheredTypes1, RecursiveTypes0, RecursiveTypes1,
		Decls0, Decls1, ThisTypeString),
	( Types = [] ->
		Comma = ""
	;
		Comma = ","
	),
	string__append_list([TypeString0, ThisTypeString, Comma], TypeString1),
	rl__gather_types(ModuleInfo, Parents, Types, GatheredTypes1, 
		GatheredTypes, RecursiveTypes1, RecursiveTypes, 
		Decls1, Decls, TypeString1, TypeString).

:- pred rl__gather_type(module_info::in, set(full_type_id)::in, (type)::in, 
		gathered_types::in, gathered_types::out, set(full_type_id)::in, 
		set(full_type_id)::out, string::in, string::out,
		string::out) is det.

rl__gather_type(ModuleInfo, Parents, Type, GatheredTypes0, GatheredTypes, 
		RecursiveTypes0, RecursiveTypes, Decls0, Decls, ThisType) :-
	classify_type(Type, ModuleInfo, ClassifiedType0),
	( ClassifiedType0 = enum_type ->
		ClassifiedType = user_type
	;
		ClassifiedType = ClassifiedType0
	),
	(
		ClassifiedType = enum_type,
			% this is converted to user_type above
		error("rl__gather_type: enum type")
	;
		ClassifiedType = polymorphic_type,
		error("rl__gather_type: polymorphic type")
	;
		ClassifiedType = char_type,
		GatheredTypes = GatheredTypes0,
		RecursiveTypes = RecursiveTypes0,
		Decls = Decls0,
		ThisType = ":I"
	;
		ClassifiedType = int_type,
		GatheredTypes = GatheredTypes0,
		RecursiveTypes = RecursiveTypes0,
		Decls = Decls0,
		ThisType = ":I"
	;
		ClassifiedType = float_type,
		GatheredTypes = GatheredTypes0,
		RecursiveTypes = RecursiveTypes0,
		Decls = Decls0,
		ThisType = ":D"
	;
		ClassifiedType = str_type,
		GatheredTypes = GatheredTypes0,
		RecursiveTypes = RecursiveTypes0,
		Decls = Decls0,
		ThisType = ":S"
	;
		ClassifiedType = pred_type,
		error("rl__gather_type: pred type")
	;
		ClassifiedType = user_type,
		(
			type_to_type_id(Type, TypeId, Args),
		 	type_constructors(Type, ModuleInfo, Ctors)
		->
			( set__member(TypeId - Args, Parents) ->
				set__insert(RecursiveTypes0, TypeId - Args,
					RecursiveTypes1)
			;
				RecursiveTypes1 = RecursiveTypes0
			),
			(
				map__search(GatheredTypes0, TypeId - Args,
					MangledTypeName0) 
			->
				GatheredTypes = GatheredTypes0,
				Decls = Decls0,
				MangledTypeName = MangledTypeName0,
				RecursiveTypes = RecursiveTypes1
			;
				set__insert(Parents, TypeId - Args,
					Parents1),
				rl__mangle_and_quote_type_name(TypeId,
					Args, MangledTypeName),

				% Record that we have seen this type
				% before processing the sub-terms.
				map__det_insert(GatheredTypes0, TypeId - Args,
					MangledTypeName, GatheredTypes1),

				rl__gather_constructors(ModuleInfo, 
					Parents1, Ctors, GatheredTypes1, 
					GatheredTypes, RecursiveTypes1,
					RecursiveTypes, Decls0, Decls1, 
					"", CtorDecls),

				% Recursive types are marked by a
				% second colon before their declaration.
				( set__member(TypeId - Args, RecursiveTypes) ->
					RecursiveSpec = ":"
				;
					RecursiveSpec = ""
				),
				string__append_list(
					[Decls1, RecursiveSpec, ":",
					MangledTypeName, "=", CtorDecls, " "],
					Decls)	
			),
			string__append(":T", MangledTypeName, ThisType)
		;
			error("rl__gather_type: type_constructors failed")
		)
	).

:- pred rl__gather_constructors(module_info::in, set(full_type_id)::in,
		list(constructor)::in, map(full_type_id, string)::in, 
		map(full_type_id, string)::out, set(full_type_id)::in, 
		set(full_type_id)::out, string::in, string::out,
		string::in, string::out) is det.
				
rl__gather_constructors(_, _, [], GatheredTypes, GatheredTypes, 
		RecursiveTypes, RecursiveTypes, Decls, Decls, 
		CtorDecls, CtorDecls).
rl__gather_constructors(ModuleInfo, Parents, [Ctor | Ctors],
		GatheredTypes0, GatheredTypes, RecursiveTypes0, RecursiveTypes,
		Decls0, Decls, CtorDecls0, CtorDecls) :-
	Ctor = ctor(_, _, CtorName, Args),
	list__length(Args, Arity),
	rl__mangle_and_quote_ctor_name(CtorName, Arity, MangledCtorName),

	Snd = lambda([Pair::in, Second::out] is det, Pair = _ - Second),
	list__map(Snd, Args, ArgTypes),
	rl__gather_types(ModuleInfo, Parents, ArgTypes, GatheredTypes0, 
		GatheredTypes1, RecursiveTypes0, RecursiveTypes1, 
		Decls0, Decls1, "", ArgList),
	( Ctors = [] ->
		Sep = ""
	;
		Sep = "|"
	),
	% Note that [] should be output as '[]'().
	string__append_list(
		[CtorDecls0, MangledCtorName, "(", ArgList, ")", Sep],
		CtorDecls1),
	rl__gather_constructors(ModuleInfo, Parents, Ctors,
		GatheredTypes1, GatheredTypes, RecursiveTypes1, RecursiveTypes,
		Decls1, Decls, CtorDecls1, CtorDecls).

%-----------------------------------------------------------------------------%

rl__mangle_and_quote_type_name(TypeId, Args, MangledTypeName) :-
	rl__mangle_type_name(TypeId, Args, MangledTypeName0),
	rl__maybe_quote_name(MangledTypeName0, MangledTypeName).

rl__mangle_type_name(TypeId, Args, MangledTypeName) :-
	rl__mangle_type_name_2(TypeId, Args, "", MangledTypeName).

:- pred rl__mangle_type_name_2(type_id::in, list(type)::in,
		string::in, string::out) is det.

rl__mangle_type_name_2(TypeId, Args, MangledTypeName0, MangledTypeName) :-
	( 
		TypeId = qualified(Module0, Name) - Arity,
		prog_out__sym_name_to_string(Module0, Module),
		string__append_list([MangledTypeName0, Module, "__", Name], 
			MangledTypeName1)
	;
		TypeId = unqualified(TypeName) - Arity,
		string__append(MangledTypeName0, TypeName, MangledTypeName1)
	),
	string__int_to_string(Arity, ArStr),
	string__append_list([MangledTypeName1, "___", ArStr], 
		MangledTypeName2),
	( Args = [] ->
		MangledTypeName = MangledTypeName2
	;
		list__foldl(rl__mangle_type_arg, Args, 
			MangledTypeName2, MangledTypeName)
	).

:- pred rl__mangle_type_arg((type)::in, string::in, string::out) is det.

rl__mangle_type_arg(Arg, String0, String) :-
	string__append(String0, "___", String1),
	( type_to_type_id(Arg, ArgTypeId, ArgTypeArgs) ->
		rl__mangle_type_name_2(ArgTypeId, ArgTypeArgs, 
			String1, String)
	;
		error("rl__mangle_type_arg: type_to_type_id failed")
	).

rl__mangle_ctor_name(CtorName, _Arity, MangledCtorName) :-
	unqualify_name(CtorName, MangledCtorName).

rl__mangle_and_quote_ctor_name(CtorName, Arity, MangledCtorName) :-
	rl__mangle_ctor_name(CtorName, Arity, MangledCtorName0),
	rl__maybe_quote_name(MangledCtorName0, MangledCtorName).

:- pred rl__maybe_quote_name(string::in, string::out) is det.

rl__maybe_quote_name(Name0, Name) :-
	( string__is_alnum_or_underscore(Name0) ->
		Name = Name0
	;
		string__append_list(["'", Name0, "'"], Name)
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
