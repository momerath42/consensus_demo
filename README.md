consensus_demo
==============

A quick, toy implementation of something resembling paxos.

For Ripple Labs amusement, but legally encumbered by current IP agreement with Analytical Informatics.

Status: 

I started with what I thought would be the simplest option that I could expand on in interesting ways, but I underestimated the task a bit, and have had multiple distractions this weekend.  What exists now, and I believe works properly (supplying the guarantees it should), is a partially role-consolidated version of paxos with no partial-state-transformation (set is all or nothing).  Something that doesn't happen the way it would in some/most paxos systems is that rejoined nodes aren't immediately updated with the consentual state; they'll get it on the next set or get_consistent (I haven't had time to reason-out/test the implications, especially with a "stable leader").  I also have a feeling the processes of agreeing on an update, and election, could be elegantly refactored into one thing, but again, time (and inexperience with this problem domain).

I wanted to have a nice little web gui for watching the activities of the nodes, and causing simulated misbehavior (netsplits and crashes).  A chunked-encoding issue has me stalled out on that front; currently the only way to watch the activity is to tail group1.log (and to call 'paxos_utils:log_to_disk(GroupId,"filename").' at the erlang console, where GroupId is any other groups you split nodes into, and watch that log).


Client interface:

paxos_leader_fsm:set(GroupId,NewState).

paxos_leader_fsm:get_consistent(GroupId). %% consults quorum about state and returns {ok,State} if consistent, or {err,ListOfStates} if it's not (see status on updating rejoined nodes)

paxos_leader_fsm:get_fast(GroupId). %% returns the leader's internal state; accurate if the leader hasn't changed (intend to guarantee 'stable' leadership, as does riak_ensemble)


Simulation commands (erlang console):

paxos_leader_fsm:simulate_split_members(GroupId,NewGroupId,NumToSplit). %% moves NumToSplit nodes in member roles to a different group (which doesn't need to pre-exist); they'll act as though there were a netsplit.

paxos_leader_fsm:simulate_split_leader(GroupId,NewGroupId). %% moves the leader to a different group, simulating a case where just it is netsplit from the members (to simulate leader + n-members split, just call both functions in rapid succeession)

Compile-time Options (intended to make them dynamic given time) - found in include/paxos.hrl:

FUZZ - set to true, will use the PACKET_LOSS_ and _DUP_PERCENTAGE values to simulate a noisy/broken network link.

NODE_COUNT and QUORUM_COUNT and various _TIMEOUTS should be self-explanatory.


To Run:

1. Install Erlang R17.3 (sorry, also meant to get a docker or vagrantfile written)
2. from this cloned repo's directory:
3. ./rebar get-deps
4. ./rebar compile
5. ./start.sh

