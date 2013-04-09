-module(stompm).

-export([connect/2, subscribe/2, unsubscribe/1, disconnect/0, ack/1, send/3, handle_data/2]).

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

-spec connect(string(), string()) -> {ok, string()}.
connect(Username, Password) ->
    ClientId = "erlang_stomp_"++binary_to_list(ossp_uuid:make(v4, text)),
    Message=lists:append(["CONNECT", "\nlogin: ", Username, "\npasscode: ", Password, "\nclient-id:",ClientId, "\n\n", [0]]),
    {ok, Message}.

-spec subscribe(string(), [{string(), string()}] | []) -> {ok, string()}.
subscribe(Queue, Options) ->
    Message = lists:append(["SUBSCRIBE", "\ndestination: ", Queue, format_options(Options) ,"\n\n", [0]]),
    {ok, Message}.

-spec unsubscribe(string()) -> {ok, string()}.
unsubscribe(Queue) ->
    Message=lists:append(["UNSUBSCRIBE", "\ndestination: ", Queue, "\n\n", [0]]),
    {ok, Message}.

-spec disconnect() -> {ok, string()}.
disconnect() ->
    Message = lists:append(["DISCONNECT","\n\n",[0]]),
    {ok, Message}.

-spec ack(string()) -> ok.
ack(_Message) ->
    ok.

-spec send(string(), string(), [{string(), string()}] | []) -> {ok, string()}.
send(Queue, Message, Options) ->
    Msg = lists:append(["SEND","\ndestination:", Queue, format_options(Options),"\n\n",Message,[0]]),
    {ok, Msg}.

-spec parse(string(), function()) -> ok.
handle_data(Data, Func) ->
    case frame(Data, #framer_state{}) of
        #framer_state{messages = []} ->
            ok;
        NewState ->
            lists:foreach(
                fun(Item) ->
                    Msg = parse(Item, #parser_state{}),
                    Func(Msg)
                end,
                NewState#framer_state.messages),
            ok
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