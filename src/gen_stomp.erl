-module(gen_stomp).

% API
-export([connect/4, disconnect/1, send/3, subscribe/3, unsubscribe/3, ack/2]).

-record(subscription, {queue, on_message}).
-record(connection, {socket, subscriptions}).

connect(host, port, user, password) ->
	ok.

disconnect(#connection{ socket = Socket} = Connection) ->
	ok.

send(#connection{socket = Socket} = Connection, Queue, Value) ->
	ok.

subscribe(#connection{socket = Socket, subscriptions = Subscriptions} = Connection, Queue, Func) ->
	ok.

unsubscribe(#connection{socket = Socket} = Connection, Queue) ->
	ok.

ack(_Ignore1, _Ignore2) ->
	ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_framing(Data, Framer, Func) ->
    case frame(Data,Framer) of
		#framer_state{messages = []} = N ->
	    	N;
		NewState1 ->
	    	lists:foreach(fun(X) ->
	    		Msg = parse(X, #parser_state{}),
			  	Func(Msg)
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
	parse(Rest,State#parser_state{message = Message++[{type,Type}], current = [],
		got_type = true, last_char = 10});
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
    lists:foldl(fun(X,Acc) ->
    	case X of
		    [] ->
				Acc;
			    {Name, Value} ->
				Acc++["\n"++Name++":"++Value];
		    E ->
				throw("Error: invalid options format: "++E)
		end
	end,[],Options).