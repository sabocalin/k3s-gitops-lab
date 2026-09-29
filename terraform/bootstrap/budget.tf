# #2: the tripwire. Nothing caps spending on this paid account; the budget cannot stop
# anything, it only emails. Any alert means something unplanned is running.
resource "aws_budgets_budget" "monthly" {
  name         = "k3s-gitops-lab-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Actual spend has reached 80% of the budget.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # AWS forecasts the month will end above the budget. Needs some billing history, so
  # it may stay silent during the account's first weeks.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
