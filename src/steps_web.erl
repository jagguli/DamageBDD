%% @author Steven Joseph
%% @copyright 2021 Steven Joseph
%% @version 1.0.0
%% @doc HTTP Steps

-module(steps_web).

-export([step/6]).

response_to_list({Status, StatusCode, Headers, Body}) ->
  [{status, Status}, {status_code, StatusCode}, {headers, Headers}, {body, Body}].

step(Config, Context, when_keyword, _N, ["I make a GET request to", Url], _) ->
  %io:format("DEBUG step_when I make a GET request to ~p ~n~p ~n", [Url,_Given]),
  {url, ServerUrl} = lists:keyfind(url, 1, Config),
  dict:store(
    response,
    response_to_list(
      hackney:request(
        get,
        ServerUrl ++ list_to_binary(Url),
        dict:fetch(headers, Context),
        <<>>,
        [{pool, default}, {with_body, true}]
      )
    ),
    Context
  );

step(Config, Context, when_keyword, _N, ["I make a POST request to", Path], Data) ->
  {url, BaseUrl} = lists:keyfind(url, 1, Config),
  Url = list_to_binary(BaseUrl ++ Path),
  dict:store(
    response,
    response_to_list(
      hackney:request(post, Url, dict:fetch(headers, Context), Data, [{with_body, true}])
    ),
    Context
  );

step(Config, Context, when_keyword, _N, ["I make a CSRF POST request to", Path], Data) ->
  {url, BaseUrl} = lists:keyfind(url, 1, Config),
  Url = list_to_binary(BaseUrl ++ Path),
  logger:debug("Target URL: ~p", [Url]),
  Headers0 =
    lists:append(
      [
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"Referer">>, Url},
        {<<"X-Requested-with">>, <<"XMLHttpRequest">>}
      ],
      dict:fetch(headers, Context)
    ),
  {ok, StatusCode, Headers, Body} = hackney:request(get, Url, Headers0, <<>>, [{pool, default}]),
  logger:debug("Status: ~p, Headers: ~p, Body: ~p", [StatusCode, Headers, Body]),
  {_, CSRFToken} = lists:keyfind(<<"X-CSRFToken">>, 1, Headers),
  {_, SessionId} = lists:keyfind(<<"X-SessionID">>, 1, Headers),
  dict:store(
    response,
    response_to_list(
      hackney:request(
        post,
        Url,
        lists:append(Headers0, [{<<"X-CSRFToken">>, CSRFToken}, {<<"X-SessionID">>, SessionId}]),
        {form, jsx:decode(Data)},
        [
          {
            cookie,
            [
              {<<"csrf_token">>, CSRFToken, [{path, <<"/">>}]},
              {<<"csrftoken">>, CSRFToken, [{path, <<"/">>}]}
            ]
          },
          {with_body, true}
        ]
      )
    ),
    Context
  );

step(_Config, Context, then_keyword, _N, ["the response status must be", Status], _) ->
  Status0 = list_to_integer(Status),
  case dict:fetch(response, Context) of
    [_, {status_code, Status0}, _, _] -> true;

    [_, {status_code, Status1}, _, _] ->
      throw({fail, io_lib:format("Response status is not ~p, got ~p", [Status0, Status1])});

    Any -> throw({fail, io_lib:format("Response status is not ~p, got ~p", [Status0, Any])})
  end;

step(_Config, Context, then_keyword, _N, ["the json at path", Path, "must be", Json], _) ->
  case dict:fetch(response, Context) of
    [_, _StatusCode, _Headers, Body] ->
      Json0 = list_to_binary(Json),
      logger:debug("step_then the json at path ~p must be ~p~n~p~n", [Path, Json0, Body]),
      logger:debug("~p~n", [ejsonpath:q(Path, jsx:decode(Body, [return_maps]))]),
      case ejsonpath:q(Path, jsx:decode(Body, [return_maps])) of
        {[Json0 | _], _} -> true;

        UnExpected ->
          throw(
            {
              fail,
              io_lib:format("the json at path ~p is not ~p, it is ~p.", [Path, Json, UnExpected])
            }
          )
      end;

    UnExpected -> throw({fail, io_lib:format("Unexpected response ~p", [UnExpected])})
  end;

step(_Config, Context, then_keyword, _N, ["the response status should be one of", Responses], _) ->
  case dict:fetch(response, Context) of
    {_, StatusCode, _Headers, _Body} ->
      case
      lists:member(
        StatusCode,
        lists:map(fun erlang:list_to_integer/1, string:split(Responses, ","))
      ) of
        true -> true;

        _ ->
          throw(
            {fail, io_lib:format("Response status ~p is not one of ~p", [StatusCode, Responses])}
          )
      end;

    UnExpected -> throw(io_lib:format("Unexpected response ~p", [UnExpected]))
  end;

step(_Config, Context, then_keyword, _N, ["I print the response"], _) ->
  {_, _StatusCode, _Headers, Body} = dict:fetch(response, Context),
  logger:info("Response: ~s", [Body]),
  true;

step(_Config, Context, _Keyword, _N, ["I set", Header, "header to", Value], _) ->
  dict:append(headers, {list_to_binary(Header), list_to_binary(Value)}, Context);

step(_Config, Context, given_keyword, _N, ["I store cookies"], _) ->
  {_, _StatusCode, Headers, _Body} = dict:fetch(response, Context),
  Cookies = lists:foldl(fun ({<<"Set-Cookie">>, Header}, Acc) -> [Acc | Header] end, [], Headers),
  logger:debug("Response:  ~p ~s", [Headers, Cookies]);

step(_Config, _Context, given_keyword, _N, ["I start a websocket connection to ", WebSocketUrl], _) ->
  {ok, ConnPid} = gun:open(WebSocketUrl, 80),
  {ok, _Protocol} = gun:await_up(ConnPid).


%dict:append(headers, {list_to_binary(Header), list_to_binary(Value)}, Context).
