Damage BDD
==========

An Erlang OTP application to run bdd load tests at scale.
Inspired by [https://github.com/behave/behave](behave).

Configure
---------

1. Edit `configs/damage.config` runner config.

   ```
    %%-*-erlang-*- 
    {url, "http://localhost:8000"}.
    {extension, "feature"}.
    {context_yaml, "config/damage.yaml"}.
    {deployment, local}.
    {stop, true}.
    {feature_dir, "features"}.
   ```

2. Edit `damage.yaml` for context data.
   ```
   deployments:
     local:
       variable1: value1
     remote:
       variable1: value1
   ```
3. Create features in `feature_dir` [default: ./features]

Run
-----

    $ rebar3 shell
    > damage:execute("test")


HTTP Steps
---------

Make a simple http GET request and verify results.
```
Feature: Asyncmind server
  Scenario: root
    When I make a GET request to "/"
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
```

Make a simple http POST request with post data in body.

```
I make a POST request to "/some/path"
{
   "data1": "value1", 
   "data2": "value2"
}
Then the response status must be "202"
```

DamageBDD Service
-----------------

You can use the server at https://run.damagebdd.com to run tests

    curl -vvv --data-binary @features/google.feature -H "Authorization: guest" 'https://run.damage.com/api/execute_feature'
