%%%-------------------------------------------------------------------------
%%% @author V. Glenn Tarcea <gtarcea@umich.edu>
%%% @copyright 2013 Univerity of Michigan
%%% @doc Something here
%%% @end
%%%-------------------------------------------------------------------------

-module(gen_stomp_server).
-author('gtarcea@umich.edu').

-behaviour(gen_server).

%% API
-export([start_link/2]).

%% Behaviour callbacks
-export([behaviour_info/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(gen_stomp_state, {module, scpid}).