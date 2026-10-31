# dev / 30-shared-svc/qdrant — shared Qdrant vector store (EC2).
#
# Chunk D. The shared vector store for MacroRAG + ARag (separate collections),
# self-hosted on a dedicated t4g.small in us-east-1a with a separate EBS data
# volume. Reached in-VPC at qdrant.genai-dev.internal:6333 over TLS + API key —
# NOT co-located in an app host, because it is shared by two subsystems and must
# not inherit one consumer's restart domain. Analysis + decision:
# docs/design/qdrant-cloud-vs-self-hosted.md §6a.
#
# Lands ALWAYS-ON (no schedule) so it can be verified healthy before the
# scheduled stop/start is added (chunk E) — the same "schedule lands with the
# working service" lesson as the MacroRAG host and RagInference.
#
# PREREQUISITES (out of band, before this applies):
#   1. The qdrant image is mirrored into ECR (20-data/ecr repo genai-dev/qdrant).
#   2. The genai-dev/qdrant/app secret has its {api_key} value set.
# The instance's bootstrap fails loudly on first boot if either is missing.
#
# Cost: ~$8/mo (t4g.small ~10h/day + 40 GB gp3). Apply as: AWS_PROFILE=genai-tf
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

  repo_key = "${local.env.name_prefix}/qdrant"

  # The mirrored arm64 image tag. The ECR repo is IMMUTABLE, so a version tag is
  # a reliable pin; switch to "@sha256:<digest>" for full digest pinning once the
  # mirror push reports it. Bump to redeploy a new build.
  image_tag = "v1.18.2"

  # Same AZ as the NAT instance and the MacroRAG host, so every vector query and
  # ingest write is same-AZ ($0 transfer) and off the NAT path.
  app_az = "us-east-1a"
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
    private_subnet_ids_by_az = { "us-east-1a" = "subnet-00000000000000000" }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "security_groups" {
  config_path = "../../00-networking/security-groups"

  mock_outputs = {
    qdrant_security_group_id = "sg-00000000000000000"
    qdrant_rest_port         = 6333
    qdrant_grpc_port         = 6334
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
      "genai-dev/qdrant" = "000000000000.dkr.ecr.us-east-1.amazonaws.com/genai-dev/qdrant"
    }
    repository_arns = {
      "genai-dev/qdrant" = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/qdrant"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "secrets" {
  config_path = "../../10-security/secrets"

  mock_outputs = {
    secret_arns = {
      "genai-dev/qdrant/app" = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/data/qdrant"
}

inputs = {
  name_prefix = local.env.name_prefix

  subnet_id          = dependency.subnets.outputs.private_subnet_ids_by_az[local.app_az]
  security_group_ids = [dependency.security_groups.outputs.qdrant_security_group_id]

  instance_type  = "t4g.small"
  root_volume_gb = 20
  data_volume_gb = 20

  # git-SHA-immutable image mirrored into our ECR; URL from the ECR dependency so
  # no account id is written into this file.
  image = "${dependency.ecr.outputs.repository_urls[local.repo_key]}:${local.image_tag}"

  # PHASE 1 (dev bring-up): API-key auth DEFERRED. secret_arn="" starts Qdrant
  # auth-off so the host + volume + TLS + discovery can be validated before the
  # org-wide secrets pass sets the key. TLS stays ON, so the only relaxed control
  # is auth; compensating controls are the private subnet, SG-to-SG-only ingress,
  # no public IP, and no real data in dev. Documented in the module README.
  # CLOSE in phase 2 by wiring the secret and re-applying:
  #   secret_arn = dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/qdrant/app"]
  secret_arn = ""

  rest_port = dependency.security_groups.outputs.qdrant_rest_port
  grpc_port = dependency.security_groups.outputs.qdrant_grpc_port

  # Stable in-VPC name: qdrant.genai-dev.internal, unaffected by the ingress toggle.
  service_discovery_namespace_id   = dependency.dns.outputs.namespace_id
  service_discovery_namespace_name = dependency.dns.outputs.namespace_name

  kms_key_arn              = dependency.kms.outputs.key_arn
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"

  # ARN-scoped: pulls ONLY the qdrant repo.
  ecr_repository_arns = [dependency.ecr.outputs.repository_arns[local.repo_key]]
}
