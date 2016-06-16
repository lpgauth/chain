-module(shackle_server).
-include("shackle_internal.hrl").

-compile(inline).
-compile({inline_size, 512}).

%% internal
-export([
    init/5,
    start_link/4
]).

%% sys behavior
-export([
    system_code_change/4,
    system_continue/3,
    system_terminate/4
]).

-type state() :: #{
    client           => client(),
    client_state     => term(),
    header           => iodata(),
    ip               => inet:ip_address() | inet:hostname(),
    name             => server_name(),
    parent           => pid(),
    pool_name        => pool_name(),
    port             => inet:port_number(),
    protocol         => protocol(),
    reconnect_state  => undefined | reconnect_state(),
    socket           => undefined | inet:socket(),
    socket_options   => [gen_tcp:connect_option() | gen_udp:option()],
    timer_ref        => undefined | reference()
}.

%% public
-spec start_link(server_name(), pool_name(), client(), client_options()) ->
    {ok, pid()}.

start_link(Name, PoolName, Client, ClientOptions) ->
    proc_lib:start_link(?MODULE, init, [Name, PoolName, Client,
        ClientOptions, self()]).

-spec init(server_name(), pool_name(), client(), client_options(), pid()) ->
    no_return().

init(Name, PoolName, Client, ClientOptions, Parent) ->
    process_flag(trap_exit, true),
    proc_lib:init_ack(Parent, {ok, self()}),
    register(Name, self()),

    self() ! ?MSG_CONNECT,
    ok = shackle_backlog:new(Name),

    Ip = ?LOOKUP(ip, ClientOptions, ?DEFAULT_IP),
    Port = ?LOOKUP(port, ClientOptions),
    Protocol = ?LOOKUP(protocol, ClientOptions, ?DEFAULT_PROTOCOL),
    ReconnectState = reconnect_state(ClientOptions),
    SocketOptions = ?LOOKUP(socket_options, ClientOptions,
        ?DEFAULT_SOCKET_OPTS),

    {ok, Addrs} = inet:getaddrs(Ip, inet),
    Ip2 = shackle_utils:random_element(Addrs),
    Header = shackle_udp:header(Ip2, Port),

    loop(#{
        client => Client,
        client_state => undefined,
        header => Header,
        ip => Ip2,
        name => Name,
        parent => Parent,
        pool_name => PoolName,
        port => Port,
        protocol => Protocol,
        reconnect_state => ReconnectState,
        socket => undefined,
        socket_options => SocketOptions,
        timer_ref => undefined
    }).

%% sys callbacks
-spec system_code_change(state(), module(), undefined | term(), term()) ->
    {ok, state()}.

system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

-spec system_continue(pid(), [], state()) ->
    ok.

system_continue(_Parent, _Debug, State) ->
    loop(State).

-spec system_terminate(term(), pid(), [], state()) ->
    none().

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).

%% private
close(#{name := Name} = State) ->
    reply_all(Name, {error, socket_closed}),
    reconnect(State).

handle_msg(?MSG_CONNECT, #{
        client := Client,
        ip := Ip,
        pool_name := PoolName,
        port := Port,
        protocol := Protocol,
        reconnect_state := #reconnect_state {
            min = Min
        } = ReconnectState,
        socket_options := SocketOptions
    } = State) ->

    case Protocol:new(Ip, Port, SocketOptions) of
        {ok, Socket} ->
            {ok, ClientState} = Client:init(),
            inet:setopts(Socket, [{active, false}]),

            case Client:setup(Socket, ClientState) of
                {ok, ClientState2} ->
                    inet:setopts(Socket, [{active, true}]),

                    {ok, State#{
                        client_state := ClientState2,
                        reconnect_state := ReconnectState#reconnect_state {
                            current = Min
                        },
                        socket := Socket
                    }};
                {error, Reason, ClientState2} ->
                    shackle_utils:warning_msg(PoolName,
                        "setup error: ~p", [Reason]),

                    reconnect(State#{
                        client_state := ClientState2
                    })
            end;
        {error, Reason} ->
            shackle_utils:warning_msg(PoolName,
                "~p connect error: ~p", [Protocol, Reason]),
            reconnect(State)
    end;
handle_msg(#cast {} = Cast, #{
        socket := undefined,
        name := Name
    } = State) ->

    reply(Name, {error, no_socket}, Cast),
    {ok, State};
