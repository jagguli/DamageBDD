-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([create/1, balance/1, check_spend/2, store_profile/1, refund/1]).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([sign_tx/1]).
-export([update_schedules/3]).
-export([test_contract_call/1]).
-export([confirm_spend/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, []}, to_json},
      {{<<"text">>, <<"plain">>, '*'}, to_text},
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


do_kyc_create(#{<<"business_name">> := BusinessName} = KycData) ->
  do_kyc_create(maps:merge(KycData, #{<<"full_name">> => BusinessName}));

do_kyc_create(
  #{
    <<"full_name">> := FullName,
    <<"email">> := ToEmail,
    <<"refund_address">> := RefundAddress
  } = KycData
) ->
  KycDataJson = jsx:encode(KycData),
  case os:getenv("KYC_SECRET_KEY") of
    false ->
      logger:info("KYC_SECRET_KEY environment variable not set."),
      exit(normal);

    KycKey ->
      EncryptedKyc =
        damage_utils:encrypt(
          KycDataJson,
          base64:decode(list_to_binary(KycKey)),
          crypto:strong_rand_bytes(32)
        ),
      case create(RefundAddress) of
        #{status := <<"ok">>} = Data ->
          Ctxt = maps:merge(Data, KycData),
          damage_utils:send_email(
            {FullName, ToEmail},
            <<"DamageBDD SignUp">>,
            damage_utils:load_template("signup_email.mustache", Ctxt)
          ),
          {ok, _Obj} =
            damage_riak:put(
              {<<"Default">>, <<"kyc">>},
              maps:get(ae_contract_address, Ctxt),
              EncryptedKyc
            ),
          maps:put(
            <<"message">>,
            <<
              "Account created. Please check email for api key to start using DamageBDD."
            >>,
            KycData
          );

        #{status := <<"notok">>} ->
          maps:put(<<"message">>, <<"Account creation failed. .">>, KycData)
      end
  end.


do_action(<<"create_from_yaml">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" yaml data: ~p ", [Data]),
  {ok, [Data0]} = fast_yaml:decode(Data, [maps]),
  do_kyc_create(Data0);

do_action(<<"create_from_json">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt(" json data: ~p ", [Data]),
  Data0 = jsx:decode(Data, [return_maps]),
  do_kyc_create(Data0);

do_action(<<"create">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?debugFmt("Form data ~p", [Data]),
  FormData = maps:from_list(cow_qs:parse_qs(Data)),
  do_kyc_create(FormData);

do_action(<<"balance">>, Req) ->
  #{account := ContractAddress} = cowboy_req:match_qs([account], Req),
  balance(ContractAddress);

do_action(<<"refund">>, Req) ->
  #{account := ContractAddress} = cowboy_req:match_qs([account], Req),
  refund(ContractAddress).


to_json(Req, State) ->
  Result = do_action(cowboy_req:binding(action, Req), Req),
  Body = jsx:encode(Result),
  %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
  %Req =
  %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
  {Body, Req, State}.


to_text(Req, State) -> to_html(Req, State).

to_html(Req, State) ->
  Body =
    damage_utils:load_template("create_account.mustache", #{body => <<"Test">>}),
  {Body, Req, State}.


from_html(Req, State) ->
  Result = do_action(cowboy_req:binding(action, Req), Req),
  Body = damage_utils:load_template("create_account.mustache", Result),
  Resp = cowboy_req:set_resp_body(Body, Req),
  {stop, cowboy_req:reply(200, Resp), State}.


from_json(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_json">>, Req),
  JsonResult = jsx:encode(Result),
  Resp = cowboy_req:set_resp_body(JsonResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_yaml(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_yaml">>, Req),
  YamlResult = fast_yaml:encode(Result),
  Resp = cowboy_req:set_resp_body(YamlResult, Req),
  {stop, cowboy_req:reply(201, Resp), State}.


aecli(contract, call, ContractAddress, Contract, Func, Args) ->
  {ok, AeWallet} = application:get_env(damage, ae_wallet),
  Password = os:getenv("AE_PASSWORD"),
  Cmd =
    mustache:render(
      "aecli contract call --contractSource {{contract_source}} --contractAddress {{contract_address}} {{contract_function}} '{{contract_args}}' {{wallet}} --password={{password}} --json",
      [
        {wallet, AeWallet},
        {password, Password},
        {contract_source, Contract},
        {contract_args, binary_to_list(jsx:encode(Args))},
        {contract_address, ContractAddress},
        {contract_function, Func}
      ]
    ),
  ?debugFmt("Cmd : ~p", [Cmd]),
  Result = exec:run(Cmd, [stdout, stderr, sync]),
  {ok, [{stdout, [AeAccount0]}]} = Result,
  jsx:decode(AeAccount0, [{labels, atom}]).


aecli(contract, deploy, Contract, Args) ->
  {ok, AeWallet} = application:get_env(damage, ae_wallet),
  Password = os:getenv("AE_PASSWORD"),
  Cmd =
    mustache:render(
      "aecli contract deploy {{wallet}} --contractSource {{contract_source}} '{{contract_args}}' --password={{password}} --json ",
      [
        {wallet, AeWallet},
        {password, Password},
        {contract_source, Contract},
        {contract_args, binary_to_list(jsx:encode(Args))}
      ]
    ),
  ?debugFmt("Cmd : ~p", [Cmd]),
  Result0 = exec:run(Cmd, [stdout, stderr, sync]),
  {ok, [{stdout, Result}]} = Result0,
  jsx:decode(binary:list_to_bin(Result), [{labels, atom}]).


create(RefundAddress) ->
  case validate_refund_addr(forward, RefundAddress) of
    {ok, RefundAddress} ->
      ?debugFmt("btc refund address ~p ", [RefundAddress]),
      % create ae account and bitcoin account
      #{result := #{contractId := ContractAddress}} =
        aecli(contract, deploy, "contracts/account.aes", []),
      {ok, BtcAddress} = bitcoin:getnewaddress(ContractAddress),
      ?debugFmt(
        "debug created AE contractid ~p ~p, ",
        [ContractAddress, BtcAddress]
      ),
      ContractCreated =
        aecli(
          contract,
          call,
          binary_to_list(ContractAddress),
          "contracts/account.aes",
          "set_btc_state",
          [BtcAddress, RefundAddress]
        ),
      ?debugFmt("debug created AE contract ~p", [ContractCreated]),
      #{
        status => <<"ok">>,
        btc_address => BtcAddress,
        ae_contract_address => ContractAddress,
        btc_refund_address => RefundAddress
      };

    Other ->
      ?debugFmt("refund_address data: ~p ", [Other]),
      #{status => <<"notok">>, message => <<"Invalid refund_address.">>}
  end.


store_profile(ContractAddress) ->
  % store config schedule etc
  logger:debug("debug ~p", [ContractAddress]),
  ok.


check_spend("guest", _Concurrency) -> ok;
check_spend(<<"guest">>, _Concurrency) -> ok;

check_spend(ContractAddress, _Concurrency) ->
  #{decodedResult := Balance} =
    aecli(
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
    aecli(
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
  logger:debug(Mesg),
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
  {ok, RealBtcBalance} = bitcoin:getreceivedbyaddress(BtcAddress),
  ?debugFmt("real balance ~p ", [RealBtcBalance]),
  {ok, RefundResult} =
    bitcoin:sendtoaddress(
      BtcRefundAddress,
      RealBtcBalance - binary_to_integer(Balance),
      ContractAddress
    ),
  ?debugFmt("Refund result ~p ", [RefundResult]),
  RefundResult.


update_schedules(ContractAddress, JobId, _Cron) ->
  ContractCall =
    aecli(
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
    aecli(
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


%update_schedules(ContractAddress, JobId, Cron)->
%  ContractCreated =
%    aecli(
%      contract,
%      call,
%      binary_to_list(ContractAddress),
%      "contracts/account.aes",
%      "update_schedules",
%      [BtcAddress, RefundAddress]
%    ),
%    ok.
%
%on_payment(Wallet) ->
%    take_fee(Wallet)
%    get_ae(Wallet)
% FROM jrx/b_lib.ts:tx_sign
%        let tx_bytes        : Uint8Array = (await vdk_aeser.unbaseNcheck(tx_str)).bytes;
%        // thank you ulf
%        // https://github.com/aeternity/protocol/tree/fd179822fc70241e79cbef7636625cf344a08109/consensus#transaction-signature
%        // we sign <<NetworkId, SerializedObject>>
%        // SerializedObject can either be the object or the hash of the object
%        // let's stick with hash for now
%        let network_id      : Uint8Array = vdk_binary.encode_utf8('ae_uat');
%        // let tx_hash_bytes   : Uint8Array = hash(tx_bytes);
%        let sign_data       : Uint8Array = vdk_binary.bytes_concat(network_id, tx_bytes);
%        // @ts-ignore yes nacl is stupid
%        let signature       : Uint8Array = nacl.sign.detached(sign_data, secret_key);
%        let signed_tx_bytes : Uint8Array = vdk_aeser.signed_tx([signature], tx_bytes);
%        let signed_tx_str   : string     = await vdk_aeser.baseNcheck('tx', signed_tx_bytes);
%/**
% * RLP-encode signed tx (signatures and tx are both the BINARY representations)
% *
% * See https://github.com/aeternity/protocol/blob/fd179822fc70241e79cbef7636625cf344a08109/serializations.md#signed-transaction
% */
%function
%signed_tx
%    (signatures : Array<Uint8Array>,
%     tx         : Uint8Array)
%    : Uint8Array
%{
%    // tag for signed tx
%    let tag_bytes = vdk_rlp.encode_uint(11);
%    // not sure what version number should be but guessing 1
%    let vsn_bytes = vdk_rlp.encode_uint(1);
%    // result is [tag, vsn, signatures, tx]
%    return vdk_rlp.encode([tag_bytes, vsn_bytes, signatures, tx]);
%}
sign_tx(UTx) ->
  Password = list_to_binary(os:getenv("AE_SECRET_KEY")),
  sign_tx(UTx, Password).


sign_tx(UTx, PrivateKey) ->
  SignData = base64:encode(<<"ae_uat", UTx/binary>>),
  Signature = enacl:sign_detached(SignData, base64:encode(PrivateKey)),
  TagBytes = <<11 : 64>>,
  VsnBytes = <<1 : 64>>,
  {ok, vrlp:encode([TagBytes, VsnBytes, [Signature], UTx])}.


test_contract_call(AeAccount) ->
  JobId = <<"sdds">>,
  {ok, Nonce} = vanillae:next_nonce(AeAccount),
  {ok, ContractData} =
    vanillae:contract_create(AeAccount, "contracts/account.aes", []),
  {ok, sTx} = sign_tx(ContractData),
  ?debugFmt("contract create ~p", [sTx]),
  {ok, AACI} = vanillae:prepare_contract("contracts/account.aes"),
  ContractCall =
    vanillae:contract_call(
      AeAccount,
      Nonce,
      % Amount
      0,
      % Gas
      0,
      % GasPrice
      0,
      % Fee
      0,
      AACI,
      sTx,
      "update_schedule",
      [JobId]
    ),
  ?debugFmt("contract call ~p", [ContractCall]),
  {ok, sTx} = sign_tx(ContractCall),
  case vanillae:post_tx(sTx) of
    {ok, #{"tx_hash" := Hash}} ->
      ?debugFmt("contract call success ~p", [Hash]),
      Hash;

    {ok, WTF} ->
      logger:error("contract call Unexpected result ~p", [WTF]),
      {error, unexpected};

    {error, Reason} ->
      logger:error("contract call error ~p", [Reason]),
      {error, Reason}
  end.
