# dev / 40-quantlibpricer/app — Faultline application host (Q5).
#
# Private-subnet t4g.large running the three-container compose stack (backend +
# bff + ui), administered only via Session Manager. NO public ingress: the UI is
# reached by an SSM port-forward (ingress_mode = "ssm"), like MacroRAG and ARag.
#
# STATEFUL tier, unlike ARag: the pricing data tree lives on a CMK-encrypted EBS
# data volume mounted into both the backend (rw) and the BFF. The backend runs
# PRICER_DEPLOY_MODE=local against that mount, so behaviour is byte-identical to
# the laptop and the BFF's DuckDB read path works unchanged.
#
# SEEDING IS MANUAL, BY DECISION (2026-07-29). ec2-app's bootstrap syncs the
# deploy BUNDLE only — it has no data-seed step, so a fresh volume comes up empty
# and stays that way until an operator fills it over SSM:
#     sudo aws s3 sync s3://<qlp-data>/data/ /mnt/qlp-data/    # seed
#     sudo aws s3 sync /mnt/qlp-data/ s3://<qlp-data>/data/    # push back
# (the instance role already carries the S3 read+write grant below, so no extra
# credentials are needed). Automating it would mean a new ec2-app input rendered
# into user-data, and user_data_replace_on_change = true makes that REPLACE the
# host — not worth it for a step run rarely, on a volume that already survives
# replacement. Revisit only if the volume starts being rebuilt often.
# Flipping the backend to native S3 (PRICER_DEPLOY_MODE=aws) is a later change and
# is blocked on the BFF read/write path (CL-Q1), not on anything here.
#
# EAST-WEST: this is the first tier that calls ANOTHER APP TIER. It reaches
# arag.genai-dev.internal:8000 and macrorag.genai-dev.internal:8000 over the
# self-referencing app-SG rule (Q4a) and the in-module Cloud Map records (Q4b).
# Nothing calls IT, so it registers no name of its own.
#
# APPLY PREREQUISITES (out of band, before this applies — the bootstrap fails
# loudly on first boot if any is missing):
#   1. Three arm64 images built and pushed to the Q1 repos, with the golden-PV
#      suite green INSIDE the qlp-backend image (CL-Q5).
#   2. genai-dev/qlp/app secret VALUE set (PRICER_API_KEY, QLP_WRITE_TOKEN,
#      OPENAI_API_KEY, FRED_API_KEY — the last two un-prefixed, see CL-Q7).
#   3. Deploy bundle (docker-compose.aws.yml + deploy.env) uploaded to
#      s3://<qlp-data>/deploy/ via scripts/deploy_qlp_bundle.py.
#   4. CL-Q8: the app's compose must forward ARAG_BASE_URL / MACRORAG_BASE_URL /
#      RAGINFER_URL / PRICER_WORKERS to the backend container. They are set in
#      runtime_env below, but today's docker-compose.aws.yml does not pass them
#      through, so scenariogen would silently fall back to localhost.
#
# NO SCHEDULE COMPONENT: per the Q6 re-scope the 11:00-21:00 schedule becomes
# inputs on THIS component once the stack is verified running, so the instance and
# its schedule share one state and the id cannot go stale.
#
# Cost: ~$23.6/mo on the 10h/day schedule (t4g.large + 30 GB root + 10 GB data),
# ~$3.2/mo stopped. Apply as: AWS_PROFILE=genai-tf
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

  # Same AZ as the NAT, Qdrant, RDS and the two RAG app tiers, so east-west
  # traffic stays in one AZ ($0 cross-AZ).
  app_az = "us-east-1a"

  # Host path the data volume mounts at; must match QLP_DATA_MOUNT below, which
  # is what the compose file interpolates for its bind mount.
  data_mount = "/mnt/qlp-data"
}

