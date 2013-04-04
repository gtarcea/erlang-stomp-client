-module(stompt).
-export([doit/0]).

doit() ->
    Fun1 = fun([{type, "MESSAGE"}, {header, Header}, {body, Body}]) ->
            io:format("Fun1 Got message: ~p~n", [Body]),
            io:format("Fun1 Got Header: ~p~n", [Header]),
            stomp_client2:send_topic("test2", "Fun1 sending message on /topic/test2", [], self());
        ([{type, _Type}, {header, _Header}, {body, _Body}]) ->
            ok
    end,
    Fun2 = fun([{type, "MESSAGE"}, {header, Header}, {body, Body}]) ->
            io:format("Fun2 Got message: ~p~n", [Body]),
            io:format("Fun2 Got Header: ~p~n", [Header]);
        ([{type, _Type}, {header, _Header}, {body, _Body}]) ->
            ok
    end,
    {ok, Pid} = stomp_client2:start("localhost", 61613, "guest", "guest"),
    stomp_client2:subscribe_topic("test", [], Fun1, Pid),
    stomp_client2:subscribe_topic("test2", [], Fun2, Pid).