handle_msg(#cast {request = Request} = Cast, #{
        client := Client,
        client_state := ClientState,
        header := Header,
        pool_name := PoolName,
        protocol := Protocol,
        socket := Socket
    } = State) ->

    {ok, ExtRequestId, Data, ClientState2} =
        Client:handle_request(Request, ClientState),

    case Protocol:send(Socket, Header, Data) of
        ok ->
            shackle_queue:add(ExtRequestId, Cast),

            {ok, State#{
                client_state := ClientState2
            }};
        {error, Reason} ->
            shackle_utils:warning_msg(PoolName, "tcp send error: ~p", [Reason]),
            Protocol:close(Socket),
            close(State)
    end;
handle_msg({inet_reply, _Socket, ok}, State) ->
    {ok, State};
handle_msg({inet_reply, _Socket, {error, Reason}}, #{
        pool_name := PoolName
    } = State) ->

    shackle_utils:warning_msg(PoolName, "udp send error: ~p", [Reason]),
    {ok, State};
handle_msg({tcp, _Port, Data}, State) ->
    handle_msg_data(Data, State);
handle_msg({tcp_closed, Socket}, #{
        socket := Socket,
        pool_name := PoolName
    } = State) ->

    shackle_utils:warning_msg(PoolName, "tcp connection closed", []),
    close(State);
handle_msg({tcp_error, Socket, Reason}, #{
        socket := Socket,
        pool_name := PoolName
    } = State) ->

    shackle_utils:warning_msg(PoolName, "tcp connection error: ~p", [Reason]),
    shackle_tcp:close(Socket),
    close(State);
handle_msg({udp, _Socket, _Ip, _InPortNo, Data}, State) ->
    handle_msg_data(Data, State).

handle_msg_data(Data, #{
        client := Client,
        client_state := ClientState
    } = State) ->

    {ok, Replies, ClientState2} = Client:handle_data(Data, ClientState),
    ok = process_replies(Replies, State),

    {ok, State#{
        client_state := ClientState2
    }}.

loop(#{parent := Parent} = State) ->
    receive
        {'EXIT', Parent, Reason} ->
            terminate(Reason, State);
        {system, From, Request} ->
            sys:handle_system_msg(Request, From, Parent, ?MODULE, [], State);
        Msg ->
            {ok, State2} = handle_msg(Msg, State),
            loop(State2)
    end.

process_replies([], _State) ->
    ok;
process_replies([{ExtRequestId, Reply} | T], #{name := Name} = State) ->
    case shackle_queue:remove(Name, ExtRequestId) of
        {ok, Cast} ->
            reply(Name, Reply, Cast);
        {error, not_found} ->
            ok
    end,
    process_replies(T, State).

reconnect(#{client_state := undefined} = State) ->
    reconnect_timer(State);
reconnect(#{
        client := Client,
        client_state := ClientState
    } = State) ->

    ok = Client:terminate(ClientState),
    reconnect_timer(State).

reconnect_state(Options) ->
    Reconnect = ?LOOKUP(reconnect, Options, ?DEFAULT_RECONNECT),
    case Reconnect of
        true ->
            Max = ?LOOKUP(reconnect_time_max, Options,
                ?DEFAULT_RECONNECT_MAX),
            Min = ?LOOKUP(reconnect_time_min, Options,
                ?DEFAULT_RECONNECT_MIN),

            #reconnect_state {
                min = Min,
                max = Max
            };
        false ->
            undefined
    end.

reconnect_timer(#{reconnect_state := undefined} = State) ->
    {ok, State#{
        socket := undefined
    }};
reconnect_timer(#{
        reconnect_state := ReconnectState
    } = State) ->

    #reconnect_state {
        current = Current
    } = ReconnectState2 = shackle_backoff:timeout(ReconnectState),
    TimerRef = erlang:send_after(Current, self(), ?MSG_CONNECT),

    {ok, State#{
        reconnect_state := ReconnectState2,
        socket := undefined,
        timer_ref := TimerRef
    }}.

reply(Name, _Reply, #cast {pid = undefined}) ->
    shackle_backlog:decrement(Name);
reply(Name, Reply, #cast {pid = Pid} = Cast) ->
    shackle_backlog:decrement(Name),
    Pid ! Cast#cast {
        reply = Reply
    }.

reply_all(Name, Reply) ->
    Requests = shackle_queue:clear(Name),
    [reply(Name, Reply, Request) || Request <- Requests].

terminate(Reason, #{
        client := Client,
        client_state := ClientState,
        name := Name,
        timer_ref := TimerRef
    }) ->

    shackle_utils:cancel_timer(TimerRef),
    ok = Client:terminate(ClientState),
    reply_all(Name, {error, shutdown}),
    ok = shackle_backlog:delete(Name),
    exit(Reason).
