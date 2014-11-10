-module(paxos_member_fsm).
-behaviour(gen_fsm).

-export([start_link/1]).
-export([init/1, handle_info/3, handle_event/3, handle_sync_event/4, terminate/3, code_change/4]).
-export([voting/2, awaiting_election/2, ready/2, waiting/2]). %% states

-include("paxos.hrl").

-import(paxos_utils,[log/3, warn/3, err/3, debug/3]).

%% -------------------------------------------
%% External Interface:
%% -------------------------------------------

start_link(GroupId) ->
    gen_fsm:start_link(paxos_member_fsm, #{group_id => GroupId,
                                           current_epoch => 0,
                                           inner_state => undefined}, []).


%% -------------------------------------------
%% gen_fsm Callbacks:
%% -------------------------------------------

init(State = #{group_id := GroupId}) ->
    paxos_utils:seed_rand_gen(GroupId),
    %% register as a member, so the leader can send to us
    %% Gproc notation: {p, l, Name} means {(p)roperty, (l)ocal, Name}
    gproc:reg({p, l, {?MODULE, GroupId}}),
    {ok, voting, State, paxos_utils:rand_election_timeout()}.

handle_sync_event(Event, From, StateName, State = #{group_id := GroupId}) ->
    warn(GroupId,"paxos_member_fsm got unexpected sync event:~p from:~p state:~p data:~p~n",
              [Event,StateName,From,State]),
    {next_state, StateName, State}.

handle_event(Event, StateName, State = #{group_id := GroupId}) ->
    warn(GroupId,"paxos_member_fsm got unexpected event:~p state:~p data:~p~n",
              [Event,StateName,State]),
    {next_state, StateName, State}.

handle_info({simulate_split, NewGroupId}, StateName, State = #{group_id := GroupId}) ->
    NewState = maps:put(group_id,NewGroupId,State),
    gproc:unreg({p, l, {?MODULE, GroupId}}),
    gproc:reg({p, l, {?MODULE, NewGroupId}}),
    {next_state, StateName, NewState, ?HEARTBEAT_PERIOD}; %% timeout for the common case
handle_info(die, _StateName, _State) ->
    exit(normal);
handle_info({global_name_conflict, Name}, StateName, State = #{group_id := GroupId}) ->
    %% presumed to mean that somehow this process thought it was the new
    %% leader, but so did another (shouldn't be possible under non-byzantine
    %% circumstances)
    err(GroupId,"paxos_member_fsm got {global_name_conflict, ~p} (very unexpected!) - in state:~p with data:~p~n",
              [Name, StateName, State]),
    %% ignoring
    {next_state, StateName, State};
%% kludgy passthrough:
handle_info({event, Event}, StateName, State = #{group_id := GroupId}) ->
    debug(GroupId,"paxos_member_fsm (pid:~p) got event:~p while in state:~p with data:~p~n", [self(),Event,StateName,State]),
    ?MODULE:StateName(Event,State);
handle_info(Other, StateName, State = #{group_id := GroupId}) ->
    warn(GroupId,"paxos_member_fsm got unexpected message:~p~n",[Other]),
    {next_state, StateName, State}.

terminate(Reason, StateName, State = #{group_id := GroupId}) ->
    warn(GroupId,"~p:terminate(~p,~p,~p)~n",[?MODULE,Reason,StateName,State]),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.


%% -------------------------------------------
%% gen_fsm State Callbacks:
%% -------------------------------------------

voting(timeout,State) ->
    run_for_election(State);

voting({autonomination, LeaderPID, EpochId} = Event,
       State = #{current_epoch := CurrentEpochId,
                 group_id := GroupId})
  when CurrentEpochId < EpochId ->
    send(LeaderPID,{vote, EpochId, self()}),
    %% wish they'd add the update syntax
    NewState = maps:put(voting_epoch, EpochId, State),
    NewState2 = maps:put(leader_voted_for, LeaderPID, NewState),
    debug(GroupId,"~p:voting(~p,~p) next-state:ready new-state:~p~n",[?MODULE,Event,State,NewState2]),
    {next_state, awaiting_election, NewState2,
     ?AWAITING_ELECTION_TIMEOUT};

voting({autonomination, _LeaderPID, EpochId},
       #{current_epoch := EpochId} = State) ->
    %% Epoch isn't higher than current! just ignore?
    {next_state, voting, State, paxos_utils:rand_election_timeout()};

voting({heartbeat, _LeaderId, _EpochId},State) ->
    %% a kludge, but a better kludge than assuming the leader is valid:
    run_for_election(State);

voting(_Other, State = #{group_id := GroupId}) ->
    debug(GroupId,"~p:voting(~p,~p) (pid:~p) - ignored~n",[?MODULE,self(),_Other,State]),
    %% we may receive late messages meant for other states; ignore
    {next_state, voting, State, paxos_utils:rand_election_timeout()}.


awaiting_election(timeout, State) ->
    NewState = maps:without([voting_epoch,leader_voted_for],State),
    {next_state, voting, NewState, paxos_utils:rand_election_timeout()};

awaiting_election({inauguration, LeaderPID, EpochId},
                  State = #{voting_epoch := EpochId,
                            leader_voted_for := LeaderVotedForPID,
                            group_id := GroupId}) ->
    log(GroupId,"awaiting_election (~p) got inauguration for:~p voting-epoch:~p voted-for:~p~n",
              [self(),LeaderPID,EpochId,LeaderVotedForPID]),
    CleanState = maps:without([voting_epoch,leader_voted_for],State),
    NewState = paxos_utils:maps_put_several([{leader,LeaderPID},
                                             {current_epoch,EpochId}],CleanState),
    {next_state,ready,NewState,?HEARTBEAT_TIMEOUT};

awaiting_election({autonomination, CandidatePID, VotingEpochId},
                  State = #{voting_epoch := VotingEpochId,
                            leader_voted_for := LeaderVotedForPID,
                            group_id := GroupId}) ->
    log(GroupId,"(pid:~p) got autonomination while awaiting_election; informing candidate:~p of vote for:~p~n",
              [self(), CandidatePID, LeaderVotedForPID]),
    send(CandidatePID, { vote_already_cast_for, LeaderVotedForPID, VotingEpochId }),
    {next_state,awaiting_election,State,?AWAITING_ELECTION_TIMEOUT};

awaiting_election(_Other,State) ->
    {next_state,awaiting_election,State,?AWAITING_ELECTION_TIMEOUT}.


ready(timeout, State) ->
    %%run_for_election(State);
    {next_state, voting, State, paxos_utils:rand_election_timeout()};

ready({heartbeat, LeaderPID, EpochId},
      State = #{current_epoch := EpochId,
                leader := LeaderPID,
                group_id := GroupId}) ->
    debug(GroupId,"~p:ready (~p) group:~p got heartbeat from leader:~p epoch:~p~n",[?MODULE,self(),GroupId,LeaderPID,EpochId]),
    {next_state, ready, State, ?HEARTBEAT_TIMEOUT};

ready({prepare, LeaderPID, NewEpoch},
      State = #{current_epoch := EpochId,
                leader := LeaderPID,
                inner_state := InnerState,
                group_id := GroupId})
  when NewEpoch > EpochId ->
    log(GroupId,"~p:ready (pid:~p) got prepare leader:~p new-epoch:~p~n",[?MODULE,self(),LeaderPID,NewEpoch]),
    send(LeaderPID, { promise, NewEpoch, InnerState }),
    NewState = maps:put(current_epoch,NewEpoch,State),
    {next_state, waiting, NewState, %%State#{ current_epoch := NewEpoch },
     ?COMMITTING_TIMEOUT};

%% kludge?
ready({autonomination, CandidatePID, VotingEpochId},
      State = #{current_epoch := EpochId,
                leader := LeaderPID,
                group_id := GroupId})
  when VotingEpochId =< EpochId ->
    log(GroupId,"(pid:~p) got autonomination while ready; informing candidate:~p of current leader:~p~n",
              [self(), CandidatePID, LeaderPID]),
    %% should this be a special case of the kludge, or is sending back a potentially old voting epoch ok?
    send(CandidatePID, { vote_already_cast_for, LeaderPID, VotingEpochId }),
    {next_state,ready,State,?HEARTBEAT_TIMEOUT};

ready(_Other, State = #{group_id := GroupId}) ->
    %% we may receive late messages meant for other states; ignore
    debug(GroupId,"~p:ready(~p,~p) pid:~p~n",[?MODULE,_Other,State,self()]),
    {next_state, ready, State, ?HEARTBEAT_TIMEOUT}.


waiting(timeout, State) ->
    {next_state, voting, State, paxos_utils:rand_election_timeout() };
%    run_for_election(State);

waiting({commit, LeaderPID, EpochId, NewInnerState},
        State = #{ current_epoch := EpochId,
                   leader := LeaderPID,
                   group_id := GroupId}) ->
    send(LeaderPID, { accept, EpochId }),
    NewState = maps:put(inner_state,NewInnerState,State),
    log(GroupId,"~p:waiting (pid:~p) got commit leader:~p epoch:~p new-inner-state:~p~n",[?MODULE,self(),LeaderPID,EpochId,NewInnerState]),
    {next_state, ready, NewState, %%State#{ inner_state := NewInnerState },
     ?HEARTBEAT_TIMEOUT};

waiting(_Other, State) ->
    %% we may receive late messages meant for other states; ignore
    {next_state, waiting, State, ?COMMITTING_TIMEOUT}.



%% -------------------------------------------
%% Internal Helpers
%% -------------------------------------------

run_for_election(#{ current_epoch := EpochId,
                    inner_state := InnerState,
                    group_id := GroupId }) ->
    CleanState = #{ group_id => GroupId,
                    current_epoch => EpochId,
                    inner_state => InnerState },
    log(GroupId,"~p:run_for_election (pid:~p)~n",[?MODULE,self()]),
    gproc:unreg({p, l, {?MODULE, GroupId}}),
    process_flag(trap_exit,true),%% leader needs exception handling
    %% TODO: verify that the stack isn't growing (see paxos_leader_fsm:campaigning/2)
    gen_fsm:enter_loop(paxos_leader_fsm, [], run_for_election, CleanState,
                       ?RUN_FOR_ELECTION_TIMEOUT).

send(Pid,Msg) ->
    paxos_utils:fuzzable_send(Pid,Msg,fun gen_fsm:send_event/2).
