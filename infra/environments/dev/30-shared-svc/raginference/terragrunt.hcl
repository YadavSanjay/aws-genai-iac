# dev / 30-shared-svc/raginference — RagInference model server (ECS Fargate).
#
# R6. The shared CPU/ARM64 inference service (BGE-M3 embedder + Jina reranker)
# that MacroRAG and ARag call for embeddings/rerank. Runs the slim image and
# syncs its ~4 GB of weights from S3 at start (MODEL_SOURCE=s3), over the free
# S3 gateway endpoint.
#
# Landed ALWAYS-ON (desired_count = 1, no autoscaling) so it can be verified
# healthy before the scheduled scale-to-zero is added (R7) — the same "schedule
# lands with the working app" lesson as the MacroRAG host.
#
# Reachable through the internal ALB at /raginfer/* once 30-shared-svc/alb wires
# this service's target group as an external target.
#
# Cost: ~$135/mo always-on (4 vCPU / 16 GB ARM64), dropping to ~$45-57/mo once
# R7 puts it on the ~10h/day schedule; ~$0 compute when scaled to zero.
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

  repo_key = "${local.env.name_prefix}/raginference"

  # The ARM64 slim image built from RagInference main @ 9ba317c (the transformers
  # <4.57 pin that fixes the jina-reranker load). A git-SHA tag, never :latest
  # (the repo is IMMUTABLE). Bump this to redeploy a new build.
  image_tag = "slim-arm64-9ba317c"
}

