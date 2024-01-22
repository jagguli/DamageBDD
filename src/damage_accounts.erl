-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).

%-export([to_text/2]).
-export(
  [create_contract/1, balance/1, check_spend/2, store_profile/1, refund/1]
).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([update_schedules/3]).
-export([confirm_spend/2]).
-export([is_allowed_domain/1]).
-export([lookup_domain/1]).
-export([get_account_context/1]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

-define(USER_BUCKET, {<<"Default">>, <<"Users">>}).
-define(CONTEXT_BUCKET, {<<"Default">>, <<"Contexts">>}).
-define(CONFIRM_TOKEN_BUCKET, {<<"Default">>, <<"ConfirmTokens">>}).
-define(TRAILS_TAG, ["Account Management"]).
-define(DOMAIN_TOKEN_BUCKET, {<<"Default">>, <<"DomainTokens">>}).

trails() ->
  [
    trails:trail(
      "/accounts/create",
      damage_accounts,
      #{action => create},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to create an account on this DamageBDD server.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create account using form ",
          produces => ["text/html"],
          parameters
          =>
          [
            #{
              name => <<"email">>,
              description
              =>
              <<"A valid email address for user account recovery.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"full_name">>,
              description => <<"A name to reffer to user in communications.">>,
              in => <<"body">>,
              required => false,
              type => <<"string">>
            }
          ]
        }
      }
    ),
    trails:trail(
      "/accounts/balance",
      damage_accounts,
      #{action => balance},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "do some action ",
          produces => ["text/plain"]
        }
      }
    ),
    trails:trail(
      "/accounts/confirm",
      damage_accounts,
      #{action => confirm},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Confirm account.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              name => <<"token">>,
              description
              =>
              <<"A valid confirmation token sent to account email.">>,
              in => <<"query">>,
              required => true,
              type => <<"string">>
            }
          ]
        }
      }
    ),
    trails:trail(
      "/accounts/reset_password",
      damage_accounts,
      #{action => reset_password},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Reset password using reset token sent to email.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              name => <<"token">>,
              description
              =>
              <<"A valid reset password token sent to account email.">>,
              in => <<"query">>,
              required => true,
              type => <<"string">>
            }
          ]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Submit reset password form.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              name => <<"current_password">>,
              description => <<"Current password">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"new_password">>,
              description => <<"New password">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"new_password_confirm">>,
              description => <<"New password confirmation">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
          ]
        }
      }
    ),
    trails:trail(
      "/accounts/domains",
      damage_accounts,
      #{action => domains},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "List domain tokens.",
          produces => ["text/plain"],
          parameters
          =>
          [
          ]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Submit reset password form.",
          produces => ["text/plain"],
          parameters
          =>
          [
            #{
              name => <<"domain">>,
              description => <<"the domain for which to generate token for.">>,
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

content_types_provided(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, []}, to_json},
      %{{<<"text">>, <<"plain">>, '*'}, to_text},
      {{<<"text">>, <<"html">>, '*'}, to_html}
    ],
    Req,
    State
  }.


content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

