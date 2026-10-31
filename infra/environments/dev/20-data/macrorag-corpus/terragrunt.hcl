# dev / 20-data/macrorag-corpus — MacroRAG corpus object store (M1).
#
# Holds the corpus object data in deploy_mode=aws: raw/ and processed/ documents
# plus the vectorstore manifest.json (which stamps the world_view_id), under the
# "corpus" prefix. The derived SQLite time-series, ingest cache, traces and eval
# do NOT live here — those are on the instance's EBS data volume (M2). See
# MacroRAG docs/design/Macro_RAG_AWS_Deployment_Plan.md §4.2 / §6.
#
# The MacroRAG instance role (compute/ec2-app, 41-macrorag/app) gets ARN-scoped
# read+write on this bucket; boto3 reads credentials from the instance role, so
# there are no keys on disk. Objects are SSE-KMS with the project CMK, which the
# role can use via the key's s3 ViaService path (no extra KMS wiring).
#
# Creating the bucket does not fill it — empty it costs ~$0; it grows only as a
# corpus is ingested.
#
# Cost: $0.023/GB-month STANDARD + versioning cleanup after 30 days. The dev
# corpus is small; expect < $0.10/mo.
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
  # arn:aws:s3:::genai-* (security/iam-terraform-role). A name outside that
  # prefix fails CreateBucket with AccessDenied — the scoping working, not a bug.
  # Region suffix is for S3's global-namespace uniqueness, not routing.
  bucket_name = "genai-${local.env.name}-macrorag-corpus-${local.merged.region}"
  kms_key_arn = dependency.kms.outputs.key_arn

  # NO object expiry (0). Stated reason (the provisioning principles require one
  # for a 0): this is the durable corpus artifact — raw/processed documents and
  # the manifest.json that stamps the index's world_view_id. Expiring live
  # objects would delete the corpus and its provenance. Growth is bounded by
  # noncurrent-version cleanup below, not by deleting live objects.
  expiration_days = 0

  # Versioning stays ON (default) as an accidental-overwrite/delete guard during
  # a re-ingest; superseded versions are cleaned after 30 days so old copies do
  # not accrue cost silently.
  noncurrent_expiration_days = 30

  # NO storage-class transitions: processed docs are read on every index build
  # and manifest.json on every query, so the objects stay in STANDARD. IA/GLACIER
  # add per-GB retrieval charges and 30/90-day minimums — more expensive here,
  # not less, for objects read repeatedly.

  # Server access logging OFF for dev — a PROD hardening item. The corpus will
  # eventually hold real documents; turning logging on additionally requires
  # extending the logs bucket policy to grant logging.s3.amazonaws.com (a
  # separate change). Compensating controls today: block-public-access, SSE-KMS,
  # TLS-enforced bucket policy, ARN-scoped role access, and account CloudTrail —
  # and there is no real data in dev yet. Revisit before prod / a real corpus.
  access_log_bucket = ""

  # A data store, not a log-delivery target.
  allow_aws_log_delivery = false

  # force_destroy stays false (default): destroy must fail on a non-empty bucket.
  # The corpus is not casually disposable.
}
