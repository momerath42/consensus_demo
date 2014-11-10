-module(paxos_sup).
-behaviour(supervisor).

-include("paxos.hrl").

%-compile({parse_transform, do}).
-compile({parse_transform, cut}).

-export([start_link/1]).
-export([init/1]).


start_link(GroupId) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [GroupId]).

init([GroupId]) ->
    io:format("paxos_sup group:~p~n",[GroupId]),
    ChildSpec = {_, {paxos_member_fsm, start_link, [GroupId]}, permanent, brutal_kill, worker, [paxos_member_fsm]},
    {ok,
     { {one_for_one, 5, 60},
       [ ChildSpec(list_to_atom("paxos_member_fsm"++integer_to_list(I)))
         || I <- lists:seq(1,?NODE_COUNT) ]
     }}.
