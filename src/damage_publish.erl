-module(damage_publish).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([is_authorized/2]).
-export([trails/0]).

-define(CHROMEDRIVER, "http://localhost:9515/").
-define(TRAILS_TAG, ["Publish Tests For Open Market Execution"]).

trails() ->
  [
    trails:trail(
      "/publish_feature/",
      damage_publish,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to schedule a test execution.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Schedule a test on post",
          produces => ["application/json"],
          parameters
          =>
          [
            #{
              name => <<"feature">>,
              description => <<"Test feature data.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
          ]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
  {
    [
      {{<<"text">>, <<"html">>, '*'}, to_html},
      {{<<"application">>, <<"json">>, []}, to_json},
      {{<<"text">>, <<"plain">>, '*'}, to_text}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_html(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  to_text(Req, State).


%logger:error("to text ipfs hash ~p ", [Req]),
%Body = damage_utils:load_template("report.mustache", [{body, <<"Test">>}]),
%logger:info("get ipfs hash ~p ", [Body]),
%{Body, Req, State}.
to_json(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  to_text(Req, State).


to_text(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  {<<"ok">>, Req, State}.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case jsx:decode(Data, [{labels, atom}, return_maps]) of
      #{feature := _FeatureData, account := _Account} = FeatureJson ->
        publish_bdd(FeatureJson, Req);

      Err ->
        logger:error("json decoding failed ~p.", [Data]),
        {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
    end,
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req0, State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  logger:debug("Req ~p.", [Req]),
  _UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
  Concurrency =
    binary_to_integer(
      cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
    ),
  ColorFormatter =
    case cowboy_req:match_qs([{color, [], <<"true">>}], Req0) of
      #{color := <<"true">>} -> true;
      _Other -> false
    end,
  case
  damage_http:check_execute_bdd(
    #{
      feature => Body,
      color_formatter => ColorFormatter,
      concurrency => Concurrency
    },
    Req0
  ) of
    {ok, Account, AvailConcurrency} ->
      {200, _} =
        publish_bdd(
          #{
            feature => Body,
            account => Account,
            color_formatter => ColorFormatter,
            concurrency => AvailConcurrency
          },
          Req0
        ),
      case AvailConcurrency of
        1 -> {stop, Req0, State};

        _ ->
          Resp0 =
            jsx:encode(damage_accounts:confirm_spend(Account, AvailConcurrency)),
          Res1 = cowboy_req:set_resp_body(Resp0, Req),
          {true, Res1, State}
      end;

    Req ->
      logger:debug("failed tests ~p.", [Req]),
      Req
  end.


publish_bdd(
  #{feature := FeatureData, account := Account, concurrency := Concurrency} =
    FeaturePayload,
  Req0
) ->
  Formatters =
    case Concurrency of
      1 ->
        Req =
          cowboy_req:stream_reply(
            200,
            #{<<"content-type">> => <<"text/plain">>},
            Req0
          ),
        logger:info("publish_bdd req ~p", [Req]),
        [
          {
            text,
            #{
              output => Req,
              color => maps:get(color_formatter, FeaturePayload, false)
            }
          }
        ];

      _ ->
        ?debugFmt("publish_bdd concurrenc ~p", [Concurrency]),
        []
    end,
  Config = damage:get_default_config(Account, Concurrency, Formatters),
  case damage:publish_data(Config, FeatureData) of
    [#{fail := _FailReason, failing_step := {_KeyWord, Line, Step, _Args}} | _] ->
      Response =
        #{
          status => <<"notok">>,
          failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
          line => Line
        },
      {400, jsx:encode(Response)};

    {parse_error, LineNo, Message} ->
      logger:debug("failure ~p.", [Message]),
      {
        400,
        jsx:encode(
          #{
            status => <<"notok">>,
            message => list_to_binary(Message),
            line => LineNo,
            hint
            =>
            <<
              "Make sure post data is in binary eg: curl --data-binary @features/test.feature ..."
            >>
          }
        )
      };

    ResultOk ->
      %logger:debug("No failure ~p.", [Ok]),
      {200, jsx:encode(ResultOk)}
  end.
