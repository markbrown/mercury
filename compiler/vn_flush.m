%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

% vn_flush.m - flush the nodes of the vn graph in order.

% Author: zs.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module vn_flush.

:- interface.

:- import_module vn_type, vn_table, vn_temploc.
:- import_module llds, list.

	% Flush the given nodes in the given order.

:- pred vn__flush_nodelist(list(vn_node), ctrlmap, vn_tables, templocs,
	list(instruction), io__state, io__state).
:- mode vn__flush_nodelist(in, in, in, in, out, di, uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module vn_table, vn_util, vn_debug, opt_debug.
:- import_module map, int, string, require, std_util.

vn__flush_nodelist([], _, _, _, []) --> [].
vn__flush_nodelist([Node0 | Nodes0], Ctrlmap, VnTables0, Templocs0, Instrs) -->
	( { Node0 = node_origlval(_) } ->
		{ Nodes1 = Nodes0 },
		{ VnTables1 = VnTables0 },
		{ Templocs1 = Templocs0 },
		{ Instrs0 = [] }
	;
		vn__flush_node(Node0, Ctrlmap, Nodes0, Nodes1,
			VnTables0, VnTables1, Templocs0, Templocs1, Instrs0)
	),
	vn__flush_nodelist(Nodes1, Ctrlmap, VnTables1, Templocs1, Instrs1),
	{ list__append(Instrs0, Instrs1, Instrs) }.

	% Flush the given node.

:- pred vn__flush_node(vn_node, ctrlmap, list(vn_node), list(vn_node),
	vn_tables, vn_tables, templocs, templocs, list(instruction),
	io__state, io__state).
% :- mode vn__flush_node(in, in, di, uo, di, uo, di, uo, out, di, uo) is det.
:- mode vn__flush_node(in, in, in, out, in, out, in, out, out, di, uo) is det.

vn__flush_node(Node, Ctrlmap, Nodes0, Nodes, VnTables0, VnTables,
		Templocs0, Templocs, Instrs) -->
	vn__flush_start_msg(Node),
	(
		{ Node = node_shared(Vn) },
		vn__flush_shared_node(Vn, Nodes0, Nodes, VnTables0, VnTables,
			Templocs0, Templocs, Instrs)
	;
		{ Node = node_lval(Vnlval) },
		vn__flush_lval_node(Vnlval, Ctrlmap, Nodes0, Nodes,
			VnTables0, VnTables, Templocs0, Templocs, Instrs)
	;
		{ Node = node_origlval(Vnlval) },
		{ Nodes = Nodes0 },
		{ VnTables = VnTables0 },
		{ Templocs = Templocs0 },
		{ Instrs = [] }
	;
		{ Node = node_ctrl(N) },
		{ Nodes = Nodes0 },
		{ map__lookup(Ctrlmap, N, VnInstr) },
		{ vn__flush_ctrl_node(VnInstr, N,
			VnTables0, VnTables, Templocs0, Templocs, Instrs) }
	),
	% we should look at all the temporary regs here and call reuse_temploc
	% for the ones that store values that are not live and are not needed
	% any more.
	vn__flush_end_msg(Instrs, VnTables).

%-----------------------------------------------------------------------------%

:- pred vn__flush_lval_node(vnlval, ctrlmap, list(vn_node), list(vn_node),
	vn_tables, vn_tables, templocs, templocs, list(instruction),
	io__state, io__state).
% :- mode vn__flush_lval_node(in, in, di, uo, di, uo, di, uo, out, di, uo)
%	is det.
:- mode vn__flush_lval_node(in, in, in, out, in, out, in, out, out, di, uo)
	is det.

vn__flush_lval_node(Vnlval, Ctrlmap, Nodes0, Nodes,
		VnTables0, VnTables, Templocs0, Templocs, Instrs) -->
	{ vn__lookup_desired_value(Vnlval, DesVn, "vn__flush_lval_node",
		VnTables0) },
	{ vn__lookup_current_value(Vnlval, CurVn, "vn__flush_lval_node",
		VnTables0) },
	(
		% Even if a vnlval already has the right value,
		% we must make sure its access path will not be
		% needed again. This requires its storage in a
		% register or temporary if it is ever used again.

		{ CurVn = DesVn },
		{ vn__vnlval_access_vns(Vnlval, AccessVns) },
		{ AccessVns = [_|_] },
		{ vn__lookup_uses(DesVn, Uses, "vn__flush_lval_node",
			VnTables0) },
		{ vn__real_uses(Uses, RealUses, VnTables0) },
		{ RealUses = [_|_] }
	->
		% This path should be taken only if some circularities
		% are broken arbitrarily. Otherwise, the shared node
		% should come before the user lval nodes.
		vn__flush_node(node_shared(DesVn), Ctrlmap,
			Nodes0, Nodes, VnTables0, VnTables1,
			Templocs0, Templocs1, Instrs1),
		{ vn__ensure_assignment(Vnlval, DesVn, [],
			VnTables1, VnTables,
			Templocs1, Templocs, Instrs2) },
		{ list__append(Instrs1, Instrs2, Instrs) }
	;
		{ vn__ensure_assignment(Vnlval, DesVn, [],
			VnTables0, VnTables,
			Templocs0, Templocs, Instrs) },
		{ Nodes = Nodes0 }
	).

%-----------------------------------------------------------------------------%

:- pred vn__flush_shared_node(vn, list(vn_node), list(vn_node),
	vn_tables, vn_tables, templocs, templocs, list(instruction),
	io__state, io__state).
% :- mode vn__flush_shared_node(in, di, uo, di, uo, di, uo, out, di, uo) is det.
:- mode vn__flush_shared_node(in, in, out, in, out, in, out, out, di, uo)
	is det.

vn__flush_shared_node(Vn, Nodes0, Nodes, VnTables0, VnTables,
		Templocs0, Templocs, Instrs) -->
	( { vn__lookup_uses(Vn, [], "vn__flush_shared_node", VnTables0) } ->
		% earlier nodes must have taken care of this vn
		{ Nodes = Nodes0 },
		{ VnTables = VnTables0 },
		{ Templocs = Templocs0 },
		{ Instrs = [] }
	;
		{ vn__choose_loc_for_shared_vn(Vn, Vnlval, VnTables0,
			Templocs0, Templocs1) },
		( { vn__search_desired_value(Vnlval, Vn, VnTables0) } ->
			vn__flush_also_msg(Vnlval),
			{ list__delete_all(Nodes0, node_lval(Vnlval), Nodes) }
		;
			{ Nodes = Nodes0 }
		),
		{ vn__ensure_assignment(Vnlval, Vn, [],
			VnTables0, VnTables, Templocs1, Templocs, Instrs) }
	).

%-----------------------------------------------------------------------------%

:- pred vn__flush_ctrl_node(vn_instr, int, vn_tables, vn_tables,
	templocs, templocs, list(instruction)).
% :- mode vn__flush_ctrl_node(in, in, di, uo, di, uo, out) is det.
:- mode vn__flush_ctrl_node(in, in, in, out, in, out, out) is det.

vn__flush_ctrl_node(Vn_instr, N, VnTables0, VnTables, Templocs0, Templocs,
		Instrs) :-
	(
		Vn_instr = vn_livevals(Livevals),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = [livevals(Livevals) - ""]
	;
		Vn_instr = vn_call(ProcAddr, RetAddr, LiveInfo, CodeModel),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = [call(ProcAddr, RetAddr, LiveInfo, CodeModel) - ""]
	;
		Vn_instr = vn_call_closure(ClAddr, RetAddr, LiveInfo),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = [call_closure(ClAddr, RetAddr, LiveInfo) - ""]
	;
		Vn_instr = vn_mkframe(Name, Size, Redoip),
		vn__rval_to_vn(const(address_const(Redoip)), AddrVn,
			VnTables0, VnTables1),
		vn__lval_to_vnlval(redoip(lval(maxfr)), SlotVnlval,
			VnTables1, VnTables2),
		vn__set_current_value(SlotVnlval, AddrVn, VnTables2, VnTables),
		Templocs = Templocs0,
		Instrs = [mkframe(Name, Size, Redoip) - ""]
	;
		Vn_instr = vn_label(Label),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = [label(Label) - ""]
	;
		Vn_instr = vn_goto(TargetAddr),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = [goto(TargetAddr) - ""]
	;
		Vn_instr = vn_computed_goto(Vn, Labels),
		vn__flush_vn(Vn, [src_ctrl(N)], [], Rval,
			VnTables0, VnTables, Templocs0, Templocs, FlushInstrs),
		Instr = computed_goto(Rval, Labels) - "",
		list__append(FlushInstrs, [Instr], Instrs)
	;
		Vn_instr = vn_if_val(Vn, TargetAddr),
		vn__flush_vn(Vn, [src_ctrl(N)], [], Rval,
			VnTables0, VnTables, Templocs0, Templocs, FlushInstrs),
		Instr = if_val(Rval, TargetAddr) - "",
		list__append(FlushInstrs, [Instr], Instrs)
	;
		Vn_instr = vn_mark_hp(Vnlval),
		vn__flush_access_path(Vnlval, [src_ctrl(N)], [], Lval,
			VnTables0, VnTables1, Templocs0, Templocs, FlushInstrs),
		vn__lookup_assigned_vn(vn_origlval(vn_hp), OldhpVn,
			"vn__flush_ctrl_node", VnTables1),
		vn__set_current_value(Vnlval, OldhpVn, VnTables1, VnTables),
		Instr = mark_hp(Lval) - "",
		list__append(FlushInstrs, [Instr], Instrs)
	;
		Vn_instr = vn_restore_hp(Vn),
		vn__flush_vn(Vn, [src_ctrl(N)], [], Rval,
			VnTables0, VnTables1, Templocs0, Templocs, FlushInstrs),
		vn__set_current_value(vn_hp, Vn, VnTables1, VnTables),
		Instr = restore_hp(Rval) - "",
		list__append(FlushInstrs, [Instr], Instrs)
	;
		Vn_instr = vn_incr_sp(Incr),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = [incr_sp(Incr) - ""]
	;
		Vn_instr = vn_decr_sp(Decr),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = [decr_sp(Decr) - ""]
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% Choose a location for a shared value number that does not have to go
	% anywhere specific right now; we do have to ensure that the chosen
	% location is accessible without access vns.

	% We prefer to choose a register or stack slot that already has the
	% value; failing that, a register or stack slot that would like to
	% have the value and whose contents either don't have to be saved
	% or can be saved with a single instruction.

	% In either case we have to pay attention when we choose non-register
	% destinations. It pays to choose a non-register holder of the value
	% only if there is at most one other user of the value. It pays to
	% choose a non-register user only if there are no other users of the
	% value.

:- pred vn__choose_loc_for_shared_vn(vn, vnlval, vn_tables, templocs, templocs).
% :- mode vn__choose_loc_for_shared_vn(in, out, in, di, uo) is det.
:- mode vn__choose_loc_for_shared_vn(in, out, in, in, out) is det.

vn__choose_loc_for_shared_vn(Vn, Chosen, VnTables, Templocs0, Templocs) :-
	(
		vn__lookup_current_locs(Vn, CurrentLocs,
			"vn__choose_loc_for_shared_vn", VnTables),
		vn__choose_cheapest_loc(CurrentLocs, BestHolder),
		vn__vnlval_access_vns(BestHolder, []),
		(
			vn__classify_loc_cost(BestHolder, 0)
		;
			vn__lookup_uses(Vn, Uses,
				"vn__choose_loc_for_shared_vn", VnTables),
			list__delete_first(Uses, src_liveval(BestHolder),
				NewUses),
			( NewUses = [] ; NewUses = [_] )
		)
	->
		Chosen = BestHolder,
		Templocs = Templocs0
	;
		vn__find_cheap_users(Vn, Users, VnTables),
		vn__choose_cheapest_loc(Users, BestUser),
		vn__vnlval_access_vns(BestUser, []),
		(
			vn__classify_loc_cost(BestUser, 0)
		;
			vn__lookup_uses(Vn, Uses,
				"vn__choose_loc_for_shared_vn", VnTables),
			list__delete_first(Uses, src_liveval(BestUser), [])
		)
	->
		Chosen = BestUser,
		Templocs = Templocs0
	;
		vn__next_temploc(Templocs0, Templocs, Chosen)
	).

%-----------------------------------------------------------------------------%

	% Find a 'user', location that would like to have the given vn.
	% The user should be 'cheap', i.e. either it should hold no value
	% that will ever be used by anybody else, or the value it holds
	% should be assignable to one of its users without needing any
	% more assignments. At the moment we insist that this user be
	% a register. We could allow stack/frame variables as well,
	% but we must now allow fields, or in general any location
	% that needs access vns.

:- pred vn__find_cheap_users(vn, list(vnlval), vn_tables).
:- mode vn__find_cheap_users(in, out, in) is det.

vn__find_cheap_users(Vn, Vnlvals, VnTables) :-
	( vn__search_uses(Vn, Uses, VnTables) ->
		vn__find_cheap_users_2(Uses, Vnlvals, VnTables)
	;
		Vnlvals = []
	).

:- pred vn__find_cheap_users_2(list(vn_src), list(vnlval), vn_tables).
:- mode vn__find_cheap_users_2(in, out, in) is det.

vn__find_cheap_users_2([], [], _VnTables).
vn__find_cheap_users_2([Src | Srcs], Vnlvals, VnTables) :-
	vn__find_cheap_users_2(Srcs, Vnlvals0, VnTables),
	(
		Src = src_liveval(Live)
		% \+ Live = vn_field(_, _, _)
	->
		( vn__search_current_value(Live, Vn, VnTables) ->
			vn__lookup_uses(Vn, Uses, "vn__find_cheap_users_2",
				VnTables),
			(
				Uses = []
			->
				% Live's current value is not used.
				Vnlvals = [Live | Vnlvals0]
			;
				list__member(UserSrc, Uses),
				(
					UserSrc = src_liveval(User),
					vn__search_current_value(User, UserVn,
						VnTables)
				->
					User = vn_reg(_),
					vn__lookup_uses(UserVn, [],
						"vn__find_cheap_users_2",
						VnTables)
				;
					true
				)
			->
				% Live's current value can be saved to User
				% without any further action.
				Vnlvals = [Live | Vnlvals0]
			;
				Vnlvals = Vnlvals0
			)
		;
			% Live doesn't have a value we know about.
			Vnlvals = [Live | Vnlvals0]
		)
	;
		Vnlvals = Vnlvals0
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pred vn__ensure_assignment(vnlval, vn, list(lval), vn_tables, vn_tables,
	templocs, templocs, list(instruction)).
% :- mode vn__ensure_assignment(in, in, in, di, uo, di, uo, out) is det.
:- mode vn__ensure_assignment(in, in, in, in, out, in, out, out) is det.

vn__ensure_assignment(Vnlval, Vn, Forbidden, VnTables0, VnTables,
		Templocs0, Templocs, Instrs) :-
	(
		vn__search_current_value(Vnlval, Cur_vn, VnTables0),
		Vn = Cur_vn
	->
		vn__del_old_use(Vn, src_liveval(Vnlval),
			VnTables0, VnTables1),
		vn__vnlval_access_vns(Vnlval, SubVns),
		vn__del_old_uses(SubVns, src_access(Vnlval),
			VnTables1, VnTables),
		Templocs = Templocs0,
		Instrs = []
	;
		vn__generate_assignment(Vnlval, Vn, Forbidden,
			VnTables0, VnTables, Templocs0, Templocs, _, Instrs)
	).

:- pred vn__generate_assignment(vnlval, vn, list(lval), vn_tables, vn_tables,
	templocs, templocs, lval, list(instruction)).
% :- mode vn__generate_assignment(in, in, in, di, uo, di, uo, out, out) is det.
:- mode vn__generate_assignment(in, in, in, in, out, in, out, out, out) is det.

vn__generate_assignment(Vnlval, Vn, Forbidden0, VnTables0, VnTables,
		Templocs0, Templocs, Lval, Instrs) :-
	( Vnlval = vn_hp ->
		error("vn_hp should never need to be explicitly flushed")
		% It should be done by the first reference to the old value
		% of the heap pointer, which should generate an incr_hp.
	;
		true
	),
	( vn__search_current_value(Vnlval, OldVn0, VnTables0) ->
		SaveVn = yes(OldVn0)
	;
		SaveVn = no
	),
	% Only lvals on the heap must have their access path flushed,
	% but they cannot appear on the temploc list, so of the next
	% next two calls, at most one will modify Temploc.
	vn__no_temploc(Vnlval, Templocs0, Templocs1),
	vn__flush_access_path(Vnlval, [src_access(Vnlval)], Forbidden0, Lval,
		VnTables0, VnTables1, Templocs1, Templocs2, AccessInstrs),
	vn__flush_vn(Vn, [src_liveval(Vnlval)], Forbidden0, Rval,
		VnTables1, VnTables2, Templocs2, Templocs3, FlushInstrs0),
	% The 'current' value of Vnlval may be changed by flush_vn if it
	% involves a reference to the old value of hp.
	(
		SaveVn = yes(OldVn),
		vn__find_lvals_in_rval(Rval, Forbidden1),
		list__append(Forbidden0, Forbidden1, Forbidden),
		vn__maybe_save_prev_value(Vnlval, OldVn, Vn, Forbidden,
			VnTables2, VnTables3, Templocs3, Templocs, SaveInstrs)
	;
		SaveVn = no,
		VnTables3 = VnTables2,
		Templocs = Templocs3,
		SaveInstrs = []
	),
	( vn__search_current_value(Vnlval, Vn, VnTables3) ->
		% Flush_vn must perform the entire assignment if it involves
		% exactly the actions of an incr_hp operation. Since the
		% incr_hp in FlushInstrs overwrites Lval, we must perform it
		% after Lval's old value has been saved.
		vn__get_incr_hp(FlushInstrs0, Instr, FlushInstrs1),
		VnTables = VnTables3
	;
		vn__set_current_value(Vnlval, Vn, VnTables3, VnTables),
		Instr = assign(Lval, Rval) - "vn flush",
		FlushInstrs1 = FlushInstrs0
	),
	list__condense([AccessInstrs, FlushInstrs1, SaveInstrs, [Instr]],
		Instrs).

	% Remove the incr_hp instruction from the list and return it
	% separately.

:- pred vn__get_incr_hp(list(instruction), instruction, list(instruction)).
% :- mode vn__get_incr_hp(di, out, uo) is det.
:- mode vn__get_incr_hp(in, out, out) is det.

vn__get_incr_hp([], _, _) :-
	error("could not find incr_hp").
vn__get_incr_hp([Instr0 | Instrs0], IncrHp, Instrs) :-
	( Instr0 = incr_hp(_, _, _) - _ ->
		IncrHp = Instr0,
		Instrs = Instrs0
	;
		vn__get_incr_hp(Instrs0, IncrHp, Instrs1),
		Instrs = [Instr0 | Instrs1]
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pred vn__flush_vn(vn, list(vn_src), list(lval), rval, vn_tables, vn_tables,
	templocs, templocs, list(instruction)).
% :- mode vn__flush_vn(in, in, in, out, di, uo, di, uo, out) is det.
:- mode vn__flush_vn(in, in, in, out, in, out, in, out, out) is det.

vn__flush_vn(Vn, Srcs, Forbidden, Rval, VnTables0, VnTables,
		Templocs0, Templocs, Instrs) :-
	( Srcs = [SrcPrime | _] ->
		Src = SrcPrime
	;
		error("empty source list in flush_vn")
	),
	vn__is_const_expr(Vn, IsConst, VnTables0),
	(
		IsConst = yes,
		vn__flush_vn_value(Vn, Srcs, Forbidden, Rval,
			VnTables0, VnTables3, Templocs0, Templocs, Instrs)
	;
		IsConst = no,
		vn__lookup_current_locs(Vn, Locs, "vn__flush_vn", VnTables0),
		vn__lookup_uses(Vn, Uses, "vn__flush_vn", VnTables0),
		list__delete_all(Uses, Src, NewUses),
		( vn__choose_cheapest_loc(Locs, Loc) ->
			(
				Loc = vn_hp
			->
				% The first reference to the old value of hp.
				vn__flush_old_hp(Srcs, Forbidden, Rval,
					VnTables0, VnTables3,
					Templocs0, Templocs, Instrs)
			;
				NewUses = [_,_|_],
				\+ ( Loc = vn_reg(_) ; Loc = vn_temp(_) ),
				\+ Src = src_liveval(_)
			->
				vn__next_temploc(Templocs0, Templocs1, Vnlval),
				vn__generate_assignment(Vnlval, Vn, Forbidden,
					VnTables0, VnTables3,
					Templocs1, Templocs, Lval, Instrs),
				Rval = lval(Lval)
			;
				vn__flush_access_path(Loc, [src_vn(Vn) | Srcs],
					Forbidden, Lval, VnTables0, VnTables3,
					Templocs0, Templocs, Instrs),
				Rval = lval(Lval)
			)
		;
			% If there are no more uses, it is useless to assign
			% the vn to a location. Otherwise it is useful, but if
			% Src is a livevals, the assignment will be done by
			% the caller.
			(
				NewUses = [_|_],
				\+ Src = src_liveval(_)
			->
				vn__choose_loc_for_shared_vn(Vn, Vnlval,
					VnTables0, Templocs0, Templocs1),
				vn__generate_assignment(Vnlval, Vn, Forbidden,
					VnTables0, VnTables3,
					Templocs1, Templocs, Lval, Instrs),
				Rval = lval(Lval)
			;
				vn__flush_vn_value(Vn, Srcs, Forbidden, Rval,
					VnTables0, VnTables3,
					Templocs0, Templocs, Instrs)
			)
		)
	),
	vn__del_old_use(Vn, Src, VnTables3, VnTables).

%-----------------------------------------------------------------------------%

:- pred vn__flush_vn_value(vn, list(vn_src), list(lval), rval,
	vn_tables, vn_tables, templocs, templocs, list(instruction)).
% :- mode vn__flush_vn_value(in, in, in, out, di, uo, di, uo, out) is det.
:- mode vn__flush_vn_value(in, in, in, out, in, out, in, out, out) is det.

vn__flush_vn_value(Vn, Srcs, Forbidden, Rval, VnTables0, VnTables,
		Templocs0, Templocs, Instrs) :-
	vn__lookup_defn(Vn, Vnrval, "vn__flush_vn_value", VnTables0),
	(
		Vnrval = vn_origlval(Vnlval),
		( Vnlval = vn_hp ->
			error("vn_hp found in flush_vn_value")
			% It should have been caught in flush_vn
		;
			true
		),
		vn__lookup_current_locs(Vn, Locs0, "vn__flush_vn_value",
			VnTables0),
		(
			% For code understandability, and for aesthetics,
			% we prefer to take the value from its original home,
			% but only if by doing so we incur no cost penalty.
			vn__lookup_current_value(Vnlval, CurVn, "vn__flush_vn_value", VnTables0),
			Vn = CurVn
		->
			Locs1 = [Vnlval | Locs0]
		;
			Locs1 = Locs0
		),
		( vn__choose_cheapest_loc(Locs1, LocPrime) ->
			Loc = LocPrime
		;
			opt_debug__dump_vnlval(Vnlval, V_str),
			string__append("cannot find copy of an origlval: ",
				V_str, Str),
			error(Str)
		),
		vn__flush_access_path(Loc, [src_vn(Vn) | Srcs], Forbidden, Lval,
			VnTables0, VnTables, Templocs0, Templocs, Instrs),
		Rval = lval(Lval)
	;
		Vnrval = vn_mkword(Tag, SubVn1),
		(
			vn__lookup_defn(SubVn1, SubVnrval, "vn__flush_vn_value",
				VnTables0),
			SubVnrval = vn_origlval(vn_hp)
		->
			vn__flush_vn(SubVn1, [src_vn(Vn) | Srcs], Forbidden,
				Rval1, VnTables0, VnTables,
				Templocs0, Templocs, Instrs),
			vn__lookup_current_locs(Vn, Locs, "vn__flush_vn_value",
				VnTables),
			( Locs = [Loc0 | _] ->
				% see below for an explanation
				vn__flush_access_path(Loc0, [], Forbidden, Lval,
					VnTables, _, Templocs0, _, _),
				Rval = lval(Lval)
			;
				Rval = mkword(Tag, Rval1)
			)
		;
			vn__flush_vn(SubVn1, [src_vn(Vn) | Srcs], Forbidden,
				Rval1, VnTables0, VnTables,
				Templocs0, Templocs, Instrs),
			Rval = mkword(Tag, Rval1)
		)
	;
		Vnrval = vn_const(Const),
		Rval = const(Const),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = []
	;
		Vnrval = vn_create(Tag, MaybeRvals, Label),
		Rval = create(Tag, MaybeRvals, Label),
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = []
	;
		Vnrval = vn_unop(Unop, SubVn1),
		vn__flush_vn(SubVn1, [src_vn(Vn) | Srcs], Forbidden, Rval1,
			VnTables0, VnTables, Templocs0, Templocs, Instrs),
		Rval = unop(Unop, Rval1)
	;
		Vnrval = vn_binop(Binop, SubVn1, SubVn2),
		vn__flush_vn(SubVn1, [src_vn(Vn) | Srcs], Forbidden, Rval1,
			VnTables0, VnTables1, Templocs0, Templocs1, Instrs1),
		vn__flush_vn(SubVn2, [src_vn(Vn) | Srcs], Forbidden, Rval2,
			VnTables1, VnTables, Templocs1, Templocs, Instrs2),
		Rval = binop(Binop, Rval1, Rval2),
		list__append(Instrs1, Instrs2, Instrs)
	).

%-----------------------------------------------------------------------------%

:- pred vn__flush_old_hp(list(vn_src), list(lval), rval, vn_tables, vn_tables,
	templocs, templocs, list(instruction)).
% :- mode vn__flush_old_hp(in, in, out, di, uo, di, uo, out) is det.
:- mode vn__flush_old_hp(in, in, out, in, out, in, out, out) is det.

vn__flush_old_hp(Srcs0, Forbidden0, ReturnRval, VnTables0, VnTables,
		Templocs0, Templocs, Instrs) :-
	% First take care of the "assignment to hp" part of incr_hp.
	vn__lookup_desired_value(vn_hp, NewhpVn, "vn__flush_old_hp", VnTables0),
	vn__flush_hp_incr(NewhpVn, Srcs0, Forbidden0, MaybeRval,
		VnTables0, VnTables1, Templocs0, Templocs1, IncrInstrs),
	(
		MaybeRval = yes(Rval0),
		( Rval0 = const(int_const(I)) ->
			I1 is I // 4,
			Rval = const(int_const(I1))
		; Rval0 = binop((*), Rval1, const(int_const(4))) ->
			Rval = Rval1
		;
			Rval = binop((/), Rval0, const(int_const(4)))
		)
	;
		MaybeRval = no,
		error("empty expression for hp increment")
	),
	vn__set_current_value(vn_hp, NewhpVn, VnTables1, VnTables2),

	% Find out whether we should tag the old hp, and if so, with what.
	vn__lookup_assigned_vn(vn_origlval(vn_hp), OldhpVn, "vn__flush_old_hp",
		VnTables2),
	( Srcs0 = [Src0Prime | Srcs1Prime] ->
		Src0 = Src0Prime,
		Srcs1 = Srcs1Prime
	;
		error("empty src list in vn__flush_old_hp")
	),
	vn__del_old_use(OldhpVn, Src0, VnTables2, VnTables3),
	vn__lookup_uses(OldhpVn, OldhpUses, "vn__flush_old_hp", VnTables3),
	(
		OldhpUses = [],
		Src0 = src_vn(UserVn),
		vn__lookup_defn(UserVn, UserVnrval, "vn__flush_old_hp",
			VnTables3),
		UserVnrval = vn_mkword(Tag, OldhpVn)
	->
		MaybeTag = yes(Tag),
		AssignedVn = UserVn,

		% Find out where to put the tagged value.
		(
			Srcs1 = [src_liveval(VnlvalPrime) | _]
		->
			Vnlval = VnlvalPrime,
			% This call is purely to convert Vnlval in Lval.
			% Since this flush will already have been done in
			% generate_assign, we give it a bogus Srcs input and
			% ignore all its other outputs.
			vn__flush_access_path(Vnlval, [], Forbidden0, Lval,
				VnTables3, _, Templocs1, _, _),
			Templocs2 = Templocs1
		; 
			vn__find_cheap_users(UserVn, UserLocs, VnTables3),
			vn__choose_cheapest_loc(UserLocs, UserLoc),
			UserLoc = vn_reg(_)
		->
			Vnlval = UserLoc,
			vn__no_access_vnlval_to_lval(Vnlval, MaybeLval),
			(
				MaybeLval = yes(Lval)
			;
				MaybeLval = no,
				error("register needs access path")
			),
			Templocs2 = Templocs1
		;
			vn__next_temploc(Templocs1, Templocs2, Vnlval),
			vn__no_access_vnlval_to_lval(Vnlval, MaybeLval),
			(
				MaybeLval = yes(Lval)
			;
				MaybeLval = no,
				error("temploc needs access path")
			)
		),
		ReturnRval = const(int_const(42))	% should not be used
	;
		MaybeTag = no,
		AssignedVn = OldhpVn,
		vn__next_temploc(Templocs1, Templocs2, Vnlval),
		vn__no_access_vnlval_to_lval(Vnlval, MaybeLval),
		(
			MaybeLval = yes(Lval)
		;
			MaybeLval = no,
			error("temploc needs access path")
		),
		ReturnRval = lval(Lval)
	),

	% Save the old value if necessary.
	( vn__search_current_value(Vnlval, OldVn, VnTables3) ->
		vn__find_lvals_in_rval(Rval, Forbidden1),
		list__append(Forbidden0, Forbidden1, Forbidden),
		vn__maybe_save_prev_value(Vnlval, OldVn, AssignedVn, Forbidden,
			VnTables3, VnTables4, Templocs2, Templocs, SaveInstrs)
	;
		VnTables4 = VnTables2,
		Templocs = Templocs2,
		SaveInstrs = []
	),

	vn__set_current_value(Vnlval, AssignedVn, VnTables4, VnTables),
	Instr = incr_hp(Lval, MaybeTag, Rval) - "",
	list__condense([IncrInstrs, SaveInstrs, [Instr]], Instrs).

%-----------------------------------------------------------------------------%

:- pred vn__flush_hp_incr(vn, list(vn_src), list(lval), maybe(rval),
	vn_tables, vn_tables, templocs, templocs, list(instruction)).
% :- mode vn__flush_hp_incr(in, in, in, out, di, uo, di, uo, out) is det.
:- mode vn__flush_hp_incr(in, in, in, out, in, out, in, out, out) is det.

vn__flush_hp_incr(Vn, Srcs, Forbidden, MaybeRval, VnTables0, VnTables,
		Templocs0, Templocs, Instrs) :-
	(
		vn__rec_find_ref_vns(Vn, SubVns, VnTables0),
		vn__free_of_old_hp(SubVns, VnTables0)
	->
		vn__flush_vn(Vn, Srcs, Forbidden, Rval, VnTables0, VnTables,
			Templocs0, Templocs, Instrs),
		MaybeRval = yes(Rval)
	;
		vn__lookup_defn(Vn, Vnrval, "vn__flush_hp_incr", VnTables0),
		(
			Vnrval = vn_origlval(Vnlval),
			( Vnlval = vn_hp ->
				MaybeRval = no
			;
				error("non-hp origlval in flush_hp_incr")
			),
			VnTables2 = VnTables0,
			Templocs = Templocs0,
			Instrs = []
		;
			Vnrval = vn_mkword(_, _),
			error("mkword in calculation of new hp")
		;
			Vnrval = vn_const(Const),
			( Const = int_const(_) ->
				MaybeRval = yes(const(Const))
			;
				error("non-int const in flush_hp_incr")
			),
			VnTables2 = VnTables0,
			Templocs = Templocs0,
			Instrs = []
		;
			Vnrval = vn_create(_, _, _),
			error("create in calculation of new hp")
		;
			Vnrval = vn_unop(_, _),
			error("unop in calculation of new hp")
		;
			Vnrval = vn_binop(Op, SubVn1, SubVn2),
			vn__flush_hp_incr(SubVn1, [src_vn(Vn) | Srcs],
				Forbidden, MaybeRval1, VnTables0, VnTables1,
				Templocs0, Templocs1, Instrs1),
			vn__flush_hp_incr(SubVn2, [src_vn(Vn) | Srcs],
				Forbidden, MaybeRval2, VnTables1, VnTables2,
				Templocs1, Templocs, Instrs2),
			list__append(Instrs1, Instrs2, Instrs),
			(
				MaybeRval1 = yes(Rval1),
				MaybeRval2 = yes(Rval2),
				MaybeRval = yes(binop(Op, Rval1, Rval2))
			;
				MaybeRval1 = yes(_Rval1),
				MaybeRval2 = no,
				( Op = (+) ->
					MaybeRval = MaybeRval1
				;
					error("non-+ op on hp")
				)
			;
				MaybeRval1 = no,
				MaybeRval2 = yes(_Rval2),
				( Op = (+) ->
					MaybeRval = MaybeRval2
				;
					error("non-+ op on hp")
				)
			;
				MaybeRval1 = no,
				MaybeRval2 = no,
				error("two 'no's in flush_hp_incr")
			)
		),
		( Srcs = [SrcPrime | _] ->
			Src = SrcPrime
		;
			error("empty source list in flush_vn")
		),
		vn__del_old_use(Vn, Src, VnTables2, VnTables)
	).

%-----------------------------------------------------------------------------%

:- pred vn__free_of_old_hp(list(vn), vn_tables).
:- mode vn__free_of_old_hp(in, in) is semidet.

vn__free_of_old_hp([], _VnTables).
vn__free_of_old_hp([Vn | Vns], VnTables) :-
	vn__lookup_defn(Vn, Vnrval, "vn__free_of_old_hp", VnTables),
	\+ Vnrval = vn_origlval(vn_hp),
	vn__free_of_old_hp(Vns, VnTables).

:- pred vn__rec_find_ref_vns(vn, list(vn), vn_tables).
:- mode vn__rec_find_ref_vns(in, out, in) is det.

vn__rec_find_ref_vns(Vn, [Vn | DeepVns], VnTables) :-
	vn__lookup_defn(Vn, Vnrval, "vn__rec_find_ref_vns", VnTables),
	vn__find_sub_vns(Vnrval, ImmedVns),
	vn__rec_find_ref_vns_list(ImmedVns, DeepVns, VnTables).

:- pred vn__rec_find_ref_vns_list(list(vn), list(vn), vn_tables).
:- mode vn__rec_find_ref_vns_list(in, out, in) is det.

vn__rec_find_ref_vns_list([], [], _VnTables).
vn__rec_find_ref_vns_list([Vn | Vns], SubVns, VnTables) :-
	vn__rec_find_ref_vns(Vn, SubVns0, VnTables),
	vn__rec_find_ref_vns_list(Vns, SubVns1, VnTables),
	list__append(SubVns0, SubVns1, SubVns).

%-----------------------------------------------------------------------------%

:- pred vn__flush_access_path(vnlval, list(vn_src), list(lval), lval,
	vn_tables, vn_tables, templocs, templocs, list(instruction)).
% :- mode vn__flush_access_path(in, in, in, out, di, uo, di, uo, out) is det.
:- mode vn__flush_access_path(in, in, in, out, in, out, in, out, out) is det.

vn__flush_access_path(Vnlval, Srcs, Forbidden, Lval, VnTables0, VnTables,
		Templocs0, Templocs, AccessInstrs) :-
	(
		Vnlval = vn_reg(Reg),
		Lval = reg(Reg),
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_stackvar(Slot),
		Lval = stackvar(Slot),
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_framevar(Slot),
		Lval = framevar(Slot),
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_succip,
		Lval = succip,
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_maxfr,
		Lval = maxfr,
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_curfr,
		Lval = curfr,
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_succfr(Vn1),
		vn__flush_vn(Vn1, [src_access(Vnlval) | Srcs], Forbidden, Rval,
			VnTables0, VnTables,
			Templocs0, Templocs, AccessInstrs),
		Lval = succfr(Rval)
	;
		Vnlval = vn_prevfr(Vn1),
		vn__flush_vn(Vn1, [src_access(Vnlval) | Srcs], Forbidden, Rval,
			VnTables0, VnTables,
			Templocs0, Templocs, AccessInstrs),
		Lval = prevfr(Rval)
	;
		Vnlval = vn_redoip(Vn1),
		vn__flush_vn(Vn1, [src_access(Vnlval) | Srcs], Forbidden, Rval,
			VnTables0, VnTables,
			Templocs0, Templocs, AccessInstrs),
		Lval = redoip(Rval)
	;
		Vnlval = vn_hp,
		Lval = hp,
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_sp,
		Lval = sp,
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	;
		Vnlval = vn_field(Tag, Vn1, Vn2),
		vn__flush_vn(Vn1, [src_access(Vnlval) | Srcs], Forbidden, Rval1,
			VnTables0, VnTables1,
			Templocs0, Templocs1, AccessInstrs1),
		vn__flush_vn(Vn2, [src_access(Vnlval) | Srcs], Forbidden, Rval2,
			VnTables1, VnTables,
			Templocs1, Templocs, AccessInstrs2),
		Lval = field(Tag, Rval1, Rval2),
		list__append(AccessInstrs1, AccessInstrs2, AccessInstrs)
	;
		Vnlval = vn_temp(Num),
		Lval = temp(Num),
		VnTables = VnTables0,
		Templocs = Templocs0,
		AccessInstrs = []
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% If the vn currently stored in the vnlval is used elsewhere,
	% and if it cannot be recreated blind (or at least not cheaply),
	% then save the value somewhere else. We prefer the somewhere else
	% to be a location where we have to store the value anyway.
	% However, we must not choose a location that is used in the expression
	% being assigned to the vnlval.

	% If we are overwriting a temporary location, it may not have
	% a current value entry in the vn tables.

	% We cannot look up the old contents of the Vnlval here, because
	% it may have been already overwritten in flush_old_hp.

:- pred vn__maybe_save_prev_value(vnlval, vn, vn, list(lval),
	vn_tables, vn_tables, templocs, templocs, list(instruction)).
% :- mode vn__maybe_save_prev_value(in, in, in, in, di, uo, di, uo, out) is det.
:- mode vn__maybe_save_prev_value(in, in, in, in, in, out, in, out, out) is det.

vn__maybe_save_prev_value(Vnlval, OldVn, NewVn, Forbidden,
		VnTables0, VnTables, Templocs0, Templocs, Instrs) :-
	(
		vn__set_current_value(Vnlval, NewVn, VnTables0, VnTablesProbe),
		vn__search_uses(OldVn, Uses, VnTablesProbe),
		vn__real_uses(Uses, RealUses, VnTablesProbe),
		\+ RealUses = [],
		vn__is_const_expr(OldVn, no, VnTables0),
		vn__lookup_current_locs(OldVn, Locs0,
			"vn__maybe_save_prev_value", VnTables0),
		list__delete_all(Locs0, Vnlval, Locs),
		vn__no_good_copies(Locs)
	->
		(
			vn__find_cheap_users(OldVn, ReqLocs, VnTables0),
			vn__choose_cheapest_loc(ReqLocs, Presumed)
		->
			vn__no_access_vnlval_to_lval(Presumed, MaybePresumed),
			(
				MaybePresumed = yes(PresumedLval),
				( list__member(PresumedLval, Forbidden) ->
					vn__next_temploc(Templocs0, Templocs1,
						Chosen)
				; RealUses = [_,_|_], \+ Presumed = vn_reg(_) ->
					vn__next_temploc(Templocs0, Templocs1,
						Chosen)
				;
					Chosen = Presumed,
					Templocs1 = Templocs0
				)
			;
				MaybePresumed = no,
				% we cannot use Presumed even if it is not
				% in Forbidden
				vn__next_temploc(Templocs0, Templocs1,
					Chosen)
			)
		;
			vn__next_temploc(Templocs0, Templocs1, Chosen)
		),
		vn__ensure_assignment(Chosen, OldVn, Forbidden,
			VnTables0, VnTables, Templocs1, Templocs, Instrs1),
		opt_debug__dump_uses_list(RealUses, Debug),
		Instrs = [comment(Debug) - "" | Instrs1]
	;
		VnTables = VnTables0,
		Templocs = Templocs0,
		Instrs = []
	).

:- pred vn__no_good_copies(list(vnlval)).
:- mode vn__no_good_copies(in) is semidet.

vn__no_good_copies([]).
vn__no_good_copies([Vnlval | Vnlvals]) :-
	Vnlval = vn_field(_, _, _),
	vn__no_good_copies(Vnlvals).