validate_refund_addr(forward, BtcAddress) ->
  case bitcoin:validateaddress(BtcAddress) of
    {ok, #{isvalid := true, address := BtcAddress}} -> {ok, BtcAddress};
    _Other -> {ok, false}
  end.


to_json(Req, #{action := domains, contract_address:=ContractAddress} = State) ->
    case damage_riak:get(?DOMAIN_TOKEN_BUCKET, ContractAddress) of
        [] ->
            {200, []};
        Found -> 
            {200, Found}
    end;

to_json(Req, #{action := balance} = State) ->
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      {jsx:encode(balance(ContractAddress)), Req, State};

    Other ->
      logger:debug("Unexpected ~p", [Other]),
      {<<"Unauthorized.">>, Req, State}
  end.


to_html(Req, #{action := create} = State) ->
  Body =
    damage_utils:load_template("create_account.mustache", #{body => <<"Test">>}),
  {Body, Req, State};

to_html(Req, #{action := confirm} = State) ->
  #{token := Password} = cowboy_req:match_qs([token], Req),
  case damage_riak:get(?CONFIRM_TOKEN_BUCKET, Password) of
    {ok, #{email := Email, expiry := _Expiry}} ->
      Body =
        damage_utils:load_template(
          "reset_password.mustache",
          #{email => Email, current_password => Password, body => <<"Test">>}
        ),
      {Body, Req, State};

    notfound -> {<<"Invalid confirmation link. Please try again.">>, Req, State}
  end;

to_html(Req, #{action := reset_password} = State) ->
  Body =
    case damage_oauth:reset_password(cowboy_req:match_qs([token], Req)) of
      {ok, Body0} -> Body0;
      {error, Msg} -> Msg
    end,
  {Body, Req, State}.


do_post_action(create, Data) ->
  case damage_oauth:add_user(Data) of
    {ok, Message} -> {201, #{status => <<"ok">>, message => Message}};
    {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
  end;

do_post_action(reset_password, Data) ->
  case damage_oauth:reset_password(Data) of
    {ok, Message} -> {201, #{status => <<"ok">>, message => Message}};
    {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
  end;

do_post_action(domains, #{email := Email} = _Data) ->
  case damage_riak:get_index(<<"email_bin">>, Email) of
    [] -> [];
    List -> List
  end.


from_html(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  FormData = maps:from_list(cow_qs:parse_qs(Data)),
  {Status0, Response0} = do_post_action(Action, FormData),
  Body =
    case Action of
      create -> <<"Account created successfuly and password set.">>;

      refund ->
        #{account := ContractAddress} = cowboy_req:match_qs([account], Req),
        refund(ContractAddress);

      _ -> Response0
    end,
  {
    stop,
    cowboy_req:reply(Status0, cowboy_req:set_resp_body(jsx:encode(Body), Req)),
    State
  }.


from_json(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} =
    case catch jsx:decode(Data, [return_maps]) of
      badarg ->
        {400, #{status => <<"failed">>, message => <<"Json decode error.">>}};

      Data0 -> do_post_action(Action, Data0)
    end,
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(jsx:encode(Response0), Req)
    ),
    State
  }.


from_yaml(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} =
    case fast_yaml:decode(Data, [maps]) of
      {ok, [Data0]} -> do_post_action(Action, Data0);
      {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
    end,
  logger:debug("post action ~p resp ~p", [Data, Response0]),
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(fast_yaml:encode(Response0), Req)
    ),
    State
  }.


create_contract(RefundAddress) ->
  % create ae account and bitcoin account
  #{result := #{contractId := ContractAddress}} =
    damage_ae:aecli(contract, deploy, "contracts/account.aes", []),
  {ok, BtcAddress} = bitcoin:getnewaddress(ContractAddress),
  ?debugFmt(
    "debug created AE contractid ~p ~p, ",
    [ContractAddress, BtcAddress]
  ),
  _ContractCreated =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "set_btc_state",
      [BtcAddress, RefundAddress]
    ),
  %?debugFmt("debug created AE contract ~p", [ContractCreated]),
  #{
    status => <<"ok">>,
    btc_address => BtcAddress,
    ae_contract_address => ContractAddress,
    btc_refund_address => RefundAddress
  }.


store_profile(ContractAddress) ->
  % store config schedule etc
  logger:debug("debug ~p", [ContractAddress]),
  ok.


check_spend("guest", _Concurrency) -> ok;
check_spend(<<"guest">>, _Concurrency) -> ok;

check_spend(ContractAddress, _Concurrency) ->
  #{decodedResult := Balance} =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "total_balance",
      []
    ),
  binary_to_integer(Balance).


balance(ContractAddress) ->
  ContractCall =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "get_state",
      []
    ),
  ?debugFmt("call AE contract ~p", [ContractCall]),
  #{
    decodedResult
    :=
    #{
      btc_address := BtcAddress,
      btc_balance := BtcBalance,
      deso_address := _DesoAddress,
      deso_balance := _DesoBalance,
      usage := Usage,
      deployer := _Deployer
    } = Results
  } = ContractCall,
  ?debugFmt("State ~p ", [Results]),
  {ok, Transactions} = bitcoin:listtransactions(ContractAddress),
  ?debugFmt("Transactions ~p ", [Transactions]),
  {ok, RealBtcBalance} = bitcoin:getreceivedbyaddress(BtcAddress),
  Mesg =
    io:format(
      "Balance of account ~p usage is ~p btc_balance ~p btc_held ~p.",
      [ContractAddress, Usage, BtcBalance, RealBtcBalance]
    ),
  logger:debug(Mesg, []),
  maps:put(btc_refund_balance, RealBtcBalance, Results).


refund(ContractAddress) ->
  #{
    btc_address := BtcAddress,
    btc_refund_address := BtcRefundAddress,
    btc_balance := _BtcBalance,
    deso_address := _DesoAddress,
    deso_balance := _DesoBalance,
    balance := Balance,
    deployer := _Deployer
  } = balance(ContractAddress),
  case validate_refund_addr(forward, BtcRefundAddress) of
    {ok, BtcRefundAddress} ->
      {ok, RealBtcBalance} = bitcoin:getreceivedbyaddress(BtcAddress),
      ?debugFmt("real balance ~p ", [RealBtcBalance]),
      {ok, RefundResult} =
        bitcoin:sendtoaddress(
          BtcRefundAddress,
          RealBtcBalance - binary_to_integer(Balance),
          ContractAddress
        ),
      ?debugFmt("Refund result ~p ", [RefundResult]),
      RefundResult;

    Other ->
      ?debugFmt("refund_address data: ~p ", [Other]),
      #{status => <<"notok">>, message => <<"Invalid refund_address.">>}
  end.


update_schedules(ContractAddress, JobId, _Cron) ->
  ContractCall =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "update_schedules",
      [JobId]
    ),
  ?debugFmt("call AE contract ~p", [ContractCall]),
  #{
    decodedResult
    :=
    #{
      btc_address := _BtcAddress,
      btc_balance := _BtcBalance,
      deso_address := _DesoAddress,
      deso_balance := _DesoBalance,
      usage := _Usage,
      deployer := _Deployer
    } = Results
  } = ContractCall,
  ?debugFmt("State ~p ", [Results]).


confirm_spend(<<"guest">>, _) -> ok;

confirm_spend(ContractAddress, Amount) ->
  ContractCall =
    damage_ae:aecli(
      contract,
      call,
      binary_to_list(ContractAddress),
      "contracts/account.aes",
      "confirm_spend",
      [Amount]
    ),
  #{
    decodedResult
    :=
    #{
      btc_address := _BtcAddress,
      btc_balance := _BtcBalance,
      deso_address := _DesoAddress,
      deso_balance := _DesoBalance,
      usage := _Usage,
      deployer := _Deployer
    } = Balances
  } = ContractCall,
  ?debugFmt("call AE contract ~p", [Balances]),
  Balances.


