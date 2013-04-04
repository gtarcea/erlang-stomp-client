-module(stompt).
-export([doit/0]).

doit() ->
    Fun = fun([{type, "MESSAGE"}, {header, Header}, {body, Body}]) ->
            io:format("Got message: ~p~n", [Body]),
            io:format("Got Header: ~p~n", [Header]);
        ([{type, _Type}, {header, _Header}, {body, _Body}]) ->
            ok
    end,
    {ok, Pid} = stomp_client2:start("localhost", 61613, "guest", "guest"),
    stomp_client2:subscribe_topic("test", [], Fun, Pid).
