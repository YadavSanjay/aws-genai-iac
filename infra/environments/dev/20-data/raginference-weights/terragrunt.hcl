# dev / 20-data/raginference-weights — RagInference model-weights bucket.
#
# R2 of the RagInference rollout. Holds the BGE-M3 embedder + Jina reranker
# weights in HF-cache layout (~4 GB). The Fargate task syncs them to HF_HOME at
# start (MODEL_SOURCE=s3), pulling over the FREE S3 gateway endpoint so the ~4 GB
# never touches the NAT instance. The bucket URI becomes the task's MODEL_S3_URI
# in R6.
#
# Creating the bucket is separate from FILLING it: after this applies, seed once
# (build weights locally, then `aws s3 sync ./models s3://<bucket>` as genai-tf).
# Until seeded the bucket is empty and costs ~$0; full it is ~$0.10/mo.
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

dependency "kms" {
  config_path = "../../10-security/kms"

  mock_outputs = {
    key_arn = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/data/s3"
}

inputs = {
  # MUST start with "genai-": the exec role's s3 grant is ARN-scoped to
  # arn:aws:s3:::genai-* (security/iam-terraform-role, GlobalData -> ProjectBuckets).
  # A name outside that prefix fails CreateBucket with AccessDenied — the scoping
  # working, not a bug. Region suffix is for S3's global uniqueness, not routing.
  bucket_name = "genai-${local.env.name}-raginference-weights-${local.merged.region}"
  kms_key_arn = dependency.kms.outputs.key_arn

  # NO object expiry (0), and this is the stated reason the provisioning
  # principles require: weights are the durable artifact the service loads on
  # EVERY cold start (scale-from-zero). Expiring them would empty the bucket and
  # break the service. Accumulation is bounded instead by versioning cleanup
  # below, not by deleting the live objects.
  expiration_days = 0

  # Weights are overwritten only on a deliberate re-seed, and the previous set is
  # always re-downloadable from Hugging Face — so keep superseded versions only
  # briefly. Versioning stays ON (default) purely as an accidental-overwrite
  # guard during a re-seed; 7 days caps the cost of the old ~4 GB copy.
  noncurrent_expiration_days = 7

  # NO storage-class transitions: the full weight set is read on every
  # scale-from-zero, so it must stay in STANDARD. STANDARD_IA/GLACIER add a
  # per-GB retrieval charge on each cold start and a 30/90-day minimum — that is
  # more expensive here, not less, for an object read repeatedly.

  # Server access logging OFF, deliberately. The contents are PUBLIC model
  # weights (BGE-M3 + Jina, freely downloadable), not sensitive data; access is
  # read-only from the task role over the private S3 gateway endpoint; and the
  # account-level CloudTrail is the audit path. Turning on S3 server-access-log
  # delivery would additionally require extending the logs bucket's policy to
  # grant logging.s3.amazonaws.com — a separate change with no security payoff
  # for non-sensitive artifacts. Revisit if the bucket ever holds private data.
  access_log_bucket = ""

  # This bucket is a data store, not a log-delivery target.
  allow_aws_log_delivery = false
}
