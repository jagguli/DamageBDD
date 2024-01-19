-module(damage_http).

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
-export([from_json/2, allowed_methods/2, from_html/2, is_authorized/2]).
-export([trails/0]).

-define(CHROMEDRIVER, "http://localhost:9515/").
-define(USER_BUCKET, {<<"Default">>, <<"Users">>}).
-define(TRAILS_TAG, ["Executing Tests"]).

trails() ->
  [
    trails:trail(
      "/execute_feature/",
      damage_http,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to execute a test on this DamageBDD server.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Execute a test on post",
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

get_access_token(Req) ->
  case cowboy_req:header(<<"authorization">>, Req) of
    <<"Bearer ", Token/binary>> -> {ok, Token};

    _ ->
      case catch cowboy_req:match_qs([access_token], Req) of
        #{access_token := Token} -> {ok, Token};

        _ ->
          Cookies = cowboy_req:parse_cookies(Req),
          case lists:keyfind(<<"sessionid">>, 1, Cookies) of
            {<<"sessionid">>, Token} -> {ok, Token};
            _ -> {error, missing}
          end
      end
  end.


is_authorized(Req, State) ->
  case get_access_token(Req) of
    {ok, Token} ->
      case oauth2:verify_access_token(Token, []) of
        {ok, {[], Auth}} ->
          #{
            <<"client">> := _Client,
            <<"resource_owner">> := ResourceOwner,
            <<"expiry_time">> := _Expiry,
            <<"scope">> := _Scope
          } = maps:from_list(Auth),
          case damage_riak:get(?USER_BUCKET, ResourceOwner) of
            {ok, #{ae_contract_address := ContractAddress} = User} ->
              {
                true,
                Req,
                maps:put(
                  user,
                  User,
                  maps:put(contract_address, ContractAddress, State)
                )
              };

            Noget ->
              logger:debug(
                "is_authoddrized Identity ~p ~p",
                [ResourceOwner, Noget]
              ),
              {{false, <<"Bearer">>}, Req, State}
          end;

        {error, access_denied} -> {{false, <<"Bearer">>}, Req, State};

        Other ->
          logger:error("Unexpected auth ~p", [Other]),
          {{false, <<"Bearer">>}, Req, State}
      end;

    {error, _} -> {{false, <<"Bearer">>}, Req, State}
  end.


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

get_concurrency_level(<<"sk_baby">>) -> 1;
get_concurrency_level(<<"sk_easy">>) -> 10;
get_concurrency_level(<<"sk_medium">>) -> 100;
get_concurrency_level(<<"sk_hard">>) -> 1000;
get_concurrency_level(<<"sk_nightmare">>) -> 10000;
get_concurrency_level(Other) when is_integer(Other) -> Other;
get_concurrency_level(Other) when is_binary(Other) -> binary_to_integer(Other).

get_config(
  #{account := Account, concurrency := Concurrency0} = FeaturePayload,
  Req0,
  Stream
) ->
  Concurrency = get_concurrency_level(Concurrency0),
  Formatters =
    case Concurrency of
      1 ->
        case Stream of
          nostream -> [];

          _ ->
            Req =
              cowboy_req:stream_reply(
                200,
                #{<<"content-type">> => <<"text/plain">>},
                Req0
              ),
            logger:info("execute_bdd req ~p", [Req]),
            [
              {
                text,
                #{
                  output => Req,
                  color => maps:get(color_formatter, FeaturePayload, false)
                }
              }
            ]
        end;

      _ ->
        ?debugFmt("execute_bdd concurrenc ~p", [Concurrency]),
        []
    end,
  damage:get_default_config(Account, Concurrency, Formatters).


execute_bdd(Config, #{feature := FeatureData}) ->
  case damage:execute_data(Config, FeatureData) of
    [#{fail := _FailReason, failing_step := {_KeyWord, Line, Step, _Args}} | _] ->
      Response =
        #{
          status => <<"notok">>,
          failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
          line => Line
        },
      {400, Response};

    {parse_error, LineNo, Message} ->
      logger:debug("failure ~p.", [Message]),
      {
        400,
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
      };

    #{report_hash := _} = Result ->
      {200, maps:merge(Result, #{status => <<"ok">>})}
  end.


check_execute_bdd(
  #{concurrency := Concurrency0} = _FeaturePayload,
  #{contract_address := ContractAddress} = _State,
  Req0
) ->
  Concurrency = get_concurrency_level(Concurrency0),
  IP = get_ip(Req0),
  case throttle:check(damage_api_rate, IP) of
    {limit_exceeded, _, _} ->
      lager:warning("IP ~p exceeded api limit", [IP]),
      {error, 429, Req0};

    _ ->
      case damage_accounts:check_spend(ContractAddress, Concurrency) of
        AvailConcurrency when AvailConcurrency > Concurrency ->
          {ok, ContractAddress, Concurrency};

        Other ->
          {
            400,
            <<
              "Insufficient balance, please top up balance at `/api/accounts/topup` balance:",
              Other/binary
            >>
          }
      end
  end.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case jsx:decode(Data, [{labels, atom}, return_maps]) of
      #{feature := FeatureData} = FeatureJson ->
        case check_execute_bdd(FeatureJson, State, Req) of
          {ok, Account, AvailConcurrency} ->
            FeaturePayload =
              #{
                feature => FeatureData,
                account => Account,
                concurrency => AvailConcurrency
              },
            execute_bdd(
              get_config(FeaturePayload, Req, nostream),
              FeaturePayload
            );

          Err ->
            logger:error("json decoding failed ~p err: ~p.", [Data, Err]),
            {400, <<"Invalid Request">>}
        end;

      _ -> {400, <<"Invalid Request">>}
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req0, State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  logger:debug("Req ~p.", [Req]),
  _UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
  Concurrency = cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>),
  ColorFormatter =
    case cowboy_req:match_qs([{color, [], <<"true">>}], Req0) of
      #{color := <<"true">>} -> true;
      _Other -> false
    end,
  case
  check_execute_bdd(
    #{
      feature => Body,
      color_formatter => ColorFormatter,
      concurrency => Concurrency
    },
    State,
    Req0
  ) of
    {ok, Account, AvailConcurrency} ->
      FeaturePayload =
          #{
            feature => Body,
            account => Account,
            color_formatter => ColorFormatter,
            concurrency => AvailConcurrency
          },
      {200, _} =
      execute_bdd(
        get_config(FeaturePayload, Req0, maybe_stream),
        FeaturePayload
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


to_html(Req, State) ->
  Body = damage_utils:load_template("api.mustache", #{body => <<"Test">>}),
  {Body, Req, State}.


to_json(Req0, State) ->
  Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req0, State}.


to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.

get_ip(Req0) ->
  case cowboy_req:peer(Req0) of
    {{IP, _}, _} -> IP;
    {IP, _} -> IP
  end.
