-module(paxos_utils).

-include("paxos.hrl").

-compile(export_all).

rand_election_timeout() ->
    random:uniform(?ELECTION_TIMEOUT_BASE + ?ELECTION_TIMEOUT_RANGE).

seed_rand_gen(_SeedForRepeatability) ->
    %% for repeatable results:
    %%random:seed(SeedForRepeatability,SeedForRepeatability,SeedForRepeatability);
    %% reasonably random:
    {A,B,C} = erlang:now(),
    random:seed(A,B,C).

%% stopgap pending all the map syntax
maps_put_several(AList,Map) ->
    lists:foldl(fun({K,V},M) ->
                        maps:put(K,V,M)
                end,Map,AList).


err(GroupId,FStr,FArgs) ->
    log(1,GroupId,FStr,FArgs).

warn(GroupId,FStr,FArgs) ->
    log(2,GroupId,FStr,FArgs).

log(GroupId,FStr,FArgs) ->
    log(3,GroupId,FStr,FArgs).

debug(GroupId,FStr,FArgs) ->
    log(4,GroupId,FStr,FArgs).

log(Priority,_GroupId,_FStr,_FArgs) when Priority > ?LOG_VERBOSITY ->
%%    io:format("d"),
    ok;
log(Priority,GroupId,FStr,FArgs) ->
%%    io:format("log(~p,~p,~p,~p)~n",[Priority,GroupId,FStr,FArgs]),
    gproc:send({p, l, {paxos_log, GroupId}},
               {paxos_log, Priority, GroupId, self(), FStr, FArgs}).

subscribe_to_log(GroupId) ->
    gproc:reg({p, l, {paxos_log, GroupId}}).

log_to_disk(GroupId,FN) ->
    spawn(fun() ->
                  subscribe_to_log(GroupId),
                  {ok,FD} = file:open(FN,[write]),
                  log_to_disk_loop(FD)
          end).

log_to_disk_loop(FD) ->
    receive
        { paxos_log, _Priority, GroupId, Pid, FStr, FArgs} ->
            io:format(FD,"~2..0w|~10.._w|"++FStr,[GroupId,Pid|FArgs]),
            log_to_disk_loop(FD)

    %% after 300000 ->
    %%         io:format(FD,"5 minutes since last message; closing log"),
    %%         file:close(FD)
    end.


fuzzable_send(To,Msg,SendFun) ->
    case {?FUZZ,random:uniform(100)} of
        {true,N} when N < ?PACKET_LOSS_PERCENTAGE ->
            lost;
        _ ->
            SendFun(To,Msg),
            case {?FUZZ,random:uniform(100)} of
                {true,M} when M < ?PACKET_DUP_PERCENTAGE ->
                    fuzzable_send(To,Msg,SendFun);
                _ ->
                    ok
            end
    end.
