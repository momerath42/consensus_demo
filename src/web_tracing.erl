-module(web_tracing).

-export([init/1, content_types_provided/2, content_types_accepted/2,
         allowed_methods/2, to_html/2 %%to_json/2, %% from_json/2,
%         is_authorized/2, malformed_request/2,
 %        process_post/2, %allow_missing_post/2,
%         options/2, variances/2
        ]).


-include_lib("webmachine/include/webmachine.hrl").

-define(LOG_TIMEOUT,60000).

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
    { ['GET'], ReqData, State}.

send_streamed_log() ->
    receive
        {paxos_log, GroupId, Pid, FStr, FArgs} ->
            Line = lists:flatten(io_lib:format("~p|~p|"++FStr,[GroupId,Pid|FArgs])),
            {Line, fun send_streamed_log/0}
    after ?LOG_TIMEOUT ->
            {"",done}
    end.

start_streaming_log() ->
    {"\r\ntest\r\n", fun send_streamed_log/0}.

to_html(ReqData,State) ->
    io:format("web_tracing:to_html~n"),
%    PIDStr = wrq:path_info(process, ReqData),
    GroupId = list_to_integer(wrq:path_info(group,ReqData)),
    paxos_utils:subscribe_to_log(GroupId),
    NewReqData = wrq:set_resp_header("Content-Length", "", ReqData),
    {{halt,200}, wrq:set_resp_body({stream,fun start_streaming_log/0},NewReqData), State}.
