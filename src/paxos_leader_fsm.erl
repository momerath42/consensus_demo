-module(paxos_leader_fsm).
-behaviour(gen_fsm).

-export([start_link/1]).
-export([init/1, handle_info/3, handle_event/3, handle_sync_event/4, terminate/3, code_change/4]).
-export([set/2, get_fast/1, get_consistent/1]). %% client interface
-export([simulate_split_leader/2, simulate_split_members/3]). %% manager/simulator interface
-export([campaigning/2, serving/2, preparing/2, committing/2, run_for_election/2]). %% states

-include("paxos.hrl").

-import(paxos_utils,[log/3, warn/3, err/3, debug/3]).

-compile(export_all).

%% -------------------------------------------
%% External Interface:
%% -------------------------------------------

start_link(GroupId) ->
    gen_fsm:start_link(paxos_leader_fsm, #{group_id => GroupId, current_epoch => 0}, []).


set(GroupId,NewState) ->
    sync_request(GroupId,{set, NewState}).

get_fast(GroupId) ->
    sync_request(GroupId,get_fast).

get_consistent(GroupId) ->
    sync_request(GroupId,get_consistent).

simulate_split_members(GroupId,NewGroupId,N) ->
    Key = {paxos_member_fsm, GroupId},
    Members = gproc:lookup_pids({p, l, Key}),
    [ MP ! { simulate_split, NewGroupId }
      || MP <- lists:sublist(Members,1,N) ].

simulate_split_leader(GroupId, NewGroupId) ->
    global:send(GroupId, { simulate_split, NewGroupId }).


%% -------------------------------------------
%% gen_fsm Callbacks:
%% -------------------------------------------

%% won't generally be called; members jump straight into this fsm's receive loop
init(State = #{group_id := GroupId}) when GroupId =/= undefined ->
    process_flag(trap_exit,true),
    paxos_utils:seed_rand_gen(GroupId),
    {ok, run_for_election, State, ?RUN_FOR_ELECTION_TIMEOUT}.

handle_sync_event(Event, From, StateName, State = #{group_id := GroupId}) ->
    warn(GroupId,"paxos_leader_fsm got unexpected sync event:~p from:~p state:~p data:~p~n",
              [Event,StateName,From,State]),
    {next_state, StateName, State, 1}.

handle_event(Event, StateName, State = #{group_id := GroupId}) ->
    warn(GroupId,"paxos_leader_fsm got unexpected event:~p state:~p data:~p~n",
              [Event,StateName,State]),
    {next_state, StateName, State, 1}.

handle_info({simulate_split, NewGroupId}, StateName, State) ->
    NewState = maps:put(group_id,NewGroupId,State),
    {next_state, StateName, NewState, ?HEARTBEAT_PERIOD};
handle_info(die, _StateName, _State) ->
    exit(normal);
handle_info({global_name_conflict, Name}, StateName, State = #{group_id := GroupId}) ->
    %% presumed to mean that somehow this process thought it was the new
    %% leader, but so did another (shouldn't be possible under non-byzantine
    %% circumstances)
    err(GroupId,"paxos_leader_fsm_fsm got {global_name_conflict, ~p} (very unexpected!) - in state:~p with data:~p~n",
              [Name, StateName, State]),
    resign(State);
%handle_info({, campaigning, State = #{group_id := GroupId}) ->
handle_info(Other, StateName, State = #{group_id := GroupId}) ->
    debug(GroupId,"paxos_leader_fsm (pid:~p) group:~p state:~p got unexpected message:~p~n",
              [self(),GroupId,StateName,Other]),
    %% Yuck! we don't really know how long we want to time out for
    %% (TODO? look up all timeouts by the state we're moving into/
    %% staying in)
    {next_state, StateName, State, 100}.

terminate(leader_of_a_non_quorum, StateName, State = #{group_id := GroupId}) ->
    log(GroupId,"~p:terminate (pid:~p) caught leader_of_a_non_quorum state:~p - resigning~n",[?MODULE,self(),StateName]),
    resign(State);

terminate(Reason, StateName, State = #{group_id := GroupId}) ->
    warn(GroupId,"~p:terminate(~p,~p,~p)~n",[?MODULE,Reason,StateName,State]),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.


%% -------------------------------------------
%% gen_fsm State Callbacks:
%% -------------------------------------------

run_for_election(timeout,State = #{group_id := GroupId, current_epoch := EpochId}) ->
    log(GroupId,"~p:run_for_election (pid:~p) group:~p epoch:~p sending autonominations for voting-epoch:~p~n",
              [?MODULE,self(),GroupId,EpochId,EpochId+1]),
    send_to_members(GroupId, {autonomination, self(), EpochId + 1}),
    NewState = paxos_utils:maps_put_several([{n_votes,1}, %% vote for self
                                             {n_votes_against,0},
                                             {voting_epoch,EpochId+1}],State),
    {next_state, campaigning, NewState, ?CAMPAIGNING_TIMEOUT};

run_for_election(_Other,State) ->
    {next_state,run_for_election,State,?RUN_FOR_ELECTION_TIMEOUT}.


campaigning(timeout,State) ->
    %% abandon the leader FSM (enter_loop doesn't return; I believe it
    %% blows away the stack too, like hibernate) TODO: verify stack
    %% isn't growing
    resign(State);

campaigning({vote, VotingEpochId, _VoterId},
            State = #{voting_epoch := VotingEpochId,
                      n_votes := NVotes,
                      group_id := GroupId})
  when ((NVotes + 1) >= ?QUORUM_COUNT) ->
    %% register the leader, for the client to find it
    log(GroupId,"~p:campaigning (pid:~p) epoch:~p group:~p got winning vote from:~p n-votes:~p~n",
              [?MODULE,self(),VotingEpochId,GroupId,_VoterId, NVotes+1]),
    global:re_register_name(GroupId,self(),
                            fun global:random_notify_name/3),
    send_to_members(GroupId, { inauguration, self(), VotingEpochId }),
    CleanState = maps:without([voting_epoch, n_votes, n_votes_against],State),
    NewState = maps:put(current_epoch, VotingEpochId, CleanState),
    {next_state, serving, NewState, ?HEARTBEAT_PERIOD};

campaigning({vote, VotingEpochId, _VoterId},
            State = #{voting_epoch := VotingEpochId,
                      n_votes := NVotes,
                      group_id := GroupId}) ->
    log(GroupId,"~p:campaigning (pid:~p) epoch:~p group:~p got vote from:~p~n",
              [?MODULE,self(),VotingEpochId,GroupId,_VoterId]),
    NewState = maps:put(n_votes,NVotes+1,State),
    {next_state, campaigning, NewState,
     %%State#{n_votes := NVotes + 1},
     ?CAMPAIGNING_TIMEOUT};

campaigning({vote_already_cast_for, OtherGuyId, VotingEpochId},
            State = #{voting_epoch := VotingEpochId,
%                      n_votes := NVotes,
                      n_votes_against := NVotesAgainst}) ->
  if ((NVotesAgainst + 1) >= ?QUORUM_COUNT) ->
          %% TODO: OtherGuy being one process is a bad assumption
          NewState = maps:put(current_epoch,VotingEpochId,State),
          resign_to_ready(OtherGuyId,NewState);
     true ->
          NewState = maps:put(n_votes_against,NVotesAgainst+1,State),
          {next_state, campaigning, NewState, ?CAMPAIGNING_TIMEOUT}
  end;

campaigning(_Other, State = #{group_id := GroupId}) ->
    debug(GroupId,"campaigning (pid:~p) got other:~p state:~p~n",[self(),_Other,State]),
    %% ignore messages for other states or epochs
    {next_state, campaigning, State, ?CAMPAIGNING_TIMEOUT}.


serving(timeout, State = #{group_id := GroupId, current_epoch := EpochId}) ->
    log(GroupId,"~p:serving (pid:~p) group:~p epoch:~p sending heartbeat~n",
              [?MODULE,self(),GroupId,EpochId]),
    send_to_members(GroupId, { heartbeat, self(), EpochId }),
    {next_state, serving, State, ?HEARTBEAT_PERIOD};

serving({request, RequesterPID, Ref, get_fast},
        State = #{inner_state := InnerState}) ->
    RequesterPID ! { req_reply, Ref, {ok, InnerState} },
    {next_state, serving, State, ?HEARTBEAT_PERIOD};

serving({request, RequesterPID, Ref, Operation},
        State = #{group_id := GroupId, current_epoch := EpochId}) ->
    NewEpochId = EpochId + 1,
    send_to_members(GroupId, { prepare, self(), NewEpochId }),
    NewState = paxos_utils:maps_put_several([{new_epoch, NewEpochId},
                                             {pending_operation, Operation},
                                             {promises, []},
                                             {promise_count, 0},
                                             {requester, RequesterPID},
                                             {request_ref, Ref}],State),
    {next_state, preparing, NewState, ?PREPARING_TIMEOUT};

serving(_Other, State) ->
    %% unnecessary (> quorum-count) messages from other states will come in; ignore them
    {next_state, serving, State, ?HEARTBEAT_PERIOD}.


preparing(timeout,State = #{requester := RequesterPID,
                            request_ref := Ref}) ->
    RequesterPID ! { req_reply, Ref, {timeout, preparing} },
    resign(State);

%% A more flexible version of this state might accept promises with an
%% epoch =< the new one, allowing determine_new_state to use old values,
%% where they might otherwise be undefined, or just useful to the
%% application

preparing({promise, EpochId, InnerState},
          State = #{ group_id := GroupId,
                     new_epoch := EpochId,
                     promises := Promises,
                     promise_count := NPromises,
                     pending_operation := Operation
                   })
  when (NPromises + 2) >= ?QUORUM_COUNT -> %% the recorded promises, the incoming promise, and self as quorum member
    StateWithLatestPromise = maps:put(promises,[InnerState|Promises],State),
    log(GroupId,"~p:preparing got quorum of promises for group:~p in epoch:~p state:~p~n",
        [?MODULE,GroupId,EpochId,StateWithLatestPromise]),
    NewState = perform_operation(Operation,StateWithLatestPromise),
    {next_state, committing, NewState,
     ?COMMITTING_TIMEOUT};

preparing({promise, EpochId, InnerState},
          State = #{ new_epoch := EpochId,
                     group_id := GroupId,
                     promises := Promises,
                     promise_count := NPromises }) ->
    NewState = paxos_utils:maps_put_several([{promises, [InnerState | Promises ]},
                                             {promise_count, NPromises + 1 }],State),
    log(GroupId,"~p:preparing got promise for group:~p in epoch:~p new-state:~p~n",
        [?MODULE,GroupId,EpochId,NewState]),
    {next_state, preparing, NewState, ?PREPARING_TIMEOUT};

preparing(_Other, State = #{group_id := GroupId}) ->
    %% unnecessary (> quorum-count) messages from other states will come in; ignore them
    log(GroupId,"~p:preparing got extraneous message:~p state:~p~n",[?MODULE,_Other,State]),
    {next_state, preparing, State, ?PREPARING_TIMEOUT}.


committing(timeout, State = #{requester := RequesterPID,
                            request_ref := Ref}) ->
    RequesterPID ! { req_reply, Ref, {timeout, committing} },
    resign(State);

committing({accept, EpochId},
           State = #{ acceptance_count := ACount,
                      current_epoch := CurrentEpochId,
                      new_epoch := EpochId,
                      requester := RequesterPID,
                      request_ref := Ref,
                      pending_operation := Operation,
                      group_id := GroupId})
  when (ACount + 2) >= ?QUORUM_COUNT -> %% recorded + incoming + self
    {OpResult,NewState} = finalize_operation(Operation,State),
    CleanState = maps:without([new_inner_state,new_epoch],NewState),
    RequesterPID ! { req_reply, Ref, OpResult },
    log(GroupId,"~p:committing (pid:~p) got accept with epoch:~p - acount+1 is a quorum:~p (updating epoch from:~p) sent op-result:~p to:~p~n",[?MODULE,self(),EpochId,?QUORUM_COUNT,CurrentEpochId,OpResult,RequesterPID]),
    {next_state, serving, CleanState,
     ?HEARTBEAT_PERIOD};

committing({accept, EpochId},
          State = #{ acceptance_count := ACount,
                     new_epoch := EpochId }) ->
    NewState = maps:put(acceptance_count,ACount+1,State),
    {next_state, committing, NewState,
     ?COMMITTING_TIMEOUT};

committing(_Other, State) ->
    %% unnecessary (> quorum-count) messages from other states will come in; ignore them
    {next_state, committing, State, ?COMMITTING_TIMEOUT}.


%% -------------------------------------------
%% Internal Helpers
%% -------------------------------------------

%% toy implementation (should be optionally provided by the
%% client/some-manager, and promises could/should contain all available
%% member states, including from past epochs (netsplit healed))
determine_new_state(LeadersNewInternalState,_Promises) ->
    LeadersNewInternalState.

sync_request(GroupId,Operation) ->
    Ref = make_ref(),
    gen_fsm:send_event(global:whereis_name(GroupId),
                       {request, self(), Ref, Operation}),
    receive
        { req_reply, Ref, Result } ->
            Result;
        { req_reply, Ref, {timeout,StateName}} ->
            {timeout, StateName}
    after ?SET_TIMEOUT ->
            {timeout, no_reply}
    end.

send_to_members(GroupId, Msg) ->
    Key = {paxos_member_fsm, GroupId},
    %% In terms of simulation, you can think of this as the available
    %% sockets (assuming a tcp connection; for udp, we'd need heartbeat
    %% replies (at least)).  A 'netsplit' results in the members being
    %% registered with a different group, and these 'sockets' being
    %% closed.  gproc and fuzzable_send could rather easily be replaced
    %% with 'real' networking.
    Members = gproc:lookup_pids({p, l, Key}),
    debug(GroupId,"send_to_members(~p,~p) key:~p members:~p~n",[GroupId,Msg,Key,Members]),
    if (length(Members) + 1) >= ?QUORUM_COUNT ->
            To = {p, l, Key},
            EventMsg = {event, Msg},
            paxos_utils:fuzzable_send(To,EventMsg,fun gproc:send/2);
       true ->
            exit(leader_of_a_non_quorum)
    end.

resign(#{ current_epoch := EpochId, inner_state := InnerState, group_id := GroupId }) ->
%%    global:unregister_name(GroupId),
    log(GroupId,"~p:resign (pid:~p) epoch:~p group:~p inner-state:~p~n",[?MODULE,self(),EpochId,GroupId,InnerState]),
    CleanState = #{ current_epoch => EpochId, inner_state => InnerState, group_id => GroupId },
    gproc:reg({p, l, {paxos_member_fsm, GroupId}}),
    process_flag(trap_exit,false),%% member doesn't want to handle exceptions
    gen_fsm:enter_loop(paxos_member_fsm, [], voting, CleanState,
                       paxos_utils:rand_election_timeout()).

resign_to_ready(NewLeaderPID, #{ voting_epoch := EpochId, inner_state := InnerState, group_id := GroupId }) ->
%%    global:unregister_name(GroupId),
    log(GroupId,"~p:resign_to_ready (pid:~p) epoch:~p group:~p inner-state:~p new-leader:~p~n",[?MODULE,self(),EpochId,GroupId,InnerState,NewLeaderPID]),
    CleanState = #{ current_epoch => EpochId, inner_state => InnerState, group_id => GroupId, leader => NewLeaderPID },
    gproc:reg({p, l, {paxos_member_fsm, GroupId}}),
    process_flag(trap_exit,false),%% member doesn't want to handle exceptions
    gen_fsm:enter_loop(paxos_member_fsm, [], ready, CleanState,
                       ?HEARTBEAT_TIMEOUT).


perform_operation({set, LeadersNewInternalState},
                  State = #{promises := Promises,
                            new_epoch := EpochId,
                            group_id := GroupId}) ->
    NewInnerState = determine_new_state(LeadersNewInternalState,Promises),
    send_to_members(GroupId, { commit, self(), EpochId, NewInnerState }),
    CleanState = maps:without([promises,promise_count],State),
    paxos_utils:maps_put_several([{new_inner_state, NewInnerState},
                                  {acceptance_count, 0}],CleanState);

perform_operation(get_consistent,
                  State = #{promises := Promises,
                            inner_state := LeadersInnerState,
                            new_epoch := EpochId,
                            group_id := GroupId}) ->
    R = lists:foldl(fun(S,{ok,[S]}) ->
                            {ok,[S]};
                       (OS,{_,R}) ->
                            {err,[OS|R]}
                    end,{ok,[LeadersInnerState]},Promises),
    %% I wasn't planning on making consistent gets follow through with a
    %% commit, but it has a nice side-effect, and maybe it's the right
    %% thing to do.
    case R of
        {ok,[S]} ->
            send_to_members(GroupId, { commit, self(), EpochId, S }),
            maps:put(get_consistent_result,{ok,S},State);
        {err,StateList} ->
            warn(GroupId,"~p:perform_operation(get_consistent group:~p epoch:~p inconsistent states:~p~n",
                 [?MODULE,GroupId,EpochId,StateList]),
            send_to_members(GroupId, { commit, self(), EpochId, LeadersInnerState }), %% sound?
            maps:put(get_consistent_result,R,State)
    end.

finalize_operation({set, _}, State = #{new_inner_state := NewInnerState, new_epoch := EpochId}) ->
    NewState = paxos_utils:maps_put_several([{inner_state,NewInnerState},
                                             {current_epoch,EpochId}],State),
    CleanState = maps:without([pending_operation],NewState),
    {ok, CleanState};

finalize_operation(get_consistent,State = #{get_consistent_result := R}) ->
    {R, maps:without([get_consistent_result,pending_operation], State)}.
