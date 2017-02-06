%% records
-record(cast, {
    client         :: client(),
    pid            :: undefined | pid(),
    request        :: term(),
    request_id     :: request_id(),
    timestamp      :: erlang:timestamp()
}).

-record(pool_options, {
    backlog_size  :: backlog_size(),
    client        :: client(),
    pool_size     :: pool_size(),
    pool_strategy :: pool_strategy()
}).

-record(reconnect_state, {
    current :: undefined | time(),
    max     :: time() | infinity,
    min     :: none | time()
}).

%% types
-type backlog_size() :: pos_integer() | infinity.
-type cast() :: #cast {}.
-type client() :: module().
-type client_option() :: {ip, inet:ip_address() | inet:hostname()} |
                         {port, inet:port_number()} |
                         {protocol, protocol()} |
                         {reconnect, boolean() | on_request} |
                         {reconnect_time_max, time()} |
                         {reconnect_time_min, time()} |
                         {socket_options, [gen_tcp:connect_option() | gen_udp:option()]}.

-type client_options() :: [client_option()].
-type external_request_id() :: term().
-type pool_name() :: atom().
-type pool_option() :: {backlog_size, backlog_size()} |
                       {pool_size, pool_size()} |
                       {pool_strategy, pool_strategy()}.

-type pool_options() :: [pool_option()].
-type pool_options_rec() :: #pool_options {}.
-type pool_size() :: pos_integer().
-type pool_strategy() :: random | round_robin.
-type protocol() :: shackle_tcp | shackle_udp.
-type reconnect_state() :: #reconnect_state {}.
-type request_id() :: {server_name(), reference()}.
-type response() :: {external_request_id(), term()}.
-type server_name() :: atom().
-type time() :: pos_integer().

-export_type([
    client_options/0,
    pool_options/0
]).
