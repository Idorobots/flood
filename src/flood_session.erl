-module(flood_session).

-export([init/2, run/2, dispatch/3, handle_socketio/2, handle_event/4, handle_timeout/2, add_metadata/2, get_metadata/2]).
-export([sample_session/0]).

-record(user_state, {metadata,
                     counters,
                     timers,
                     timeout_handlers,
                     event_handlers,
                     socketio_handlers}).

-include("socketio.hrl").

%% External functions:
init(InitData, Session) ->
    Name = proplists:get_value(<<"session_name">>, Session),
    Transport = proplists:get_value(<<"transport">>, Session),
    Weight = proplists:get_value(<<"weight">>, Session),
    Metadata = proplists:get_value(<<"metadata">>, Session),
    Actions = proplists:get_value(<<"do">>, Session),
    State = #user_state{metadata = InitData ++ [{<<"session_name">>, Name},
                                                {<<"transport">>, Transport},
                                                {<<"weight">>, Weight}
                                                | Metadata],
                        counters = dict:new(),
                        timers = dict:new(),
                        timeout_handlers = dict:new(),
                        event_handlers = dict:new(),
                        socketio_handlers = dict:new()},
    run(Actions, State).

run(Actions, State) ->
    run_iter(Actions, {noreply, State}).

run_iter([], Acc) ->
    Acc;

run_iter(_Actions, {stop, Reason, State}) ->
    {stop, Reason, State};

run_iter([Action | Actions], {noreply, State}) ->
    Name = proplists:get_value(<<"op">>, Action),
    run_iter(Actions, dispatch(Name, Action, State));

run_iter([Action | Actions], {reply, Replies, State}) ->
    Name = proplists:get_value(<<"op">>, Action),
    run_iter(Actions, combine(dispatch(Name, Action, State), {reply, Replies, State})).

