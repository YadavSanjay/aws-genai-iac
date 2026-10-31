# dev / 42-arag/db — ARag PostgreSQL database (A4).
#
# ARag's xbrl_db: facts, registries, materialized views, and the audit schema.
# The one net-new infra piece the ARag rollout adds — MacroRAG stays on SQLite,
# ARag owns the single RDS Postgres (docs/design/aws-service-consolidation.md §3,
# docs/design/arag-rollout-plan.md A4).
#
# Lands with ingress from the app tier already wired (networking/security-groups
# rds group), but the DB is EMPTY until the one-time DDL bootstrap runs on the
# ingest runner (A7): scripts/ddl/* then rebuild_mvs.py against this endpoint.
#
# The master password is NOT here and never in state: manage_master_user_password
# keeps it in an AWS-managed, CMK-encrypted, rotating Secrets Manager secret. The
# app + ingest roles read it from master_user_secret_arn (module output) at runtime.
#
# Cost: ~$5.05/mo (db.t4g.micro single-AZ on the 10:45-21:10 schedule below; it
# would be ~$11.70 running 24x7) + ~$2.30/mo for 20 GB gp3, which bills whether
# the instance is up or not. Apply as: AWS_PROFILE=genai-tf
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

dependency "subnets" {
  config_path = "../../00-networking/subnets"

  mock_outputs = {
    private_subnet_ids = ["subnet-00000000000000000", "subnet-11111111111111111"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "security_groups" {
  config_path = "../../00-networking/security-groups"

  mock_outputs = {
    rds_security_group_id = "sg-00000000000000000"
    rds_port              = 5432
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
  source = "${get_repo_root()}/infra/modules/data/rds"
}

inputs = {
  name = "${local.env.name_prefix}-arag"

  # DB subnet group spans every private subnet (>=2 AZs, an RDS requirement even
  # single-AZ). The instance itself runs in one AZ until multi_az is set.
  subnet_ids             = dependency.subnets.outputs.private_subnet_ids
  vpc_security_group_ids = [dependency.security_groups.outputs.rds_security_group_id]

  kms_key_arn = dependency.kms.outputs.key_arn

  db_name         = "xbrl_db"
  master_username = "arag_admin"

  # dev sizing: smallest Graviton class, small gp3 with autoscaling headroom. The
  # XBRL dataset is tens of MB; scale up on measured load, not up front.
  instance_class    = "db.t4g.micro"
  engine_version    = "16"
  allocated_storage = 20

  # dev posture (each flips for prod via the module inputs): single-AZ, no
  # deletion protection, skip the final snapshot. skip_final_snapshot is safe here
  # ONLY because the DB is derived state — facts + MVs re-ingest from the durable
  # S3 filings, so a lost dev DB costs a re-ingest, not data.
  multi_az            = false
  deletion_protection = false
  skip_final_snapshot = true

  backup_retention_days = 7
  log_retention_days    = 7

  # Scheduled stop/start — the last always-on line item in the dev estate.
  #
  # The window BRACKETS the app window (11:00-21:00 ET) rather than matching it.
  # Matching 11:00 exactly would hand the app tier a database that is still
  # starting, and matching 21:00 would race the stop against a live host.
  #
  # The 15-minute lead is measured, not guessed: a fire test on 2026-07-29 took
  # 8m08s from the schedule firing to `available` (starting 14:42:43 -> rebooting
  # 14:49:05, RDS applying pending parameters -> available 14:50:51). A 10-minute
  # lead would have held that day with 2 minutes to spare, which is not enough
  # margin for a start that also has to apply a parameter change.
  #
  # In this component rather than a sibling 42-arag/db-schedule, deliberately: a
  # schedule that lives beside the resource it targets holds a copy of its
  # identifier and rots (see the note in 42-arag/app-schedule). Here the target is
  # a reference inside the same state.
  #
  # An off-window ingest run needs the database started by hand first:
  #   AWS_PROFILE=genai-tf aws rds start-db-instance --db-instance-identifier genai-dev-arag
  # Cost: ~$11.70/mo (24x7) to ~$5.05/mo (~10.3h/day), about -$6.65/mo. Parked
  # (stop-only, below) it is ~$0.40/mo of compute — a few hours once a week after
  # each seven-day force-start. Storage (~$2.30/mo for 20 GB gp3) and backups bill
  # whether the instance is up or not, and parking does not change that.
  #
  # PARK MODE (dev/env.hcl) drops the START and keeps the STOP. This is the one
  # tier where parking is NOT `schedule_enabled = false`, and the difference is
  # not cosmetic: RDS force-starts a stopped instance after seven days. Disable
  # both rules and the database is back up on day 8 with nothing left to put it
  # down, billing 24x7 for the rest of the park — the exact opposite of the
  # intent, and silent. A daily stop with no start re-parks it within hours.
  #
  # The module accepts stop-without-start deliberately; start-without-stop is
  # still rejected at plan time. See infra/modules/data/rds/README.md.
  start_cron        = local.env.parked ? null : "45 10 * * ? *"
  stop_cron         = "10 21 * * ? *"
  schedule_timezone = "America/New_York"
  schedule_enabled  = true

  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"
}
