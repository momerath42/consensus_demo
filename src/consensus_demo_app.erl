-module(consensus_demo_app).

-behaviour(application).

-export([
    start/2,
    stop/1
]).

-export([start/0]).

start() ->
%% this shouldn't be necessary, but for some reason the command line
%% options and .app methods are both failing
    application:start(inets),
    application:start(crypto),
    application:start(syntax_tools),
    application:start(compiler),
    application:start(xmerl),
    application:start(asn1),
    application:start(public_key),
    application:start(ssl),
    application:start(mochiweb),
    application:start(webmachine),
    application:start(gproc),
    application:start(consensus_demo).

start(_Type, _StartArgs) ->
    io:format("consensus_demo_app:start/2~n"),
    inets:start(),
    application:start(gproc),
    consensus_demo_sup:start_link(),
    GroupId = 1,
    paxos_sup:start_link(GroupId).


stop(_State) ->
    ok.
