%%%-------------------------------------------------------------------
%% @doc sserl top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(sserl_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include("sserl.hrl").

-define(SERVER, ?MODULE).


%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    TrafficEvent = {?TRAFFIC_EVENT,
                      {gen_event, start_link, [{local, ?TRAFFIC_EVENT}]},
                       permanent, 5000, worker, dynamic},

    StatEvent = {?STAT_EVENT,
                 {gen_event, start_link, [{local, ?STAT_EVENT}]},
                 permanent, 5000, worker, dynamic},

    Storage = {sserl_storage, {sserl_storage, start_link, []},
            transient, brutal_kill, worker, []},

    ListenerSup = {sserl_listener_sup, {sserl_listener_sup, start_link, []},
                  transient, brutal_kill, supervisor, [sserl_listener_sup]},

    Manager = {sserl_manager, {sserl_manager, start_link, []},
            transient, brutal_kill, worker, [sserl_port_manager]},

    Mutil = {sserl_mutil, {sserl_mutil, start_link, []},
             transient, brutal_kill, worker, []},

    {ok, { {one_for_one, 2, 10}, 
           [TrafficEvent, StatEvent, Storage, ListenerSup, Manager, Mutil]} }.

%%====================================================================
%% Internal functions
%%====================================================================
