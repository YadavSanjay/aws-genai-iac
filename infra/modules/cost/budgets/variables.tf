variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly cost budget in USD. Alerts fire against this."
  type        = number

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than 0."
  }
}

variable "alert_emails" {
  description = <<-EOT
    Email addresses subscribed to cost alerts. Set in the GITIGNORED
    infra/account.local.hcl — personal addresses do not belong in a committed file.
    Each subscription must be confirmed via the emailed link before it delivers.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one alert email is required — a budget nobody is told about is not a guardrail."
  }

  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "alert_emails must all be valid email addresses."
  }
}

variable "actual_thresholds_percent" {
  description = "Percentages of budget at which to alert on ACTUAL spend."
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = alltrue([for t in var.actual_thresholds_percent : t > 0 && t <= 100])
    error_message = "actual_thresholds_percent values must be in (0, 100]."
  }
}

variable "forecast_threshold_percent" {
  description = "Percentage of budget at which to alert on FORECASTED month-end spend."
  type        = number
  default     = 100
}

variable "anomaly_monitor_name" {
  description = <<-EOT
    Name of the per-service Cost Anomaly Detection monitor.

    Deliberately NOT following the <project>-<env>-<component> convention. AWS
    permits exactly ONE dimensional (SERVICE) spend monitor per account, and most
    accounts already carry the auto-created "Default-Services-Monitor". Renaming
    it forces replacement, which discards the trained anomaly baseline (it needs
    ~10 days of history to detect anything). Adopting the existing name lets
    Terraform import and manage it with no destroy.

    Override only for a greenfield account with no default monitor.
  EOT
  type        = string
  default     = "Default-Services-Monitor"
}

variable "anomaly_impact_usd" {
  description = <<-EOT
    Minimum absolute dollar impact before a Cost Anomaly Detection alert fires.
    Too low and daily noise trains you to ignore it; too high and it never fires.
  EOT
  type        = number
  default     = 10

  validation {
    condition     = var.anomaly_impact_usd > 0
    error_message = "anomaly_impact_usd must be greater than 0."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
