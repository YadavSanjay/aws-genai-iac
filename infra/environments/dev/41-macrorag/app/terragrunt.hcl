# dev / 41-macrorag/app — MacroRAG application host.
#
# Private-subnet t4g.large running the MacroRAG docker-compose stack (ui + api +
# redis + otel), administered only via Session Manager. NO public ingress: the
# UI is reached by an SSM port-forward to :8080 (ingress_mode = "ssm"; the shared
# ALB was retired). It calls the shared Qdrant (TLS) and RagInference (HTTP) over
# Cloud Map, reads/writes its corpus on S3, and reads its secret from Secrets
# Manager — all via the instance role.
#
# The bootstrap (compute/ec2-app, M5) mounts the data volume, syncs the deploy
# bundle from S3, renders the secret env-file, and runs `docker compose up` as a
# per-boot systemd unit. Applying a user_data change REPLACES the instance; the
# data volume is a separate resource and survives.
#
# NO SCHEDULE COMPONENT YET: it lands (41-macrorag/app-schedule, M7) only once the
# stack is verified running, so a scheduled start cannot bill for a broken app.
#
# Cost: ~$51.46/mo running 24x7, ~$22.56/mo on the 10h/day schedule, ~$4.00/mo
# stopped (30 GB root + 20 GB data EBS floor).
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

  # Same AZ as the NAT instance, so egress does not cross an availability zone
  # at $0.01/GB in each direction.
  app_az = "us-east-1a"

  # Image tags are NOT here anymore — they live in the deploy bundle's deploy.env
  # (this dir), so bumping one does not touch Terraform. See deploy_env_relpath.
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
      "genai-dev/macrorag"       = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/macrorag"
      "genai-dev/macrorag-ui"    = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/macrorag-ui"
      "genai-dev/redis"          = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/redis"
      "genai-dev/otel-collector" = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/otel-collector"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "secrets" {
  config_path = "../../10-security/secrets"

  mock_outputs = {
    secret_arns = {
      "genai-dev/macrorag/app" = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "corpus" {
  config_path = "../../20-data/macrorag-corpus"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::genai-dev-macrorag-corpus-us-east-1"
    bucket_id  = "genai-dev-macrorag-corpus-us-east-1"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules//compute/ec2-app"
}

inputs = {
  name_prefix = local.env.name_prefix
  app_name    = "macrorag"

  subnet_id          = dependency.subnets.outputs.private_subnet_ids_by_az[local.app_az]
  security_group_ids = [dependency.security_groups.outputs.app_security_group_id]

  # Graviton. Confirmed the MacroRAG image builds for arm64 — a mismatched image
  # fails at container start with "exec format error", not at deploy time.
  #
  # RIGHT-SIZED to t4g.small (2 vCPU / 2 GB) from the original t4g.large: embedding
  # is offloaded to RagInference (no torch/models in-process), so the host just
  # orchestrates I/O — measured ~1.3% CPU average, ~14% peak, even during a full
  # index. 2 GB fits steady-state query serving. A full RE-INDEX is the memory
  # high-water mark (chunk batches + timeseries build); bump the type temporarily
  # for a bulk re-index (like the RagInference vCPU bump), then drop back here.
  instance_type = "t4g.small"

  # OS + container images. Billed while stopped, so it is part of the floor of
  # this instance's monthly cost.
  root_volume_gb = 30

  # Dedicated data volume for the SQLite stores (timeseries + ingest cache),
  # traces and eval — mounted at /mnt/macrorag-data by the bootstrap (M5). Kept
  # OFF the root so it survives an instance replacement (a right-size of the
  # oversized t4g.large is expected). 20 GB per the MacroRAG deployment plan §4.2;
  # also billed while stopped, so it adds to the EBS floor.
  data_volume_gb = 20

  kms_key_arn              = dependency.kms.outputs.key_arn
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"

  # ARN-scoped to the FOUR repositories this host actually pulls — its own app +
  # UI images and the two mirrored sidecars — not every repo in the shared ECR
  # component (which also holds raginference + qdrant). Least privilege: the role
  # can pull only what its compose stack runs.
  ecr_repository_arns = [
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/macrorag"],
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/macrorag-ui"],
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/redis"],
    dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/otel-collector"],
  ]
  # ONLY MacroRAG's own secret — not values(...) of the whole secrets component,
  # which now also holds qdrant/app and arag/app and would grant this role read on
  # both (a cross-subsystem leak). Scope to the one secret this host consumes.
  secret_arns = [dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/macrorag/app"]]

  # Corpus object store (raw/processed/manifest) — ARN-scoped read+write. boto3
  # uses the instance role, no keys on disk. SQLite/traces are on the EBS data
  # volume (M2), NOT here.
  s3_bucket_arns = [dependency.corpus.outputs.bucket_arn]

  # --- Runtime (M5): the compose stack ---------------------------------------
  # The app container runs boto3 (corpus S3) and reaches the instance role
  # THROUGH the docker bridge, one hop past the host — so IMDS hop-limit is 2,
  # not the default 1. The instance role is tightly ARN-scoped, which is the
  # compensating control for opening that hop.
  imds_hop_limit = 2

  # Compose mounts durable state at /mnt/macrorag-data (matches the data volume).
  data_mount_point = "/mnt/macrorag-data"

  # 11:00-21:00 ET. RETROFITTED from the separate 41-macrorag/app-schedule
  # component (deleted with this change): that one stored a COPY of the instance
  # id, so the 07-27 reprovision left it driving a terminated host until someone
  # re-applied it. Here the target is aws_instance.app.id, rewritten by the same
  # apply that replaces the instance. Same schedule names, same window — the only
  # thing that changes is which state owns them.
  start_cron        = "0 11 * * ? *"
  stop_cron         = "0 21 * * ? *"
  schedule_timezone = "America/New_York"

  # Both crons go DISABLED while the environment is parked (dev/env.hcl). The
  # 20 GB data volume carrying the built index survives the stop, so a wake-up
  # does not re-index the corpus.
  schedule_enabled = !local.env.parked

  # In-VPC name macrorag.genai-dev.internal:8000, so Faultline's scenariogen
  # can set MACRORAG_BASE_URL to a stable host instead of a private IP that
  # changes whenever this instance is replaced (Q4b). Registration lives in the
  # ec2-app module, i.e. in THIS component's state, so the record is rewritten by
  # the same apply that replaces the instance — no second component to re-apply.
  service_discovery_namespace_id   = dependency.dns.outputs.namespace_id
  service_discovery_namespace_name = dependency.dns.outputs.namespace_name

  # Deploy bundle (compose file + rag.aws.yaml + otel config) lives under the
  # corpus bucket's deploy/ prefix, uploaded by scripts/deploy_macrorag_bundle.py.
  compose_bundle_s3_uri = "s3://${dependency.corpus.outputs.bucket_id}/deploy"
  compose_file_relpath  = "infra/docker/docker-compose.aws.yml"

  # The app secret is rendered VERBATIM to the compose env_file path (KEY=value
  # lines). This must match the compose service's env_file: default.
  app_env_secret_arn = dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/macrorag/app"]
  app_env_file_path  = "/opt/macrorag/.env"

  # Per-DEPLOY env-file with the ECR image tags. It lives in the S3 deploy bundle
  # (deploy.env), NOT user-data — so bumping an image is "edit deploy.env, re-run
  # scripts/deploy_macrorag_bundle.py, restart app.service", with no instance
  # replacement and no IAM change. The committed template is deploy.env in this
  # dir; the script fills in the registry and uploads it.
  deploy_env_relpath = "deploy.env"

  # Host-STATIC compose env (changes rarely; lives in user-data): shared-service
  # endpoints (Qdrant TLS, RagInference plain HTTP) and the corpus bucket. NO
  # credentials here.
  runtime_env = {
    MACRORAG_S3_BUCKET = dependency.corpus.outputs.bucket_id
    MACRORAG_S3_PREFIX = "corpus"

    MACRORAG_QDRANT_URL = "https://qdrant.${local.env.name_prefix}.internal:6333"
    RAGINFER_URL        = "http://raginference.${local.env.name_prefix}.internal:8799"

    # Point the compose env_file at the rendered secret (matches app_env_file_path).
    MACRORAG_ENV_FILE = "/opt/macrorag/.env"
  }
}
