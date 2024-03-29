-module(damage_schedule).

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
-export([execute_bdd/2]).
-export([do_schedule/3]).
-export([do_schedule/5]).
-export([do_schedule/6]).
-export([load_schedules/0]).
-export([load_schedules/1]).
-export([delete_schedule/1]).
-export([test_conflict_resolution/0]).
-export([trails/0]).
-export([is_authorized/2]).

-include_lib("kernel/include/logger.hrl").

-define(SCHEDULES_BUCKET, {<<"Default">>, <<"Schedules">>}).
-define(TRAILS_TAG, ["Scheduling Tests"]).

trails() ->
  [
    trails:trail(
      "/schedule/[...]",
      damage_schedule,
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

execute_bdd(ScheduleId, Concurrency) ->
  %% Add the filter to allow PidToLog to send debug events
  [ContractAddress, Hash] = string:split(ScheduleId, <<"|">>),
  logger:error(
    "scheduled job execution ~p ContractAddress ~p, Hash ~p.",
    [ScheduleId, ContractAddress, Hash]
  ),
  Config = damage:get_default_config(ContractAddress, Concurrency, []),
  {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
  BddFileName = filename:join(RunDir, string:join(["scheduled.feature"], "")),
  ok = damage_ipfs:get(ScheduleId, BddFileName),
  logger:debug(
    "scheduled job execution config ~p feature ~p scheduleid ~p.",
    [Config, BddFileName, ScheduleId]
  ),
  damage:execute_file(Config, BddFileName).


do_schedule({Concurrency, ScheduleId}, daily, every, Hour, Minute, AMPM) ->
  Job =
    {
      {once, {Hour, Minute, AMPM}},
      {damage_schedule, execute_bdd, [ScheduleId, Concurrency]}
    },
  erlcron:cron(ScheduleId, Job).


do_schedule({Concurrency, ScheduleId}, daily, every, Second, sec) ->
  Job =
    {
      {daily, {every, {Second, sec}}},
      {damage_schedule, execute_bdd, [ScheduleId, Concurrency]}
    },
  erlcron:cron(ScheduleId, Job);

do_schedule({Concurrency, ScheduleId}, once, Hour, Minute, Second)
when is_integer(Second) ->
  Job =
    {
      {once, {Hour, Minute, Second}},
      {damage_schedule, execute_bdd, [ScheduleId, Concurrency]}
    },
  erlcron:cron(ScheduleId, Job);

do_schedule({Concurrency, ScheduleId}, once, Hour, Minute, AMPM)
when is_atom(AMPM) ->
  Job =
    {
      {once, {Hour, Minute, AMPM}},
      {damage_schedule, execute_bdd, [ScheduleId, Concurrency]}
    },
  erlcron:cron(ScheduleId, Job).


do_schedule({Concurrency, ScheduleId}, once, Seconds) when is_integer(Seconds) ->
  Job =
    {{once, Seconds}, {damage_schedule, execute_bdd, [ScheduleId, Concurrency]}},
  erlcron:cron(ScheduleId, Job).


binary_spec_to_term_spec([], Acc) -> Acc;

binary_spec_to_term_spec([Spec | Rest], Acc) ->
  Term =
    case catch binary_to_integer(Spec) of
      {'EXIT', _} -> binary_to_atom(Spec);
      Int -> Int
    end,
  binary_spec_to_term_spec(Rest, Acc ++ [Term]).


validate(Gherkin) ->
  case catch egherkin:parse(Gherkin) of
    {failed, LineNo, Message} ->
      logger:error("Parsing Failed LineNo +~p ~n     ~p.", [LineNo, Message]),
      {parse_error, LineNo, Message};

    {_LineNo, _Tags, _Feature, _Description, _BackGround, _Scenarios} -> ok
  end.


from_text(Req, #{contract_address := ContractAddress} = State) ->
  {ok, Body, _} = cowboy_req:read_body(Req),
  ok = validate(Body),
  CronSpec = binary_spec_to_term_spec(cowboy_req:path_info(Req), []),
  Concurrency = cowboy_req:header(<<"x-damage-concurrency">>, Req, 1),
  logger:debug("Cron Spec: ~p", [CronSpec]),
  {ok, #{<<"Hash">> := Hash}} =
    damage_ipfs:add({data, Body, <<"Scheduledjob">>}),
  ScheduleId = <<ContractAddress/binary, "|", Hash/binary>>,
  Args = [{Concurrency, ScheduleId}] ++ CronSpec,
  logger:info("do_schedule: ~p", [Args]),
  CronJob = apply(?MODULE, do_schedule, Args),
  Created = date_util:now_to_seconds_hires(os:timestamp()),
  logger:info("Cron Job: ~p", [CronJob]),
  {ok, true} =
    save_schedule(
      #{
        created => Created,
        modified => Created,
        contract_address => ContractAddress,
        hash => Hash,
        concurrency => Concurrency,
        cronspec => CronSpec
      }
    ),
  %damage_accounts:update_schedules(ContractAddress, Hash, CronJob),
  Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_json(Req, State) -> from_text(Req, State).

from_html(Req, State) -> from_text(Req, State).

to_html(Req, State) -> to_json(Req, State).

to_text(Req, State) -> to_json(Req, State).

to_json(Req, #{contract_address := ContractAddress} = State) ->
  Body = jsx:encode(load_schedules(ContractAddress)),
  logger:info("Loading scheduled for ~p ~p", [ContractAddress, Body]),
  {Body, Req, State}.


save_schedule(
  #{contract_address := ContractAddress, hash := Hash, cronspec := _CronSpec} =
    Schedule
) ->
  Obj = damage_riak:get(?SCHEDULES_BUCKET, Hash),
  case catch riakc_obj:get_value(Obj) of
    siblings -> logger:error("failed to load  schedule ~p", [Obj]);
    Schedule -> logger:info("loaded  schedule ~p", [Schedule])
  end,
  {ok, true} =
    damage_riak:put(
      ?SCHEDULES_BUCKET,
      Hash,
      jsx:encode(Schedule),
      [{{binary_index, "contract_address"}, [ContractAddress]}]
    ).


delete_schedule(ScheduleId) ->
  damage_riak:delete(?SCHEDULES_BUCKET, ScheduleId).

load_schedule(ScheduleId) ->
  logger:debug("Schedulid ~p", [ScheduleId]),
  case catch damage_riak:get(?SCHEDULES_BUCKET, ScheduleId) of
    notfound -> logger:info("schedule notfound ~p", [ScheduleId]);

    Schedule ->
      case catch jsx:decode(Schedule) of
        {'EXIT', Error} ->
          logger:error("failed to load  schedule ~p ~p", [Schedule, Error]);

        Ok -> logger:info("Loaded  schedule ~p", [Ok])
      end
  end.


load_schedules(ContractAddress) ->
  [
    load_schedule(ScheduleId)
    ||
    ScheduleId
    <-
    damage_riak:get_index(
      ?SCHEDULES_BUCKET,
      {binary_index, "contract_address"},
      ContractAddress
    )
  ].

load_schedules() ->
  [
    load_schedule(ScheduleId)
    || ScheduleId <- damage_riak:list_keys(?SCHEDULES_BUCKET)
  ].

test_conflict_resolution() -> load_schedules().
