-module(consensus_demo_resource).

-export([init/1, content_types_provided/2, content_types_accepted/2,
         allowed_methods/2, %%to_json/2, %% from_json/2,
%         is_authorized/2,
         malformed_request/2, process_post/2, %allow_missing_post/2,
         options/2, variances/2]).


-include_lib("webmachine/include/webmachine.hrl").

%% ------------------------------------------------------------------
%% WebMachine Callbacks:
%% ------------------------------------------------------------------

init(_Config) ->
    {{trace, "/tmp"}, #{}}.
%    {ok, _Config}.

content_types_provided(ReqData, State) ->
    { [ {"text/html", to_html} ], ReqData, State}.

content_types_accepted(ReqData, State) ->
    { [ {"application/json", from_json} ], ReqData, State }.

allowed_methods(ReqData, State) ->
    { ['GET','POST','OPTIONS'], ReqData, State}.
%%    { ['GET', 'POST', 'PUT', 'DELETE', 'HEAD'], ReqData, State}.

options(ReqData,State) ->
    io:format("options~n"),
    {[%%{"Access-Control-Allow-Origin","*"}, %% TODO! make this more restrictive, based on some configuration or discovery
      {"Access-Control-Allow-Origin","http://localhost:8001"}, %%
      {"Access-Control-Allow-Methods","POST, OPTIONS"},
      {"Access-Control-Max-Age","1000"},
      {"Access-Control-Allow-Headers","origin, x-csrftoken, content-type, accept"}
     ],ReqData,State}.

variances(ReqData,State) ->
    io:format("variances~n"),
    {["Origin"],ReqData,State}.

%% allow_missing_post(ReqData,State) ->
%%     {true,ReqData,State}.

%%is_authorized(ReqData,State) ->
 %%   {true,ReqData,State}

malformed_request(ReqData, State) ->
    handle_malformed_request(wrq:method(ReqData), ReqData, State).

handle_malformed_request('OPTIONS',ReqData,State) ->
    {false, ReqData, State };

handle_malformed_request('POST',ReqData,State) ->
    PIDStr = wrq:path_info(process, ReqData),
    ActionStr = wrq:path_info(action, ReqData),
%%    ReqBody = wrq:req_body(ReqData),
    io:format("malformed_request pidstr:~p actionstr:~p~n",
              [PIDStr,ActionStr]),
    if (PIDStr and ActionStr) ->
            {false, ReqData, State};
       true ->
            {true, ReqData, State}
    end.



process_post(ReqData,State) ->
    %% todo
    {true, ReqData, State}.