dispatch(<<"start_timer">>, Action, State) ->
    Time = proplists:get_value(<<"time">>, Action),
    Name = proplists:get_value(<<"name">>, Action),
    Timer = gen_fsm:start_timer(Time, Name),
    Timers = dict:store(Name, Timer, State#user_state.timers),
    {noreply, State#user_state{timers = Timers}};

dispatch(<<"stop_timer">>, Action, State) ->
    Name = proplists:get_value(<<"name">>, Action),
    Timer = dict:fetch(Name, State#user_state.timers),
    gen_fsm:cancel_timer(Timer),
    Timers = dict:erase(Name, State#user_state.timers),
    {noreply, State#user_state{timers = Timers}};

dispatch(<<"restart_timer">>, Action, State) ->
    case dispatch(<<"stop_timer">>, Action, State) of
        {noreply, NewState}      -> dispatch(<<"start_timer">>, Action, NewState);
        {stop, Reason, NewState} -> {stop, Reason, NewState}
    end;

dispatch(<<"on_timeout">>, Action, State) ->
    Name = proplists:get_value(<<"name">>, Action),
    Actions = proplists:get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.timeout_handlers),
    {noreply, State#user_state{timeout_handlers = TH}};

dispatch(<<"inc_counter">>, Action, State) ->
    {noreply, State};

dispatch(<<"dec_counter">>, Action, State) ->
    {noreply, State};

dispatch(<<"set_counter">>, Action, State) ->
    {noreply, State};

dispatch(<<"on_event">>, Action, State) ->
    Name = proplists:get_value(<<"name">>, Action),
    Actions = proplists:get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.event_handlers),
    {noreply, State#user_state{event_handlers = TH}};

dispatch(<<"on_socketio">>, Action, State) ->
    Name = proplists:get_value(<<"opcode">>, Action),
    Actions = proplists:get_value(<<"do">>, Action),
    TH = dict:append_list(Name, Actions, State#user_state.socketio_handlers),
    {noreply, State#user_state{socketio_handlers = TH}};

dispatch(<<"emit_event">>, Action, State) ->
    Name = proplists:get_value(<<"name">>, Action),
    Args = proplists:get_value(<<"args">>, Action),
    Event = jsonx:encode({[{name, Name}, {args, Args}]}),
    {reply, [#sio_message{type = event, data = Event}], State};

dispatch(<<"emit_socketio">>, Action, State) ->
    Opcode = proplists:get_value(<<"opcode">>, Action),
    %% FIXME Add ACKs.
    Endpoint = proplists:get_value(<<"endpoint">>, Action, <<"">>),
    Data = proplists:get_value(<<"data">>, Action, <<"">>),
    {reply, [#sio_message{type = sio_type(Opcode), endpoint = Endpoint, data = Data}], State};

dispatch(<<"terminate">>, Action, State) ->
    Reason = proplists:get_value(<<"reason">>, Action),
    {stop, {shutdown, lookup(Reason, State#user_state.metadata)}, State};

dispatch(<<"log">>, Action, State) ->
    Format = proplists:get_value(<<"format">>, Action),
    Params = proplists:get_value(<<"params">>, Action, []),
    lager:notice(Format, lists:map(fun(What) -> lookup(What, State#user_state.metadata) end, Params)),
    {noreply, State};

dispatch(Name, _Action, State) ->
    {stop, {unknown_action, Name}, State}.

get_metadata(Name, State) ->
    proplists:get_value(Name, State#user_state.metadata).

add_metadata(Metadata, State) ->
    State#user_state{metadata = Metadata ++ State#user_state.metadata}.

handle_timeout(Name, State) ->
    with_tmp_metadata([{<<"timer">>, Name}],
                      fun(S) ->
                              handle(Name, S#user_state.timeout_handlers, S)
                      end,
                      State).

handle_event(Event, Name, Args, State) ->
    %% FIXME Name and Args should be strings.
    with_tmp_metadata([{<<"event">>, Event}, {<<"event.name">>, Name}, {<<"event.args">>, Args}],
                      fun(S) ->
                              handle(Name, S#user_state.event_handlers, S)
                      end,
                      State).

handle_socketio(SIOMessages, State) when is_list(SIOMessages) ->
    lists:foldr(fun(_, {stop, Reason, NewState}) ->
                        {stop, Reason, NewState};
                   (Message, Acc = {reply, _, NewState}) ->
                        combine(handle_socketio(Message, NewState), Acc);

                   (Message, Acc = {noreply, NewState}) ->
                        combine(handle_socketio(Message, NewState), Acc)
                end,
                {noreply, State},
                SIOMessages);

handle_socketio(SIOMessage = #sio_message{type = event, endpoint = Endpoint, data = Data}, State) ->
    %% TODO Add acks.
    with_tmp_metadata([{<<"message">>, SIOMessage},
                       {<<"message.opcode">>, sio_opcode(event)},
                       {<<"message.endpoint">>, Endpoint},
                       {<<"message.data">>, Data}],
                      fun(S) ->
                              JSON = jsonx:decode(Data, [{format, proplist}]),
                              Name = proplists:get_value(<<"name">>, JSON),
                              Args = proplists:get_value(<<"args">>, JSON),
                              case handle(sio_opcode(event), S#user_state.socketio_handlers, S) of
                                  {stop, Reason, NewState}    -> {stop, Reason, NewState};
                                  Else = {noreply, NewState}  -> combine(handle_event(Data, Name, Args, NewState), Else);
                                  Else = {reply, _, NewState} -> combine(handle_event(Data, Name, Args, NewState), Else)
                              end
                      end,
                      State);

handle_socketio(SIOMessage = #sio_message{type = Type, endpoint = Endpoint, data = Data}, State) ->
    %% TODO Add acks.
    with_tmp_metadata([{<<"message">>, SIOMessage},
                       {<<"message.opcode">>, sio_opcode(Type)},
                       {<<"message.endpoint">>, Endpoint},
                       {<<"message.data">>, Data}],
                      fun(S) ->
                              handle(sio_opcode(Type), S#user_state.socketio_handlers, S)
                      end,
                      State).

%% Internal functions:
handle(Name, Handlers, State) ->
    case dict:find(Name, Handlers) of
        {ok, Actions} -> run(Actions, State);
        _             -> {noreply, State}
    end.

sample_session() ->
    [{<<"session_name">>,<<"Sample Session">>},
     {<<"transport">>,<<"websocket">>},
     {<<"weight">>,0.2},
     {<<"metadata">>,
      [{<<"foo">>,<<"bar">>},{<<"baz">>,<<"hurr">>}]},
     {<<"do">>,
      [[{<<"op">>, <<"on_event">>},
        {<<"name">>, <<"comet_error">>},
        {<<"do">>, [[{<<"op">>, <<"log">>},
                     {<<"format">>, <<"Received an error: ~p, ~p, ~p, ~p. Aborting">>},
                     {<<"params">>, [<<"$message">>, <<"$event">>, <<"$event.name">>, <<"$event.args">>]}],
                    [{<<"op">>, <<"terminate">>},
                     {<<"reason">>, <<"Error!">>}]]}],
       [{<<"op">>,<<"on_socketio">>},
        {<<"opcode">>, <<"1">>},
        {<<"do">>, [[{<<"op">>,<<"log">>},
                     {<<"format">>, <<"Client ~s connected using session ~s! ">>},
                     {<<"params">>,[<<"$sid">>, <<"$session_name">>]}],
                    [{<<"op">>, <<"emit_event">>},
                     {<<"name">>, <<"ping">>},
                     {<<"args">>, <<"pong">>}]]}]]}].

lookup(<<"$", What/binary>>, Metadata) ->
    proplists:get_value(What, Metadata);

lookup(What, _Metadata) ->
    What.

combine({reply, A, StateA}, {reply, B, _StateB}) ->
    {reply, B ++ A, StateA};

combine({reply, Replies, StateA}, {noreply, _StateB}) ->
    {reply, Replies, StateA};

combine({noreply, StateA}, {reply, Replies, _StateB}) ->
    {reply, Replies, StateA};

combine({noreply, StateA}, _) ->
    {noreply, StateA};

combine({stop, Reason, StateA}, _) ->
    {stop, Reason, StateA}.

sio_type(Opcode) ->
    proplists:get_value(Opcode, lists:zip(?MESSAGE_OPCODES, ?MESSAGE_TYPES), error).

sio_opcode(Type) ->
    proplists:get_value(Type, lists:zip(?MESSAGE_TYPES, ?MESSAGE_OPCODES), <<"7">>).

with_tmp_metadata(Metadata, Fun, State) ->
    OldMetadata = State#user_state.metadata,
    case Fun(add_metadata(Metadata, State)) of
        {stop, Reason, NewState}   -> {stop, Reason, NewState#user_state{metadata = OldMetadata}};
        {reply, Replies, NewState} -> {reply, Replies, NewState#user_state{metadata = OldMetadata}};
        {noreply, NewState}        -> {noreply, NewState#user_state{metadata = OldMetadata}}
    end.
