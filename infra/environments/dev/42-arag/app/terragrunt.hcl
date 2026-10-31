# dev / 42-arag/app — ARag application host (A6).
#
# Private-subnet t4g.small running the ARag docker-compose stack (ui + api + mcp),
# administered only via Session Manager. NO public ingress: the UI is reached by an
# SSM port-forward (ingress_mode = "ssm"), like MacroRAG. It reads facts from RDS
# (TLS) and narrative from the shared Qdrant (TLS), calls RagInference (HTTP) over
# Cloud Map, and reaches OpenAI over the NAT — all via the instance role.
#
# STATELESS tier: the query path is filesystem-free (facts in RDS, vectors in
# Qdrant), so there is NO data volume and NO read/write S3 grant. The only S3 need
# is a READ-ONLY pull of the deploy bundle (bundle_read_bucket_arn), which rides
# the filings bucket's deploy/ prefix.
#
# CREDENTIALS, two sources, both fetched host-side by the ec2-app bootstrap (the
# slim serving image is boto3-free, so the container cannot fetch its own secrets):
#   - genai-dev/arag/app  -> rendered VERBATIM to /opt/arag/.env (OPENAI/JINA keys).
#   - the RDS-managed secret (db_secret_arn) -> APPENDED to /opt/arag/.env as
#     DB_USERNAME / DB_PASSWORD. Re-fetched every boot, so a rotated DB password is
#     picked up by `systemctl restart app.service` — no image rebuild, no reprovision.
#
# COMPOSE CONTRACT (ARag's docker-compose.aws.yml, in the deploy bundle): the app
# reads XBRL_DB_*. The bootstrap writes XBRL_DB_USER/XBRL_DB_PASSWORD directly into
# /opt/arag/.env (via db_secret_env_map below) and XBRL_DB_HOST/PORT/NAME come from
# runtime_env, so the compose service needs nothing special beyond
# `env_file: /opt/arag/.env` (which it already uses for the OPENAI/JINA keys). No
# compose-level remapping — the container reads the final names straight from env.
#
# APPLY PREREQUISITES (out of band, before this applies):
#   1. arag + arag-ui images built (arm64) and pushed to their ECR repos.
#   2. genai-dev/arag/app secret value set (OPENAI_API_KEY, JINA_API_KEY).
#   3. The deploy bundle (docker-compose.aws.yml + deploy.env) uploaded to
#      s3://<filings-bucket>/deploy/.
#   4. RDS DDL bootstrapped (A7) for the app to serve real queries (it will start
#      without it, but queries fail until the schema + data exist).
# The bootstrap fails loudly on first boot if the bundle or a secret is missing.
#
# NOTE: this reuses compute/ec2-app; the db_secret_arn support was added there, so
# landing this REPROVISIONS the MacroRAG host too (benign — identical behavior with
# its db_secret_arn empty). Reprovision + SSM-verify MacroRAG in the same window.
#
# NO SCHEDULE COMPONENT YET: it lands (42-arag/app-schedule, A8) only once the stack
# is verified running.
#
# Cost: ~$22.56/mo on the 10h/day schedule (t4g.small + 30 GB root), ~$4.00/mo
# stopped. Apply as: AWS_PROFILE=genai-tf
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

  # Same AZ as the NAT, Qdrant and RDS, so east-west traffic stays in one AZ ($0).
  app_az = "us-east-1a"
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

