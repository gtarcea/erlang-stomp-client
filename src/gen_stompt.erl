-module(gen_stompt).
-behavior(gen_stomp).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2,
        terminate/2, code_change/3]).

-record(state, { stuff }).

start_link() ->
    gen_stomp:start_link(?MODULE, "localhost", 61613, "guest", "guest", [{"/topic/test", []}], []).

init([]) ->
    {ok, #state{stuff = true}}.

handle_call({stomp, Message}, _From, State) ->
    io:format("Received message: ~p~n", [Message]),
    {reply, {ok, "Hello"}, State}.

handle_cast(stop, State) ->
    {stop, normal, State}.

handle_info(_Ignore, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
