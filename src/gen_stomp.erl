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

-record(state,
    {
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
    {ok, ConnectMessage} = stompm:connect(Username, Password),
    {ok,Sock}=gen_tcp:connect(Host,Port,[{active, false}]),
    gen_tcp:send(Sock,ConnectMessage),
    {ok, _Response}=gen_tcp:recv(Sock, 0),
    subscribe_to_queues(Sock, Queues),
    inet:setopts(Sock,[{active,once}]),
    {ok, #state{socket = Sock}}.

subscribe_to_queues(Sock, Queues) ->
    lists:foreach(
        fun({Queue, Options}) ->
            {ok, SubscribeMessage} = stompm:subscribe(Queue, Options),
            gen_tcp:send(Sock, SubscribeMessage)
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
    {ok, SubscribeMessage} = stompm:subscribe(Queue, Options),
    gen_tcp:send(Socket,SubscribeMessage),
    inet:setopts(Socket,[{active,once}]),
    {noreply, State#state{subscriptions = [Queue | State#state.subscriptions]}};
handle_cast({unsubscribe, Queue}, #state{socket = Socket} = State) ->
    {ok, UnsubscribeMessage} = stompm:unsubscribe(Queue),
    gen_tcp:send(Socket, UnsubscribeMessage),
    inet:setopts(Socket,[{active,once}]),
    {noreply, State#state{subscriptions = [Queue | State#state.subscriptions]}};
handle_cast({send, {Queue, Message, Options}}, #state{socket = Socket} = State) ->
    {ok, SendMessage} = stompm:send(Queue, Message, Options),
    gen_tcp:send(Socket,SendMessage),
    inet:setopts(Socket,[{active,once}]),
    {noreply,State};
handle_cast(Request, #state{cb = Callback, cb_server_state = CallbackServerState} = State) ->
    Response = Callback:handle_cast(Request, CallbackServerState),
    callback_response(Response, State).

%% @hidden
%% Implements handle_info in gen_server and calls the gen_stomp handle_info callback
handle_info({tcp, Sock, RawData}, #state{ cb = Callback, cb_server_state = CallbackServerState,
                                            socket = Socket} = State) ->
    case (catch Socket = Sock) of
        {_, _} ->
            % Not the stomp socket, pass the message on
            Response = Callback:handle_info( {tcp, Sock, RawData}, CallbackServerState),
            callback_response(Response, State);
        _ ->
            % Socket and Sock matched. This is a message from the Stomp server. Parse it
            % and send it on.
            case RawData of
                {error, Error} ->
                    error_logger:error_msg("Cannot connect to STOMP ~p~n", [Error]);
                _ ->
                    Fun = fun(Msg) ->
                        handle_call({stomp, Msg}, self(), State)
                    end,
                    stompm:handle_data(RawData, Fun)
            end,
            inet:setopts(Socket, [{active, once}]),
            {noreply, State}
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