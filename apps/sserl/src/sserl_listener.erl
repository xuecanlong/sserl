%%%-------------------------------------------------------------------
%%% @author paul <paul@hupaul.com>
%%% @copyright (C) 2016, paul
%%% @doc
%%%
%%% @end
%%% Created : 15 May 2016 by paul <paul@hupaul.com>
%%%-------------------------------------------------------------------
-module(sserl_listener).

-behaviour(gen_server).

%% API
-export([start_link/1, get_port/1, get_portinfo/1, update/2, get_states/1]).

-export([flow_limit_allow/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("sserl.hrl").

-define(SERVER, ?MODULE).
-define(MAX_LIMIT, 1024).
-define(MAX_FLOW, 100*1024*1024).

-record(state, {
          lsocket,                  % listen socket
          conns = [],               % current connection list [{Pid, Addr, Port}]
          port_info                 % portinfo()
}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link(Args) -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Args) ->
    %% get configs
    Type      = proplists:get_value(type, Args, server),
    IP        = proplists:get_value(ip, Args),
    Port      = proplists:get_value(port, Args),
    ConnLimit = proplists:get_value(conn_limit,  Args, ?MAX_LIMIT),
    ExpireTime= proplists:get_value(expire_time, Args, max_time()),
    MaxFlow   = proplists:get_value(max_flow, Args, ?MAX_FLOW),
    OTA       = proplists:get_value(ota, Args, false),
    Password  = proplists:get_value(password, Args),
    Method    = parse_method(proplists:get_value(method, Args, rc4_md5)),
    CurrTime  = os:system_time(seconds),
    Server    = proplists:get_value(server, Args),
    %% validate args
    ValidMethod = lists:any(fun(M) -> M =:= Method end, shadowsocks_crypt:methods()),
    if
        Type =/=server andalso Type =/= client ->
            {error, {badargs, invalid_type}};
        Type =:= client andalso Server =:= undefined ->
            {error, {badargs, client_need_server}};
        Port < 0 orelse Port > 65535 ->
            {error, {badargs, port_out_of_range}};
        not is_integer(ConnLimit) ->
            {error, {badargs, conn_limit_need_integer}};
        not ValidMethod ->
            {error, {badargs, unsupported_method}};
        not is_list(Password) ->
            {error, {badargs, password_need_list}};
        CurrTime >= ExpireTime ->
            {error, expired};
        true ->
            %% IP
            PortInfo = #portinfo{port = Port, password = Password, method = Method,
                                 ota = OTA, type = Type, server = Server,
                                 conn_limit = ConnLimit, max_flow = MaxFlow,
                                 expire_time=ExpireTime
                        },
            gen_server:start_link(?MODULE, [PortInfo, IP], [])
    end.

%%-------------------------------------------------------------------
%% @doc get listening port number by Pid
%% 
%% @spec get_port(Pid) -> inet:port_number()
%%
%% @end
%%-------------------------------------------------------------------
get_port(Pid) ->
    gen_server:call(Pid, get_port).

get_portinfo(Pid) ->
    gen_server:call(Pid, get_portinfo).    

%% Return :: {ok, Pid}
update(Pid, Args) ->
    gen_server:call(Pid, {update, Args}),
    {ok, self()}.

%% Return :: [] | [{Pid, Addr, Port}]
get_states(Pid) ->
    gen_server:call(Pid, get_states).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([PortInfo, IP]) ->
    process_flag(trap_exit, true),

    Opts = [binary, {backlog, 20},{nodelay, true}, {active, false}, 
            {packet, raw}, {reuseaddr, true},{send_timeout_close, true}],
    %% get the ip address
    Opts1 = case IP of
        undefined ->
            Opts;
        Addr ->
             Opts++[{ip, Addr}]
    end,
    %% start listen

    case gen_tcp:listen(PortInfo#portinfo.port, Opts1) of
        {ok, LSocket} ->
            %% set to async accept, so we can do many things on this process
            case prim_inet:async_accept(LSocket, -1) of
                {ok, _} ->
                    gen_event:notify(?STAT_EVENT, {listener, {new, PortInfo}}),
                    {ok,#state{lsocket = LSocket,
                               port_info = PortInfo
                        }};
                {error, Error} ->
                    {stop, Error}
            end;
        Error ->
            {stop, Error}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(get_port, _From, State=#state{port_info=PortInfo}) ->
    {reply, PortInfo#portinfo.port, State};

handle_call(get_portinfo, _From, State=#state{port_info=PortInfo}) ->
    {reply, PortInfo, State};

%% update args
handle_call({update, Args}, _From, State) ->
    PortInfo   = State#state.port_info,
    ConnLimit  = proplists:get_value(conn_limit,  Args, PortInfo#portinfo.conn_limit),
    MaxFlow    = proplists:get_value(max_flow, Args, PortInfo#portinfo.max_flow),
    ExpireTime = proplists:get_value(expire_time, Args, PortInfo#portinfo.expire_time),
    Password   = proplists:get_value(password, Args, PortInfo#portinfo.password),
    Method     = parse_method(proplists:get_value(method, Args, PortInfo#portinfo.method)),    

    PortInf2 = PortInfo#portinfo{conn_limit  = ConnLimit,
                                 max_flow    = MaxFlow,
                                 expire_time = ExpireTime,
                                 password    = Password,
                                 method      = Method},
    gen_event:notify(?STAT_EVENT, {listener, {update, PortInf2}}),
    {reply, ok, State#state{port_info = PortInf2}};

handle_call(get_states, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% 超过使用期，停止进程
handle_info({timeout, _Ref, expire}, State) ->
    {stop, expire, State};

handle_info({inet_async, _LSocket, _Ref, {ok, CSocket}}, 
            State=#state{port_info=PortInfo, conns=Conns}) ->
    
    OTA = PortInfo#portinfo.ota,
    Port = PortInfo#portinfo.port,
    Type = PortInfo#portinfo.type,
    Method = PortInfo#portinfo.method,
    Password = PortInfo#portinfo.password,
    Server = PortInfo#portinfo.server,

    true = inet_db:register_socket(CSocket, inet_tcp), 
    {ok, {CAddr, CPort}} = inet:peername(CSocket),
    
    % access controll
    case {conn_limit_allow(PortInfo, Conns, CAddr), flow_limit_allow(PortInfo), expire_time_allow(PortInfo)} of
        {false, _, _} ->
            lager:notice("~p will accept ~p, but beyond conn limit", [Port, CAddr]),
            gen_tcp:close(CSocket),
            case prim_inet:async_accept(State#state.lsocket, -1) of
                {ok, _} ->
                    {noreply, State};
                {error, Ref} ->
                    {stop, {async_accept, inet:format_error(Ref)}, State}
            end;
        {_, false, _} ->
            lager:notice("~p will accept ~p, but beyond flow limit", [Port, CAddr]),
            gen_tcp:close(CSocket),
            case prim_inet:async_accept(State#state.lsocket, -1) of
                {ok, _} ->
                    {noreply, State};
                {error, Ref} ->
                    {stop, {async_accept, inet:format_error(Ref)}, State}
            end;
        {_, _, false} ->
            lager:notice("~p will accept ~p, but has expired", [Port, CAddr]),
            gen_tcp:close(CSocket),
            case prim_inet:async_accept(State#state.lsocket, -1) of
                {ok, _} ->
                    {noreply, State};
                {error, Ref} ->
                    {stop, {async_accept, inet:format_error(Ref)}, State}
            end;
        {true, true, true} ->
            gen_event:notify(?STAT_EVENT, {listener, {accept, Port, {CAddr, CPort}}}),

            {ok, Pid} = sserl_conn:start_link(CSocket, {Port, Server, OTA, Type, {Method, Password}}),

            case gen_tcp:controlling_process(CSocket, Pid) of
                ok ->
                    gen_event:notify(?STAT_EVENT, {conn, {open, Pid}}),
                    Pid ! {shoot, CSocket};
                {error, _} ->
                    exit(Pid, kill),
                    gen_tcp:close(CSocket)
            end,
            NewConns = [{Pid, CAddr, CPort}|Conns],
            case prim_inet:async_accept(State#state.lsocket, -1) of
                {ok, _} ->
                    {noreply, State#state{conns=NewConns}};
                {error, Ref} ->
                    {stop, {async_accept, inet:format_error(Ref)}, State#state{conns=NewConns}}
            end
    end;

handle_info({inet_async, _LSocket, _Ref, Error}, State) ->
    {stop, Error, State};

handle_info({'EXIT', Pid, Reason}, State = #state{conns=Conns}) ->
    gen_event:notify(?STAT_EVENT, {conn, {close, Pid, Reason}}),
    Remained = lists:filter(fun(C) -> 
                case C of
                    {Pid, _Addr, _Port} -> false;
                    _ -> true
                end
            end, Conns),
    {noreply, State#state{conns=Remained}};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    PortInfo = State#state.port_info,
    gen_event:notify(?STAT_EVENT, {listener, {stop, PortInfo#portinfo.port}}),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
max_time() ->
    erlang:convert_time_unit(erlang:system_info(end_time), native, seconds).

%% parse encrty method
parse_method(Method) when is_list(Method); is_binary(Method) ->
    list_to_atom(re:replace(Method, "-", "_", [global, {return, list}]));
parse_method(Method) when is_atom(Method) ->
    Method.

%% @doc calculate conntectd num
%% Return :: bool()
conn_limit_allow(PortInfo, Conns, NewAddr) ->
    % 使用 `IsContain和limit数量限制` 俩种方式, 来判断是否符合连接限制的规范
    % 避免了 当前客户端数=2, limit=1. 时, 这俩个客服端都无法服务的场景

    {ConnectMap, IsContain} = lists:foldl(fun({_, Addr, _}, {Map, IsContain}) -> 
                N = maps:get(Addr, Map, 0),
                NewMap = maps:put(Addr, N+1, Map),
                % 当 IsContain 为true, 则表达式为true; 
                % 当 IsContain 为 false, 表达式值等于 Addr =:= NewAddr
                IsContain2 = IsContain orelse Addr =:= NewAddr,
                {NewMap, IsContain2}
              end, {maps:new(), false}, Conns),
              
    % 当已经在服务中的 Client, 返回 true;
    % 当未在服务中的 Client, 判断连接数;
    IsContain orelse maps:size(ConnectMap) < PortInfo#portinfo.conn_limit.

%% Return :: bool()
flow_limit_allow(PortInfo) ->
    FlowTotal = sserl_traffic:flow_usage(PortInfo#portinfo.port),
    PortInfo#portinfo.max_flow > FlowTotal.

expire_time_allow(PortInfo) ->
    PortInfo#portinfo.expire_time > os:system_time(seconds).
