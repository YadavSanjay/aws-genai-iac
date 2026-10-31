# dev / 30-shared-svc/qdrant-schedule — start/stop schedule for the Qdrant host.
#
# Chunk E. Runs Qdrant 11:00-21:00 ET (the app window), stopped overnight —
# INSIDE the NAT window (10:00-22:00) so a scheduled start still has egress if it
# ever needs it. A scheduled start does NOT re-bootstrap: cloud-init ran once on
# first boot; systemd (qdrant.service) brings the container back from the cached
# image, and the instance keeps its private IP across stop/start so the Cloud Map
# record stays valid.
#
# Separate component from data/qdrant, and lands AFTER the host is verified
# healthy always-on — the same "schedule lands with the working service" lesson
# as the MacroRAG host and RagInference. Uses workload="qdrant" so its schedule
# and role names do not collide with the NAT's (workload="instance").
#
# Cost: this is what takes Qdrant from ~24x7 to ~10h/day (design §6a).
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

dependency "qdrant" {
  config_path = "../qdrant"

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
  workload     = "qdrant"
  instance_ids = [dependency.qdrant.outputs.instance_id]

  # America/New_York, matching the NAT and app windows. IANA name so DST is
  # handled by AWS (see the eventbridge module's timezone note).
  timezone   = "America/New_York"
  start_cron = "0 11 * * ? *"
  stop_cron  = "0 21 * * ? *"

  # Disabled while the environment is parked (dev/env.hcl). Qdrant's collections
  # live on a CMK-encrypted EBS data volume that survives the stop untouched, so
  # parking costs nothing but the volume and loses no vectors.
  enabled = !local.env.parked

  kms_key_arn              = dependency.kms.outputs.key_arn
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"
}
