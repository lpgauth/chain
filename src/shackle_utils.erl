-module(shackle_utils).
-include("shackle_internal.hrl").

%% public
-export([
    cancel_timer/1,
    info_msg/3,
    lookup/3,
    now_diff/1,
    random/1,
    random_element/1,
    send/2,
    timeout/2,
    timing/2,
    warning_msg/3
]).

%% public
-spec cancel_timer(erlang:timer_ref() | undefined) -> ok.

cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) ->
    erlang:cancel_timer(TimerRef).

-spec info_msg(pool_name(), string(), [term()]) -> ok.

info_msg(Pool, Format, Data) ->
    error_logger:info_msg("[~p] " ++ Format, [Pool | Data]).

-spec lookup(atom(), [{atom(), term()}], term()) -> term().

lookup(Key, List, Default) ->
    case lists:keyfind(Key, 1, List) of
        false -> Default;
        {_, Value} -> Value
    end.

-spec now_diff(erlang:timestamp()) -> non_neg_integer().

now_diff(Timestamp) ->
    timer:now_diff(os:timestamp(), Timestamp).

-spec random(pos_integer()) -> non_neg_integer().

random(N) ->
    erlang:phash2({self(), os:timestamp()}, N).

-spec random_element([term()]) -> term().

random_element([X]) ->
    X;
random_element([_|_] = List) ->
    T = list_to_tuple(List),
    element(random(tuple_size(T)) + 1, T).

-spec send(undefined | pid(), term()) -> term().

send(undefined, _Msg) ->
    ok;
send(Pid, Msg) ->
    erlang:send(Pid, Msg).

-spec timeout(time(), erlang:timestamp()) -> integer().

timeout(Timeout, Timestamp) ->
    Diff = timer:now_diff(os:timestamp(), Timestamp) div 1000,
    Timeout - Diff.

-spec timing(erlang:timestamp(), [non_neg_integer()]) -> [non_neg_integer()].

timing(undefined, []) ->
    [];
timing(Timestamp, []) ->
    [now_diff(Timestamp)];
timing(Timestamp, [H | _] = Timing) ->
    [(now_diff(Timestamp) - H) | Timing].

-spec warning_msg(pool_name(), string(), [term()]) -> ok.

warning_msg(Pool, Format, Data) ->
    error_logger:warning_msg("[~p] " ++ Format, [Pool | Data]).
