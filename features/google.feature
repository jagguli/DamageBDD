Feature: Test basic functionality of Google.com using HTTP API

  Scenario: GET request to Google.com
    Given I am using server "https://www.google.com"
    When I make a GET request to "/search?q=bdd"
    Then the response must contain text "behaviour driven development"