dependency "subnets" {
  config_path = "../../00-networking/subnets"

  mock_outputs = {
    private_subnet_ids_by_az = { "us-east-1a" = "subnet-00000000000000000" }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "security_groups" {
  config_path = "../../00-networking/security-groups"

  mock_outputs = {
    app_security_group_id = "sg-00000000000000000"
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

dependency "ecr" {
  config_path = "../../20-data/ecr"

  mock_outputs = {
    repository_arns = {
      "genai-dev/qlp-backend" = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/qlp-backend"
      "genai-dev/qlp-bff"     = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/qlp-bff"
      "genai-dev/qlp-ui"      = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/qlp-ui"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "secrets" {
  config_path = "../../10-security/secrets"

  mock_outputs = {
    secret_arns = {
      "genai-dev/qlp/app" = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "data" {
  config_path = "../../20-data/qlp-data"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::genai-dev-qlp-data-us-east-1"
    bucket_id  = "genai-dev-qlp-data-us-east-1"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules//compute/ec2-app"
}

inputs = {
  name_prefix = local.env.name_prefix

  # LOAD-BEARING: the genai-dev/qlp/app secret's reader deny excepts EXACTLY
  # arn:...:role/genai-dev-qlp, and ArnNotLike does not wildcard. Renaming this
  # gives the host a role that cannot read its own credentials, which surfaces
  # as a bootstrap that aborts before the image pull with nothing on disk saying
  # why — how ARag's ingest runner failed.
  app_name = "qlp"

  subnet_id = dependency.subnets.outputs.private_subnet_ids_by_az[local.app_az]
  # Reuses the shared app-tier SG: it already egresses to the shared services and,
  # since Q4a, to the other app tiers on 8000 — which is the whole point here.
  security_group_ids = [dependency.security_groups.outputs.app_security_group_id]

  # Graviton (arm64). 2 vCPU is the VaR constraint, not RAM: the data tree is
  # 36 MB but ql.Settings.evaluationDate is process-global, so full-reval VaR
  # parallelises across PROCESSES and cores are the only lever. Step to
  # t4g.xlarge (~$40/mo scheduled) on measured wall-clock, not on principle.
  instance_type  = "t4g.large"
  root_volume_gb = 30

  # STATEFUL: the live data tree. Small because the tree is 36 MB — this is
  # headroom for DuckDB spill and image layers, not capacity. Survives instance
  # replacement, and the qlp-data bucket is the off-box copy.
  data_volume_gb   = 10
  data_mount_point = local.data_mount

  kms_key_arn              = dependency.kms.outputs.key_arn
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"

  # ARN-scoped to exactly the three repos this host pulls.
  ecr_repository_arns = [
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/qlp-backend"],
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/qlp-bff"],
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/qlp-ui"],
  ]

  secret_arns = [dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/qlp/app"]]

  # READ+WRITE on the data bucket. Used by the OPERATOR's manual seed / push-back
  # over SSM (see the header) — nothing in the bootstrap touches it. The grant is
  # what keeps the box disposable: the tree can always be restored from S3.
  #
  # DELIBERATE, BOUNDED OVER-GRANT: the module scopes S3 by BUCKET, not prefix, so
  # this also covers deploy/ — the host can overwrite the very bundle it boots
  # from. Accepted because the alternative is a second bucket for one small object
  # set, and a host that can already READ its bundle and holds the instance role is
  # inside the same trust boundary either way. Prefix-scoped grants would be a
  # module enhancement; recorded rather than done silently.
  s3_bucket_arns = [dependency.data.outputs.bucket_arn]

  # Containers make no AWS calls in local mode — the S3 seed/sync runs HOST-side
  # from the bootstrap — so the instance role does not need to be reachable
  # through the docker bridge and the hop limit stays at the tighter default.
  # Flipping to PRICER_DEPLOY_MODE=aws (the backend calling S3 itself) requires
  # raising this to 2.
  imds_hop_limit = 1

  # Q6 — the 11:00-21:00 ET window, matching qdrant/macrorag/arag. Lives HERE
  # rather than in a 40-quantlibpricer/app-schedule component so the schedule and
  # the instance share one state: the target is a reference to aws_instance.app.id
  # and is rewritten by the same apply that replaces the host, instead of a copied
  # id that rots (MacroRAG's schedule is orphaned that way today).
  start_cron        = "0 11 * * ? *"
  stop_cron         = "0 21 * * ? *"
  schedule_timezone = "America/New_York"

  # Both crons go DISABLED while the environment is parked (dev/env.hcl). The
  # 10 GB /mnt/data volume holding the EBS live tree is untouched by a stop, so
  # waking up is `parked = false` + apply, not a reseed.
  schedule_enabled = !local.env.parked

  # Deploy bundle under the data bucket's deploy/ prefix, uploaded out of band by
  # scripts/deploy_qlp_bundle.py. Faultline's AWS compose lives at its REPO
  # ROOT, not under infra/docker/ as ARag's and MacroRAG's do.
  compose_bundle_s3_uri = "s3://${dependency.data.outputs.bucket_id}/deploy"
  compose_file_relpath  = "docker-compose.aws.yml"

  # App secret -> the env-file the compose loads via env_file.
  app_env_secret_arn = dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/qlp/app"]
  app_env_file_path  = "/opt/qlp/.env"

  # Per-deploy image tags ride the bundle's deploy.env (cp + restart to bump; no
  # reprovision), same decoupling as MacroRAG and ARag.
  deploy_env_relpath = "deploy.env"

  # Host-STATIC compose env (no credentials). Written to /opt/app/.env and passed
  # as compose's FIRST --env-file, so ${VAR} interpolation in the compose file
  # resolves from here.
  runtime_env = {
    # Local mode against the mounted volume: byte-identical to the laptop, and the
    # BFF's DuckDB readers work unchanged. /app/data is the CONTAINER path; the
    # host side is QLP_DATA_MOUNT below.
    #
    # DO NOT set this to "aws" (with an s3:// PRICER_DATA_URI) until CL-Q10 lands.
    # The BFF DISCARDS a remote URI — ui/bff/app/settings.py does
    # `if uri and "://" not in uri` and otherwise falls back to project_root()/"data"
    # — and its readers are pure local filesystem (Path.glob, duckdb read_parquet on a
    # posix path, st_mtime ordering). The backend would write to S3 while the BFF kept
    # reading a volume nobody writes to: a permanently blank UI that fails SILENTLY,
    # bought at the price of an instance replacement. See the rollout plan, CL-Q10.
    PRICER_DEPLOY_MODE = "local"
    PRICER_DATA_URI    = "/app/data"
    PRICER_ENV         = "dev"
    PRICER_LOG_LEVEL   = "INFO"
    PRICER_JSON_LOGS   = "true"

    # VaR fan-out = vCPUs. Bump with the instance type, never above it.
    PRICER_WORKERS = "2"

    # Compose interpolates these for its bind mount and env_file paths; they must
    # match data_mount_point and app_env_file_path above.
    QLP_DATA_MOUNT = local.data_mount
    QLP_ENV_FILE   = "/opt/qlp/.env"

    # The SSM port-forward origin, NOT an ALB hostname — dev has no load balancer.
    QLP_CORS_ORIGINS = "http://localhost:8080"
    API_UPSTREAM     = "bff:8088"

    # East-west (Q4a + Q4b). Stable Cloud Map names, never private IPs: the record
    # is rewritten by the same apply that replaces the target instance.
    # CL-Q8: today's docker-compose.aws.yml does NOT forward these three to the
    # backend container, so scenariogen would fall back to localhost. Set here so
    # they are live the moment that compose gains the passthrough.
    ARAG_BASE_URL     = "http://arag.${local.env.name_prefix}.internal:8000"
    MACRORAG_BASE_URL = "http://macrorag.${local.env.name_prefix}.internal:8000"
    RAGINFER_URL      = "http://raginference.${local.env.name_prefix}.internal:8799"
  }
}
