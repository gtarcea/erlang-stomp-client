%%%-------------------------------------------------------------------
%%% @author nisbus <nisbus@kodiak.is>
%%% @author Omar Yasin <omarkj@kodiak.is>
%%% @copyright (C) 2011, Kodi ehf (http://kodiak.is)
%%% @doc
%%% A stomp client gen_server for Erlang
%%% @end
%%% Created : 13 May 2011 by nisbus
%%%-------------------------------------------------------------------
-module(stomp_client).

%% API
-export([connect/4, subscribe/3, unsubscribe/2, disconnect/1, ack/1, send/4]).

%%%===================================================================
%%% API
%%%===================================================================

connect(Host, Port, Username, Password) ->
    ConnectMessage = stompm:connect(Username, Password),
    {ok,Sock} = gen_tcp:connect(Host,Port,[{active, false}]),
    gen_tcp:send(Sock,ConnectMessage),
    {ok, _Response} = gen_tcp:recv(Sock, 0),
    inet:setopts(Sock,[{active,once}]),
    {ok, Sock}.

subscribe(Socket, Queue, Options) ->
    SubscribeMessage = stompm:subscribe(Queue, Options),
    write_to_socket(Socket, SubscribeMessage).

unsubscribe(Socket, Queue) ->
    UnsubscribeMessage = stompm:unsubscribe(Queue),
    write_to_socket(Socket, UnsubscribeMessage).

disconnect(Socket) ->
    DisconnectMessage = stompm:disconnect(),
    write_to_socket(Socket, DisconnectMessage),
    gen_tcp:close(Socket).

ack(_Socket) ->
    ok.

send(Socket, Queue, Message, Options) ->
    SendMessage = stompm:send(Queue, Message, Options),
    write_to_socket(Socket, SendMessage).

write_to_socket(Socket, Message) ->
    gen_tcp:send(Socket,Message),
    inet:setopts(Socket,[{active,once}]),
    {ok, Socket}.