dependency "dns" {
  config_path = "../../00-networking/dns"

  mock_outputs = {
    namespace_id   = "ns-mock000000000000"
    namespace_name = "genai-dev.internal"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "ecr" {
  config_path = "../../20-data/ecr"

  mock_outputs = {
    repository_arns = {
      "genai-dev/arag"    = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/arag"
      "genai-dev/arag-ui" = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/arag-ui"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "secrets" {
  config_path = "../../10-security/secrets"

  mock_outputs = {
    secret_arns = {
      "genai-dev/arag/app" = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "filings" {
  config_path = "../../20-data/arag-filings"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::genai-dev-arag-filings-us-east-1"
    bucket_id  = "genai-dev-arag-filings-us-east-1"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "db" {
  config_path = "../db"

  mock_outputs = {
    address                = "genai-dev-arag.mock.us-east-1.rds.amazonaws.com"
    port                   = 5432
    db_name                = "xbrl_db"
    master_user_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds!db-mock"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules//compute/ec2-app"
}

inputs = {
  name_prefix = local.env.name_prefix
  app_name    = "arag"

  subnet_id = dependency.subnets.outputs.private_subnet_ids_by_az[local.app_az]
  # ARag reuses the shared app-tier SG (already egresses to Qdrant, RagInference
  # and RDS, all of which admit it) — the same group MacroRAG uses.
  security_group_ids = [dependency.security_groups.outputs.app_security_group_id]

  # Graviton (arm64). The serving image offloads embedding/rerank to RagInference
  # and the LLM to OpenAI, so the host just orchestrates I/O — t4g.small is ample;
  # scale up on measured load.
  instance_type  = "t4g.small"
  root_volume_gb = 30

  # STATELESS: no data volume. Facts live in RDS, vectors in Qdrant.
  data_volume_gb = 0

  kms_key_arn              = dependency.kms.outputs.key_arn
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"

  # ARN-scoped to the TWO repos this host pulls (api+mcp share the arag image; the
  # UI is arag-ui). No redis/otel sidecars in the ARag stack.
  ecr_repository_arns = [
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/arag"],
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/arag-ui"],
  ]

  # App secret (OPENAI/JINA), rendered verbatim to the env-file below.
  secret_arns = [dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/arag/app"]]

  # RDS-managed master-user secret (JSON {username,password}). The bootstrap writes
  # its fields into /opt/arag/.env under the names ARag's code reads, so no compose
  # remapping is needed. Read grant is added automatically by the module.
  db_secret_arn = dependency.db.outputs.master_user_secret_arn
  db_secret_env_map = {
    username = "XBRL_DB_USER"
    password = "XBRL_DB_PASSWORD"
  }

  # NO read/write data bucket. Read-only pull of the deploy bundle only, from the
  # filings bucket's deploy/ prefix.
  bundle_read_bucket_arn = dependency.filings.outputs.bucket_arn

  # The slim serving container makes NO AWS calls (boto3-free), so it does not need
  # instance-role creds through the docker bridge — IMDS hop stays at the default 1.
  imds_hop_limit = 1

  # 11:00-21:00 ET. RETROFITTED from the separate 42-arag/app-schedule component
  # (deleted with this change): that one stored a COPY of the instance id, so a
  # reprovision left it driving a terminated host until someone re-applied it.
  # Here the target is aws_instance.app.id, rewritten by the same apply that
  # replaces the instance. Same schedule names, same window — the only thing that
  # changes is which state owns them. The database has its own, slightly wider
  # window (42-arag/db, 10:45-21:10) so it is up before the app and down after.
  start_cron        = "0 11 * * ? *"
  stop_cron         = "0 21 * * ? *"
  schedule_timezone = "America/New_York"

  # Both crons go DISABLED while the environment is parked (dev/env.hcl). ARag's
  # state lives in RDS and Qdrant rather than on this host, and both are parked
  # alongside it, so the ingested filings are still there on wake-up.
  schedule_enabled = !local.env.parked

  # In-VPC name arag.genai-dev.internal:8000, so Faultline's scenariogen can
  # set ARAG_BASE_URL to a stable host instead of a private IP that changes
  # whenever this instance is replaced (Q4b). Registration lives in the ec2-app
  # module, i.e. in THIS component's state, so the record is rewritten by the same
  # apply that replaces the instance — no second component to re-apply.
  service_discovery_namespace_id   = dependency.dns.outputs.namespace_id
  service_discovery_namespace_name = dependency.dns.outputs.namespace_name

  # Deploy bundle (compose file + deploy.env) under the filings bucket's deploy/
  # prefix, uploaded out of band before apply.
  compose_bundle_s3_uri = "s3://${dependency.filings.outputs.bucket_id}/deploy"
  compose_file_relpath  = "infra/docker/docker-compose.aws.yml"

  # App secret -> compose env_file. The DB secret is appended to this same file.
  app_env_secret_arn = dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/arag/app"]
  app_env_file_path  = "/opt/arag/.env"

  # Per-deploy image tags ride the bundle's deploy.env (cp + restart to bump; no
  # reprovision), same decoupling as MacroRAG.
  deploy_env_relpath = "deploy.env"

  # Host-STATIC compose env (no credentials): deploy mode, DB host/port/name (the
  # user + password come from the DB secret), and the shared-service endpoints.
  runtime_env = {
    ARAG_DEPLOY_MODE = "aws"

    XBRL_DB_HOST    = dependency.db.outputs.address
    XBRL_DB_PORT    = tostring(dependency.db.outputs.port)
    XBRL_DB_NAME    = dependency.db.outputs.db_name
    XBRL_DB_SSLMODE = "require"

    QDRANT_HOST = "qdrant.${local.env.name_prefix}.internal"
    QDRANT_PORT = "6333"
    # TLS on, but skip verification: the shared Qdrant fronts a self-signed cert
    # (CN qdrant.<ns>.internal). The client honors QDRANT_VERIFY (ARag repo change).
    QDRANT_HTTPS  = "true"
    QDRANT_VERIFY = "false"

    RAGINFER_URL = "http://raginference.${local.env.name_prefix}.internal:8799"
    # 8 minutes. A narrative rerank is a listwise pass over the prefetched chunks on
    # CPU Fargate, and 300s was not enough even after the 8-vCPU + prefetch_limit=10
    # changes left headroom — this is the backstop, not the expected latency.
    # MUST stay BELOW the UI's nginx proxy_read_timeout (ARAG_PROXY_READ_TIMEOUT,
    # default 600s) so the app's own timeout fires first and the browser gets the
    # app's error rather than an opaque 504.
    RAGINFER_TIMEOUT_S = "480"

    # Point the compose env_file at the rendered secret (matches app_env_file_path).
    ARAG_ENV_FILE = "/opt/arag/.env"
  }
}
