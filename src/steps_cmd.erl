-module(steps_cmd).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

step(_Config, Context, <<"When">>, _N, ["I run the command", Command], _) ->
  {ok, Allowed} = application:get_env(damage, cmd_allowed),
  CommandPath = os:find_executable(Command),
  case lists:search(fun (Command1) -> Command1 =:= CommandPath end, Allowed) of
    false ->
      maps:put(
        fail,
        damage_utils:strf("Command is not in allowed commands", []),
        Context
      );

    {value, Command0} ->
      CWD = filename:absname(maps:get(cmd_cwd, Context, "/tmp")),
      maps:put(
        cmd_result,
        exec:run(Command0, [sync, stderr, stdout, {cd, CWD}]),
        Context
      )
  end;

step(_Config, Context, <<"Then">>, _N, ["the exit status must be", Status], _) ->
  StatusInt = list_to_integer(Status),
  case maps:get(cmd_result, Context) of
    {ok, _Res} when StatusInt =:= 0 -> Context;
    {error, [{exit_status, Status}]} -> Context;

    Other ->
      maps:put(
        fail,
        damage_utils:strf("Exit status is not ~p, got ~p", [StatusInt, Other]),
        Context
      )
  end;

step(_Config, Context, <<"Given">>, _N, ["I change directory to", Path], _) ->
  maps:put(cmd_cwd, Path, Context);

step(_Config, _Context, <<"Given">>, _N, ["I am the node named", _Node], _) ->
  ok.