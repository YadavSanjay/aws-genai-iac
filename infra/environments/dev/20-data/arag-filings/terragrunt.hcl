# dev / 20-data/arag-filings — ARag SEC-filings object store (A2).
#
# Holds the raw SEC EDGAR filings in ARAG_DEPLOY_MODE=aws: downloaded attachments,
# manifest.yaml, and canonical HTML, under the {ticker}/{year}/{form}/... key
# layout the FilingStore abstraction uses (ARag docs/design/
# ARag_AWS_Deployment_Plan_July2026.md §4.1 / §6 item 3). This is the S3 side of
# ARag's dual local/aws storage seam; local mode keeps the same layout on disk.
#
# INGEST-SIDE ONLY. ARag's query path is filesystem-free (reads facts from RDS and
# narrative from Qdrant), so only the ingest runner (42-arag/ingest, A7) gets
# ARN-scoped read+write on this bucket; the app tier (A6) does not touch it. boto3
# reads credentials from the instance role, so there are no keys on disk. Objects
# are SSE-KMS with the project CMK, usable by the role via the key's s3 ViaService
# path (no extra KMS wiring). Role grants land in A5/A7, not here.
#
# Creating the bucket does not fill it — empty it costs ~$0; it grows only as
# filings are ingested.
#
# Cost: $0.023/GB-month STANDARD + versioning cleanup after 30 days. Filings are
# small HTML/XBRL; expect < $0.10/mo in dev.
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
  bucket_name = "genai-${local.env.name}-arag-filings-${local.merged.region}"
  kms_key_arn = dependency.kms.outputs.key_arn

  # NO object expiry (0). Stated reason (the provisioning principles require one
  # for a 0): filings are the durable source artifact of the whole XBRL pipeline —
  # facts in RDS and vectors in Qdrant are DERIVED from them and can be rebuilt,
  # but the filings themselves cannot be re-derived if deleted (only re-downloaded
  # from EDGAR). Expiring live objects would erase the corpus of record. Growth is
  # bounded by noncurrent-version cleanup below, not by deleting live objects.
  expiration_days = 0

  # Versioning stays ON (default) as an accidental-overwrite/delete guard during a
  # re-download or re-ingest; superseded versions are cleaned after 30 days so old
  # copies do not accrue cost silently.
  noncurrent_expiration_days = 30

  # NO storage-class transitions: canonical HTML is re-read by the ingest pipeline
  # on every re-chunk / re-embed, so objects stay in STANDARD. IA/GLACIER add
  # per-GB retrieval charges and 30/90-day minimums — more expensive here, not
  # less, for objects read repeatedly during ingest.

  # Server access logging OFF for dev — a PROD hardening item. Turning it on
  # additionally requires extending the logs bucket policy to grant
  # logging.s3.amazonaws.com (a separate change). Compensating controls today:
  # block-public-access, SSE-KMS, TLS-enforced bucket policy, ARN-scoped role
  # access, and account CloudTrail — and there is no real data in dev yet. Revisit
  # before prod / a real filing set.
  access_log_bucket = ""

  # A data store, not a log-delivery target.
  allow_aws_log_delivery = false

  # force_destroy stays false (default): destroy must fail on a non-empty bucket.
  # The filings store is not casually disposable.
}
