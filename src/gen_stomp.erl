%%%------------------------------------------------------------------------
%%% Copyright 2013 Regents of University of Michigan
%%%------------------------------------------------------------------------

-module(gen_stomp).
-behaviour(gen_server).

%% New behaviour export
-export([behaviour_info/1]).

%% gen_server callbacks
-export([start_link/7, init/1, handle_call/3,
        handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% API
-export([subscribe/2, unsubscribe/1, send_message/3]).

-record(framer_state,
    {
        current = [],
        messages = []
    }).

-record(parser_state,
    {
        current = [],
        last_char,
        key = [],
        message = [],
        got_type = false,
        header = []
    }).

-record(state,
    {
        framer,
        socket,
        subscriptions = [],
        cb_server_state,
        cb
    }).

%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

%% @hidden
behaviour_info(callbacks) ->
    [
        {init, 1},
        {handle_call, 3},
        {handle_cast, 2},
        {handle_info, 2},
        {terminate, 2},
        {code_change, 3}
    ].

%% @doc starts server listening on the queues
start_link(CallbackModule, Host, Port, Username, Password, Queues, InitParams) ->
    gen_server:start_link(?MODULE, [CallbackModule, Host, Port, Username, Password, Queues, InitParams], []).

init([CallbackModule, Host, Port, Username, Password, Queues, InitParams]) ->
    case CallbackModule:init(InitParams) of
        {ok, CallbackServerState} ->
            {ok, State} = init_stomp(Host, Port, Username, Password, Queues),
            {ok, State#state{cb = CallbackModule, cb_server_state = CallbackServerState}};
        Error ->
            Error
    end.

%% Setups state, initializes the tcp connection and connects to stomp server.
init_stomp(Host, Port, Username, Password, Queues) ->
    ClientId = "erlang_stomp_"++binary_to_list(ossp_uuid:make(v4, text)),
    Message=lists:append(["CONNECT", "\nlogin: ", Username, "\npasscode: ", Password,"\nclient-id:",ClientId, "\n\n", [0]]),
    {ok,Sock}=gen_tcp:connect(Host,Port,[{active, false}]),
    gen_tcp:send(Sock,Message),
    {ok, Response}=gen_tcp:recv(Sock, 0),
    subscribe_to_queues(Sock, Queues),
    State = frame(Response, #framer_state{}),
    inet:setopts(Sock,[{active,once}]),
    {ok, #state{framer = State, socket = Sock}}.

subscribe_to_queues(Sock, Queues) ->
    lists:foreach(
        fun({Queue, Options}) ->
            Message = lists:append(["SUBSCRIBE", "\ndestination: ", Queue, format_options(Options) ,"\n\n", [0]]),
            io:format("subscribe_to_queues: ~s~n", [Message]),
            gen_tcp:send(Sock, Message),
            ok
        end, Queues).

%% @doc subscribes to a queue
-spec subscribe(string(), [tuple(string(), string())] | []) -> ok.
subscribe(Queue, Options) ->
    gen_server:cast(self(), {subscribe, Queue, Options}).

-spec unsubscribe(string()) -> ok.
unsubscribe(Queue) ->
    gen_server:cast(self(), {unsubscribe, Queue}).

-spec send_message(string(), string(), [tuple(string(), string())] | []) -> ok.
send_message(Queue, Message, Options) ->
    gen_server:cast(self(), {send_message, {Queue, Message, Options}}).

%%%------------------------------------------------------------------------
%%% gen_server callbacks - These callbacks then implement the callbacks
%%% for gen_stomp.
%%%------------------------------------------------------------------------

%% @hidden
%% Implements handle_call in gen_server and calls the gen_stomp handle_call callback
handle_call(Request, From, #state{cb = Callback, cb_server_state = CallbackServerState} = State) ->
    Response = Callback:handle_call(Request, From, CallbackServerState),
    callback_response(Response, State).

%% @hidden
%% Implements handle_cast in gen_server and calls the gen_stomp handle_cast callback
handle_cast({subscribe, Queue, Options}, #state{socket = Socket} = State) ->
    Message = lists:append(["SUBSCRIBE", "\ndestination: ", Queue,format_options(Options) ,"\n\n", [0]]),
    gen_tcp:send(Socket,Message),
    inet:setopts(Socket,[{active,once}]),
    {noreply, State#state{subscriptions = [Queue | State#state.subscriptions]}};
handle_cast({unsubscribe, Queue}, #state{socket = Socket} = State) ->
    Message=lists:append(["UNSUBSCRIBE", "\ndestination: ", Queue, "\n\n", [0]]),
    gen_tcp:send(Socket,Message),
    inet:setopts(Socket,[{active,once}]),
    {noreply, State#state{subscriptions = [Queue | State#state.subscriptions]}};
handle_cast({send, {Queue, Message, Options}}, #state{socket = Socket} = State) ->
    Msg = lists:append(["SEND","\ndestination:", Queue, format_options(Options),"\n\n",Message,[0]]),
    gen_tcp:send(Socket,Msg),
    inet:setopts(Socket,[{active,once}]),
    {noreply,State};
handle_cast(Request, #state{cb = Callback, cb_server_state = CallbackServerState} = State) ->
    Response = Callback:handle_cast(Request, CallbackServerState),
    callback_response(Response, State).

%% @hidden
%% Implements handle_info in gen_server and calls the gen_stomp handle_info callback
handle_info({tcp, Sock, RawData}, #state{ cb = Callback, cb_server_state = CallbackServerState,
                                            socket = Socket, framer = Framer } = State) ->
    case (catch Socket = Sock) of
        {_, _} ->
            % Not the stomp socket, pass the message on
            Response = Callback:handle_info( {tcp, Sock, RawData}, CallbackServerState),
            callback_response(Response, State);
        _ ->
            % Socket and Sock matched. This is a message from the Stomp server. Parse it
            % and send it on.
            NewState = case RawData of
                        {error, Error} ->
                            error_logger:error_msg("Cannot connect to STOMP ~p~n", [Error]),
                            Framer;
                        _ ->
                            do_framing(RawData, Framer, State)
            end,
            inet:setopts(Socket, [{active, once}]),
            {noreply, State#state{framer = NewState}}
    end;
handle_info(Info, #state{cb = Callback, cb_server_state = CallbackServerState} = State) ->
    Response = Callback:handle_info(Info, CallbackServerState),
    callback_response(Response, State).

%%% Handle different responses from callback
callback_response({noreply, CallbackServerState}, #state{} = State) ->
    {noreply, State#state{cb_server_state = CallbackServerState}};
callback_response({noreply, CallbackServerState, hibernate}, #state{} = State) ->
    {noreply, State#state{cb_server_state = CallbackServerState}, hibernate};
callback_response({noreply, CallbackServerState, Timeout}, #state{} = State) ->
    {noreply, State#state{cb_server_state = CallbackServerState}, Timeout};
callback_response({reply, Reply, CallbackServerState}, #state{} = State) ->
    {reply, Reply, State#state{cb_server_state = CallbackServerState}};
callback_response({reply, Reply, CallbackServerState, hibernate}, #state{} = State) ->
    {reply, Reply, State#state{cb_server_state = CallbackServerState}, hibernate};
callback_response({reply, Reply, CallbackServerState, Timeout}, #state{} = State) ->
    {reply, Reply, State#state{cb_server_state = CallbackServerState}, Timeout};
callback_response({stop, Reason, CallbackServerState}, #state{} = State) ->
    {reply, Reason, State#state{cb_server_state = CallbackServerState}};
callback_response({stop, Reason, Reply, CallbackServerState}, #state{} = State) ->
    {reply, Reason, Reply, State#state{cb_server_state = CallbackServerState}}.

%% @hidden
%% Implements gen_server:terminate callback and calls into callback for gen_stomp.
terminate(Reason, #state{cb = Callback, cb_server_state = CallbackServerState, socket = Socket} = _State) ->
    Message = lists:append(["DISCONNECT","\n\n",[0]]),
    gen_tcp:send(Socket,Message),
    inet:setopts(Socket,[{active,once}]),
    gen_tcp:close(Socket),
    Callback:terminate(Reason, CallbackServerState),
    ok.

code_change(OldVsn, #state{cb = Callback, cb_server_state = CallbackServerState} = State, Extra) ->
    {ok, NewCallbackState} = Callback:code_change(OldVsn, CallbackServerState, Extra),
    {ok, State#state{cb_server_state = NewCallbackState}}.


%%%------------------------------------------------------------------------
%%% gen_server callback implementations specific to gen_stomp
%%%------------------------------------------------------------------------





%%%------------------------------------------------------------------------
%%% Internal to STOMP message parsing and handling
%%%------------------------------------------------------------------------

do_framing(Data, Framer, State) ->
    case frame(Data,Framer) of
        #framer_state{messages = []} = N ->
            N;
        NewState1 ->
            lists:foreach(
                fun(X) ->
                    Msg = parse(X, #parser_state{}),
                    handle_call({stomp, Msg}, self(), State)
                end,
                NewState1#framer_state.messages),
            #framer_state{current = NewState1#framer_state.current}
    end.

frame([],State) ->
    State;
frame([First|Rest],#framer_state{current = [], messages = []}) ->
    frame(Rest,#framer_state{current = [First]});
frame([0], State) ->
    Message = State#framer_state.current++[0],
    State#framer_state{messages = State#framer_state.messages++[Message], current = []};
frame([0|Rest], State) ->
    Message = State#framer_state.current++[0],
    frame(Rest,State#framer_state{messages = State#framer_state.messages++[Message], current = []});
frame([Match|Rest], #framer_state{current = Current} = State) ->
    frame(Rest,State#framer_state{current = Current++[Match]});
frame([Match|[]], #framer_state{current = Current} = State) ->
    State#framer_state{current = Current++[Match]}.

%First character
parse([First|Rest], #parser_state{last_char = undefined} = State) ->
    parse(Rest, State#parser_state{last_char = First, current = [First]});
%Command
parse([10|[]], #parser_state{last_char = Last, header = Header, message = Message}) when Last =:= 10 ->
    Message++[{header,Header}];
%%Start of Body (end of parse)
parse([10|Rest], #parser_state{last_char = Last, header = Header, message = Message}) when Last =:= 10 ->
    Body = lists:reverse(tl(lists:reverse(Rest))),
    Message++[{header,Header},{body,Body}];
%%Get message type
parse([10|Rest], #parser_state{got_type = false, message = Message, current = Current} = State) ->
    Type = case Current of
           [10|T] ->
           T;
           _ ->
           Current
       end,
    parse(Rest,State#parser_state{message = Message++[{type,Type}], current = [], got_type = true, last_char = 10});
%%Key Value Header
parse([10|Rest], #parser_state{key = Key, current = Value, header = Header} = State) when length(Key) =/= 0 ->
    parse(Rest,State#parser_state{last_char = 10, current =[], header = Header ++ [{Key,Value}], key = [] });
%%%HEADER
parse([10|Rest], #parser_state{got_type = true} = State) ->
    parse(Rest,State#parser_state{last_char = 10});
%%Starting value
parse([$:|Rest], #parser_state{key = [], current = Current} = State) ->
    parse(Rest,State#parser_state{current = [], key = Current, last_char = $:});
%First key char
parse([First|Rest], #parser_state{got_type = true, key = [], current = Current} = State) ->
    parse(Rest,State#parser_state{last_char = First, current = Current ++ [First]});
parse([First|Rest], #parser_state{got_type = true, key = Key, current = Current} = State) when length(Key) =/= 0 ->
    parse(Rest,State#parser_state{last_char = First, current = Current ++[First]});
parse([First|Rest], #parser_state{last_char = Last, current = Current} = State) when Last =/= undefined ->
    parse(Rest, State#parser_state{last_char = First, current = Current++[First]}).

format_options(Options) ->
    lists:foldl(
        fun(X,Acc) ->
            case X of
                [] ->
                Acc;
                {Name, Value} ->
                Acc++["\n"++Name++":"++Value];
                E ->
                throw("Error: invalid options format: "++E)
            end
        end,[],Options).
