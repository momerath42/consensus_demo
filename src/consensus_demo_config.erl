-module(consensus_demo_config).

-export([
    dispatch/0,
    web_config/0
]).

-spec dispatch() -> [webmachine_dispatcher:route()].
dispatch() ->
    {ok,DispatchTerms} = file:consult("priv/dispatch.conf"),
    lists:flatten([
                   DispatchTerms,
                   {[], consensus_demo_resource, []}
                  ]).

web_config() ->
    {ok, App} = application:get_application(?MODULE),
    {ok, Ip} = application:get_env(App, web_ip),
    {ok, Port} = application:get_env(App, web_port),
    [
        {ip, Ip},
        {port, Port},
        {log_dir, "priv/log"},
        {dispatch, dispatch()}
    ].
