# AWS sends security, abuse and billing notices to the root email by default. The root
# address is not monitored, so route those three categories to one that is.
resource "aws_account_alternate_contact" "this" {
  for_each = toset(["BILLING", "OPERATIONS", "SECURITY"])

  alternate_contact_type = each.key
  name                   = var.alert_name
  title                  = "Owner"
  email_address          = var.alert_email
  phone_number           = var.alert_phone
}