dependency "dns" {
  config_path = "../../00-networking/dns"

  mock_outputs = {
    namespace_id   = "ns-00000000000000000"
    namespace_name = "genai-dev.internal"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "subnets" {
  config_path = "../../00-networking/subnets"

  mock_outputs = {
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "security_groups" {
  config_path = "../../00-networking/security-groups"

  mock_outputs = {
    raginfer_security_group_id = "sg-00000000000000000"
    raginfer_port              = 8799
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
    repository_urls = {
      "genai-dev/raginference" = "000000000000.dkr.ecr.us-east-1.amazonaws.com/genai-dev/raginference"
    }
    repository_arns = {
      "genai-dev/raginference" = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/raginference"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "weights" {
  config_path = "../../20-data/raginference-weights"

  mock_outputs = {
    bucket_id  = "genai-dev-raginference-weights-us-east-1"
    bucket_arn = "arn:aws:s3:::genai-dev-raginference-weights-us-east-1"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/compute/ecs-service"
}

inputs = {
  name_prefix = local.env.name_prefix
  app_name    = "raginference"

  # git-SHA-tagged ARM64 slim image. The URL comes from the ECR dependency so no
  # account id is written into this file.
  image = "${dependency.ecr.outputs.repository_urls[local.repo_key]}:${local.image_tag}"

  # 8 vCPU / 16 GB. Was 4 vCPU, raised 2026-07-29 for QUERY latency, not ingest:
  # jina-reranker-v3 is listwise, so one narrative rerank is a handful of 4096-token
  # forwards of a 0.6B model, and on 4 vCPU that measured over 10 MINUTES — past
  # every client timeout. Rerank throughput is ~linear in vCPU, so this is ~2x, and
  # ARag's prefetch_limit 30->10 takes another ~3x off the token count.
  # Memory stays 16 GB (the 8-vCPU Fargate minimum, and 4 vCPU never approached it).
  # Cost: $0.186 -> $0.316/hr, i.e. ~$56 -> ~$95/mo on the 11-21 schedule (+$39).
  #
  # NOTE: a full-corpus index is CPU-bound (bge-m3 ~6s/text). For a one-time bulk
  # ingest, temporarily bump to 16384/32768 (16 vCPU / 32 GB) and revert afterwards —
  # do NOT commit that bump; steady state is 8/16.
  cpu              = 8192
  memory           = 16384
  cpu_architecture = "ARM64"

  container_port = dependency.security_groups.outputs.raginfer_port

  # Non-secret config only; the model source, bucket and region are not secrets.
  environment = {
    DEPLOY_MODE  = "aws"
    MODEL_SOURCE = "s3"
    MODEL_S3_URI = "s3://${dependency.weights.outputs.bucket_id}"
    HF_HOME      = "/models"
    RERANKER     = "jina"
    EMBEDDER     = "bge"
    AWS_REGION   = local.merged.region
  }

  # Cloud Map service discovery — RagInference resolves at
  # raginference.genai-dev.internal:8799 for in-VPC callers (MacroRAG, ARag). No
  # load balancer; unaffected by the ingress toggle.
  service_discovery_namespace_id   = dependency.dns.outputs.namespace_id
  service_discovery_namespace_name = dependency.dns.outputs.namespace_name

  # The container health check gates Cloud Map registration: a task appears in
  # DNS only once /readyz returns 200 (BOTH models loaded), so callers never
  # resolve a task that is still warming. start_period is 300s — the ECS maximum,
  # and what the RagInference image's own HEALTHCHECK uses. The 3-GB image pull
  # happens BEFORE the container starts (not counted here); what this must cover
  # is the weight sync + warm, which is well under 300s. Uses python (curl was
  # purged from the runtime image).
  container_health_check = {
    command      = ["CMD-SHELL", "python -c 'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen(\"http://127.0.0.1:8799/readyz\",timeout=4).status==200 else 1)' || exit 1"]
    interval     = 30
    timeout      = 5
    retries      = 3
    start_period = 300
  }

  # Private subnets (>=2 AZ). Weight sync is via the S3 gateway endpoint (no NAT,
  # no cross-AZ charge), so placement is a resilience choice, not a cost one.
  subnet_ids         = dependency.subnets.outputs.private_subnet_ids
  security_group_ids = [dependency.security_groups.outputs.raginfer_security_group_id]

  kms_key_arn              = dependency.kms.outputs.key_arn
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"

  # ARN-scoped: the execution role pulls ONLY the raginference repo; the task
  # role reads ONLY the weights bucket.
  ecr_repository_arns   = [dependency.ecr.outputs.repository_arns[local.repo_key]]
  task_read_bucket_arns = [dependency.weights.outputs.bucket_arn]

  # ECS Exec for troubleshooting a Fargate task (there is no SSH).
  enable_execute_command = true

  # R8 observability: CPU + memory alarms (free AWS/ECS metrics). Memory is the
  # one to watch — the 16 GB task size is a right-sizing question, and a task
  # running near the threshold is the evidence to move it. No alarm_actions yet
  # (no ops SNS topic); the alarms are visible/queryable and page nobody until
  # one is wired. Scaled-to-zero emits no datapoints, so missing data is benign.
  enable_alarms          = true
  alarm_cpu_threshold    = 85
  alarm_memory_threshold = 90

  # R7 scheduled scale-to-zero. Application Auto Scaling owns DesiredCount now
  # (min 0, max 1), scaling up at 11:00 and down at 21:00 daily — aligned with
  # the app window and INSIDE the NAT window (10:00-22:00), so the cold-start
  # image pull + logs have egress. First request after scale-up pays a ~5-6 min
  # cold start (batch-tolerant SLO). desired_count is ignored (see the module's
  # ignore_changes); it set the initial always-on capacity, autoscaling drives it
  # from here.
  #
  # PARK MODE (dev/env.hcl). This service is the single largest line item in the
  # environment — an 8 vCPU Fargate task at ~$0.316/hr, about two thirds of the
  # estate's entire daily burn — so parking matters more here than anywhere else.
  #
  # Parking drops the scale-UP action and bounds the scalable target to 0, which
  # is what actually holds it down: Application Auto Scaling enforces the target's
  # max, so a task left running is scaled in rather than waiting for 21:00. The
  # scale-DOWN action is deliberately KEPT as a backstop — it costs nothing and
  # re-asserts zero if anything ever sets DesiredCount by hand.
  #
  # desired_count is 0 rather than 1 while parked so that the service still
  # settles at zero if enable_autoscaling is ever turned off; the module's
  # ignore_changes means it does not fight Auto Scaling either way.
  desired_count            = local.env.parked ? 0 : 1
  enable_autoscaling       = true
  autoscaling_min_capacity = 0
  autoscaling_max_capacity = local.env.parked ? 0 : 1
  scale_up_cron            = local.env.parked ? "" : "cron(0 11 * * ? *)"
  scale_down_cron          = "cron(0 21 * * ? *)"
  schedule_timezone        = "America/New_York"

  # A parked service has no task to reach steady state, and waiting for one would
  # hang the apply.
  wait_for_steady_state = !local.env.parked
}
