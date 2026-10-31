# dev / 90-observability/scheduler-alarms — detection for scheduled start/stop (O2).
#
# The estate runs on schedules: the NAT (10:00-22:00), Qdrant, MacroRAG, ARag and
# Faultline hosts (11:00-21:00), the ARag database (10:45-21:10). Between them
# they make roughly a dozen unattended API calls a day, every one at an hour nobody
# is watching, and a failure leaves no trace anyone reads.
#
# 2026-07-27 is the worked example: `genai-dev-qdrant-stop` fired, the EC2 call was
# refused, TargetErrorCount recorded it, and nothing said so. The infrastructure was
# fine — the detection was missing.
#
# Cost: $0.20/mo (two alarms).
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "alerts" {
  config_path = "../alerts"

  mock_outputs = {
    topic_arn = "arn:aws:sns:us-east-1:000000000000:mock-ops-alerts"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/observability/scheduler-alarms"
}

inputs = {
  name_prefix     = local.env.name_prefix
  alert_topic_arn = dependency.alerts.outputs.topic_arn

  # Every schedule in this estate is created in the default group; the module's
  # variable documents why that costs us per-schedule attribution.
  schedule_group = "default"
}
