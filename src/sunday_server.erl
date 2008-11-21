-module (sunday_server).

-export ([start_link/0]).
-export ([init/1]).

-include ("drink_mnesia.hrl").
-include ("user.hrl").
-include ("qlc.hrl").

-record (sunday_state, {
			socket,
			machine = nil,
			user = nil,
			userref = nil}).

start_link () ->
	spawn_link(?MODULE, init, [self()]).

init (_Parent) ->
	loop(waiting_for_socket, #sunday_state{}).

loop (waiting_for_socket, State) ->
	receive
		{socket, Socket} ->
			inet:setopts(Socket, [{active, once}]),
			{ok, {Address, _Port}} = inet:sockname(Socket),
			Q = qlc:q([ X#machine.machine || X <- mnesia:table(machine), X#machine.public_ip =:= Address ]),
			case mnesia:transaction(fun() -> qlc:eval(Q) end) of
				{atomic, [M]} ->
					Machine = M,
					gen_tcp:send(Socket, "OK Welcome to " ++ atom_to_list(Machine) ++ "\n");
				{atomic, []} ->
					Machine = nil,
					gen_tcp:send(Socket, "OK Welcome to the Erlang Drink Server\n");
				{aborted, _Reason} ->
					Machine = nil,
					gen_tcp:send(Socket, "OK Welcome to the Erlang Drink Server\n")
			end,
			loop(normal, State#sunday_state{socket=Socket,machine=Machine});
		_Else ->
			loop(waiting_for_socket, State)
	end;

loop (normal, State) ->
	#sunday_state{socket=Socket} = State,
	receive
		{tcp, Socket, Data} ->
			[Command | Args] = string:tokens(binary_to_list(Data) -- "\r\n", " "),
			case got_command(string:to_upper(Command), Args, State) of
				{ok, Text, NewState} ->
					send(State, "OK " ++ Text ++ "\n");
				{raw, Text, NewState} ->
					send(State, Text);
				{error, Num, Text, NewState} ->
					send(State, "ERR " ++ integer_to_list(Num) ++ " " ++ Text ++ "\n");
				{exit, Text, NewState} ->
					send(State, "OK " ++ Text ++ "\n"),
					exit(quit)
			end,
			inet:setopts(Socket, [{active, once}]),
			loop(normal, NewState);
		{tcp_closed, Socket} ->
			error_logger:error_msg("TCP Socket Closed"),
			exit(tcp_closed);
		{tcp_error, Socket, Reason} ->
			error_logger:error_msg("TCP Socket Error: ~p", [Reason]),
			exit(Reason);
		_Else ->
			loop(normal, State)
	end.

send(State, Str) ->
	gen_tcp:send(State#sunday_state.socket, Str).

got_command("ACCTMGRCHK", _, State) ->
	{ok, "Server doesn't matter anymore.", State};
got_command("ADDCREDITS", [User, CreditsStr], State) ->
    case string:to_integer(CreditsStr) of
        {error, _Reason} ->
            {error, 402, "Invalid credits."};
        {Credits, _Rest} ->
            case user_auth:admin(State#sunday_state.userref, User) of
                {ok, UserRef} ->
                    case user_auth:add_credits(UserRef, Credits, sunday_server) of
                        ok ->
                            {ok, "Added credits.", State};
                        {error, _Reason} ->
                            {error, 0, "Unknown error.", State}
                    end;
                {error, invalid_ref} ->
                    {error, 204, "You need to login.", State};
                {error, permission_denied} ->
                    {error, 0, "Permission denied.", State};
                {error, invalid_user} ->
                    {error, 410, "Invalid user.", State}
            end
    end;
got_command("ADDCREDITS", _, State) ->
    {error, 406, "Invalid parameters.", State};
got_command("CHPASS", _, State) ->
	{error, 451, "Cannot change user/pass anymore.", State};
got_command("CODE", _, State) ->
	{error, 451, "Not implemented.", State};
got_command("DROP", [SlotStr], State) ->
	case string:to_integer(SlotStr) of
		{error, _Reason} ->
			{error, 409, "Invalid slot.", State};
		{SlotNum, _Rest} ->
			case user_auth:drop(State#sunday_state.userref, State#sunday_state.machine, SlotNum) of
				ok ->
					{ok, "", State};
				{error, invalid_ref} ->
					{error, 204, "You need to login.", State};
				{error, permission_denied} ->
					{error, 0, "Invalid user login.", State};
				{error, slot_empty} ->
					{error, 100, "Slot empty.", State};
				{error, poor} ->
					{error, 203, "User is poor.", State};
				{error, drop_nack} ->
					{error, 101, "Drop failed, contact an admin.", State};
				{error, machine_down} ->
					{error, 0, "Machine is down.", State};
				{error, invalid_machine} ->
					{error, 0, "Machine required.", State};
				{error, _Reason} ->
					{error, 0, "Unknown error.", State}
			end
	end;		
got_command("DROP", [_Slot, _Delay], State) ->
	{error, 451, "Not implemented.", State};
got_command("DROP", _, State) ->
	{error, 406, "Invalid parameters.", State};
got_command("GETBALANCE", [], State) ->
	case State#sunday_state.userref of
		nil ->
			{error, 204, "You need to login.", State};
		UserRef ->
			{ok, UserInfo} = user_auth:user_info(UserRef),
			{ok, "Credits: " ++ integer_to_list(UserInfo#user.credits), State}
	end;
got_command("GETBALANCE", [User], State) ->
	case State#sunday_state.userref of
		nil ->
			{error, 204, "You need to login.", State};
		AdminUserRef ->
			case user_auth:admin(AdminUserRef, User) of
				{ok, UserRef} ->
					{ok, UserInfo} = user_auth:user_info(UserRef),
					user_auth:delete_ref(UserRef),
					{ok, "Credits: " ++ integer_to_list(UserInfo#user.credits), State};
				{error, permission_denied} ->
					{error, 200, "Access denied.", State};
				{error, _Reason} ->
					{error, 200, "Unknown error.", State}
			end
	end;
got_command("GETBALANCE", _, State) ->
	{error, 406, "Invalid parameters.", State};
got_command("IBUTTON", [Ibutton], State) ->
	case State#sunday_state.userref of
		nil ->
			ok;
		OldUserRef ->
			user_auth:delete_ref(OldUserRef)
	end,
	NewState = State#sunday_state{user=nil},
	case user_auth:auth(Ibutton) of
		{ok, UserRef} ->
			{ok, UserInfo} = user_auth:user_info(UserRef),
			NewNewState = NewState#sunday_state{userref = UserRef},
			{ok, "Credits: " ++ integer_to_list(UserInfo#user.credits), NewNewState};
		{error, _Reason} ->
			{error, 200, "Unknown error.", NewState}
	end;
got_command("IBUTTON", _, State) ->
	{error, 406, "Invalid parameters.", State};
got_command("LOCATION", _, State) ->
	{error, 451, "Not implemented.", State}; % If someone wants to implement this...
got_command("MACHINE", [MachineStr], State) ->
	Machine = list_to_atom(MachineStr),
	case drink_machines_sup:is_machine(Machine) of % TODO: convert_drink_alias_to_machineid
		false ->
			{error, 0, "Invalid machine.", State};
		true ->
			case drink_machines_sup:is_machine_alive(Machine) of
				true ->
					{ok, "Welcome to " ++ MachineStr, State#sunday_state{machine = Machine}};
				false ->
					{error, 0, "Machine is down.", State}
			end
	end;
got_command("PASS", [Pass], State) ->
	case State#sunday_state.userref of
		nil ->
			ok;
		OldUserRef ->
			user_auth:delete_ref(OldUserRef)
	end,
	case State#sunday_state.user of
		nil ->
			{error, 201, "USER command needs to be issued first.", State};
		User ->
			NewState = State#sunday_state{user=nil},
			case user_auth:auth(User, Pass) of
				{ok, UserRef} ->
					{ok, UserInfo} = user_auth:user_info(UserRef),
					NewNewState = NewState#sunday_state{userref = UserRef},
					{ok, "Credits: " ++ integer_to_list(UserInfo#user.credits), NewNewState};
				{error, badpass} ->
					{error, 202, "Invalid username or password.", NewState};
				{error, _Reason} ->
					{error, 200, "Unknown error.", NewState}
			end
	end;
got_command("PASS", _, State) ->
	{error, 406, "Invalid parameters.", State};
got_command("QUIT", _, State) ->
	{exit, "Disconnecting.", State};
%got_command("RAND", [_Delay], State) ->
%	{error, 451, "Not implemented.", State};
got_command("RAND", _, State) ->
	{error, 451, "Not implemented.", State}; % Delay 0
got_command("STAT", [Slot], State) ->
	case string:to_integer(Slot) of
		{error, _Reason} ->
			{error, 406, "Invalid parameters.", State};
		{SlotNum, _Rest} ->
			case drink_machine:slot_info(State#sunday_state.machine, SlotNum) of
				{ok, SlotInfo} ->
					{raw, slot_status_reply([SlotInfo]), State};
				{error, machine_down} ->
					{error, 0, "Machine is down.", State};
				{error, invalid_machine} ->
					{error, 0, "Machine required.", State};
				{error, _Reason} ->
					{error, 406, "Invalid parameters.", State}
			end
	end;
got_command("STAT", _, State) ->
	case drink_machine:slots(State#sunday_state.machine) of
		{ok, Slots} ->
			{raw, slot_status_reply(lists:sort(Slots)), State};
		{error, machine_down} ->
			{error, 0, "Machine is down.", State};
		{error, invalid_machine} ->
			{error, 0, "Machine required.", State};
		{error, _Reason} ->
			{error, 0, "Unknown error.", State}
	end;
got_command("TEMP", _, State) ->
	case drink_machine:temperature(State#sunday_state.machine) of
		{ok, Temp} ->
			{ok, io_lib:format("~.4f", [Temp]), State};
		{error, no_temp} ->
			{error, 351, "Unable to determine temperature.", State};
		{error, machine_down} ->
			{error, 0, "Machine is down.", State};
		{error, invalid_machine} ->
			{error, 0, "Machine required.", State};
		{error, _Reason} ->
			{error, 0, "Unknown error.", State}
	end;
got_command("USER", [User], State) ->
	NewState = State#sunday_state{user=User},
	{ok, "Password required.", NewState};
got_command("USER", _, State) ->
	{error, 406, "Invalid parameters.", State};
got_command("VERSION", _, State) ->
	{ok, "ErlangSunday v1", State};
got_command(_, _, State) ->
	{error, 452, "Invalid command.", State}.

slot_status_reply(Slots) ->
	slot_status_detail(Slots) ++ "OK " ++ integer_to_list(length(Slots)) ++ " Slots retrieved\n".

slot_status_detail([]) ->
	[];
slot_status_detail([Slot | Slots]) ->
	io_lib:format("~b \"~s\" ~b ~b 0 true\n", [Slot#slot.num, Slot#slot.name, Slot#slot.price, Slot#slot.avail]) ++ slot_status_detail(Slots).