lookup_domain(Domain) when is_binary(Domain) ->
  lookup_domain(binary_to_list(Domain));

lookup_domain(Domain) ->
  case inet_res:lookup(Domain, in, txt) of
    Records when is_list(Records) ->
      case lists:filtermap(
        fun
          ([Record]) ->
            case string:split(Record, "=") of
              ["damagebdd_token", Token] -> Token;
              _ -> false
            end
        end,
        Records
      ) of
        [] ->
          io:format("No TXT record found for token: ~p~n", [Records]),
          false;

        [Token | _] -> ok = check_host_token(Domain, Token)
      end;

    Other ->
      logger:debug("dns record look up failed ~p ~p", [Domain, Other]),
      false
  end.


is_allowed_domain(Host) when is_binary(Host) ->
  is_allowed_domain(binary_to_list(Host));

is_allowed_domain(Host) ->
  AllowedHosts = ["jsontest.com", "damagebdd.com", "run.damagebdd.com"],
  case lists:any(
    fun
      (LHost) ->
        case LHost of
          Host -> true;
          _ -> false
        end
    end,
    AllowedHosts
  ) of
    false -> lookup_domain(Host);
    true -> true
  end.


check_host_token(Host, Token) ->
  Keys =
    damage_riak:get_index(
      {<<"Default">>, <<"HostTokens">>},
      <<"host_bin">>,
      Host
    ),
  case lists:filter(
    fun
      (T) ->
        T = Token,
        true
    end,
    Keys
  ) of
    [Token] -> {ok, Token};
    [] -> {error, notfound}
  end.


get_account_context(Account) ->
  case damage_riak:get(?CONTEXT_BUCKET, Account) of
    {ok, Context} ->
      logger:debug("got context ~p", [Context]),
      Context;

    Other ->
      logger:debug("got context ~p", [Other]),
      #{}
  end.
