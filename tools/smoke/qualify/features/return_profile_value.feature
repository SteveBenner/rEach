Feature: Looking up one profile setting

  @backend @cafe
  Scenario: Requesting target_margin returns the cafe's target margin with status ok
    Given the profile holds "target_margin" as "0.32"
    When I call "context.return_profile_value" with:
      """
      {"key": "target_margin"}
      """
    Then the call succeeds
    And the result "status" is "ok"
    And the result "value" is "0.32"

  @backend @agency
  Scenario: Requesting an unknown key returns not_found
    Given the profile holds "target_margin" as "0.32"
    When I call "context.return_profile_value" with:
      """
      {"key": "favourite_colour"}
      """
    Then the call succeeds
    And the result "status" is "not_found"
    And the result "value" is null

  @backend @shop
  Scenario: A key typed with capitals and spaces resolves to the same value
    Given the profile holds "monthly_revenue" as "42000"
    When I call "context.return_profile_value" with:
      """
      {"key": "  Monthly_Revenue "}
      """
    Then the call succeeds
    And the result "key" is "monthly_revenue"
    And the result "value" is "42000"

  @backend @cafe
  Scenario: A setting of zero is still found
    Given the profile holds "discount_floor" as the number 0
    When I call "context.return_profile_value" with:
      """
      {"key": "discount_floor"}
      """
    Then the call succeeds
    And the result "status" is "ok"
