# dev / 00-networking/nat-schedule — start/stop schedule for the NAT instance.
#
# Runs 10:00-22:00 daily, stopped overnight. Takes the NAT from ~$7.31/mo to
# ~$3.97/mo. Separate from the nat component deliberately: the instance was
# proven to work first, so a future "NAT is broken" cannot be confused with
# "the schedule is broken".
#
# WHILE STOPPED, PRIVATE-SUBNET EGRESS IS DOWN. That is the intent for dev, but
# anything scheduled to run overnight in a private subnet will have no internet.
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # `try`, not a ternary — see the note in infra/root.hcl.
  account_local_path = find_in_parent_folders("account.local.hcl", "")
  account_local      = try(read_terragrunt_config(local.account_local_path).locals, {})
  merged             = merge(local.account, local.account_local)
}

dependency "nat" {
  config_path = "../nat"

  mock_outputs = {
    instance_id = "i-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "kms" {
  config_path = "../../10-security/kms"

  mock_outputs = {
    key_arn = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/scheduler/eventbridge"
}

inputs = {
  name_prefix  = local.env.name_prefix
  instance_ids = [dependency.nat.outputs.instance_id]

  # LOAD-BEARING. Inferred from the workstation running UTC-4 in July. An IANA
  # name rather than a fixed offset so daylight saving is handled by AWS —
  # otherwise the window would drift an hour twice a year and the symptom would
  # be "the environment goes down early in November".
  #
  # Change this one value if the intended local time is different.
  timezone = "America/New_York"

  # 10:00 up, 22:00 down, every day. Six fields:
  #   minute hour day-of-month month day-of-week year
  # day-of-month and day-of-week are mutually exclusive, hence the "?".
  start_cron = "0 10 * * ? *"
  stop_cron  = "0 22 * * ? *"

  # Both rules go DISABLED while the environment is parked (dev/env.hcl), so the
  # NAT stays down with the private-subnet tiers it exists to serve. A stopped
  # EC2 instance never restarts itself, so this is enough — no residual charge
  # beyond its 8 GB root volume.
  enabled = !local.env.parked

  # Encrypts each schedule's target input. The payload here is only an instance
  # id, but the module is reused for application schedules with richer inputs,
  # and encrypting by default beats remembering to turn it on later.
  kms_key_arn = dependency.kms.outputs.key_arn

  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"
}
