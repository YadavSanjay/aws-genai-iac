# dev / 20-data/ecr — container repositories.
#
# Phase 2 + R1 + A1 + Q1. MacroRAG's two repositories, RagInference's single repo
# (the slim ARM64 inference image — R1 of the RagInference rollout), ARag's three
# (A1 of the ARag rollout), and Faultline's three (Q1). All four subsystems
# now have their repositories; adding another is a single list entry.
#
# Creating a repository does NOT push an image — these are empty until a build
# lands, and an empty repository costs $0. RagInference's image is built and
# pushed separately, right before its Fargate service applies.
#
# Cost: $0.10/GB-month, bounded by the lifecycle policy. Expect ~$0.30-0.60/mo
# once images are pushed; $0 until then.
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "kms" {
  config_path = "../../10-security/kms"

  mock_outputs = {
    key_arn = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/registry/ecr"
}

inputs = {
  repositories = [
    "${local.env.name_prefix}/macrorag",
    "${local.env.name_prefix}/macrorag-ui",
    "${local.env.name_prefix}/raginference",
    # Shared Qdrant. We mirror the upstream qdrant/qdrant arm64 image here rather
    # than pull from Docker Hub at boot: the pull then rides the free S3 gateway
    # endpoint (no NAT dependency, no Docker Hub rate limit) and the exact image
    # is pinned in-account by digest. See qdrant §6a.
    "${local.env.name_prefix}/qdrant",
    # MacroRAG compose sidecars, mirrored for the SAME reason as qdrant above:
    # the boot-time pull rides the free S3 gateway endpoint (no NAT dependency,
    # no Docker Hub rate limit) and the exact image is pinned in-account. Both
    # are pushed as arm64 with a fixed version tag (never :latest), so the
    # immutable-tag policy is a reliable record of what runs.
    "${local.env.name_prefix}/redis",
    "${local.env.name_prefix}/otel-collector",
    # ARag subsystem (A1 of the ARag rollout — docs/design/arag-rollout-plan.md).
    # Three images: the slim torch-free serving image (api + mcp), the nginx UI,
    # and the full ingest image (Arelle + JRE + boto3). Empty until built; the
    # repos cost $0 until an image is pushed.
    "${local.env.name_prefix}/arag",
    "${local.env.name_prefix}/arag-ui",
    "${local.env.name_prefix}/arag-ingest",
    # Faultline subsystem (Q1 of the Faultline rollout —
    # docs/design/quantlibpricer-rollout-plan.md). Three images, all arm64: the
    # QuantLib backend (one image serving every subsystem entrypoint — pricer API,
    # marketdata, risk, scenariogen, sizing, governance), the QuantLib-free BFF,
    # and the nginx SPA. Empty until built; the repos cost $0 until a push.
    "${local.env.name_prefix}/qlp-backend",
    "${local.env.name_prefix}/qlp-bff",
    "${local.env.name_prefix}/qlp-ui",
  ]

  kms_key_arn = dependency.kms.outputs.key_arn

  # IMMUTABLE: a pushed tag can never be repointed at different content, so a
  # deployed tag is a reliable record of what is running. Requires per-build
  # tags (git SHA) rather than a rolling :latest.
  image_tag_mutability = "IMMUTABLE"

  # dev: keep history short. Layers are shared between builds so this is
  # cheaper than it looks, but the bound is what stops silent growth.
  keep_tagged_images   = 5
  untagged_expiry_days = 3
}
