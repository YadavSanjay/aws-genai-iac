# dev / 20-data/qlp-data — Faultline object store (Q2).
#
# Two logically distinct things live here, both durable:
#
#   data/    the seed + backup of Faultline's data tree (marketdata, pricer,
#            risk, scenariogen), mirroring the on-disk layout its storage façade
#            uses (Faultline docs/design/AITrade_aws_deployment_design.md
#            §3.2 / §7.3). Per the rollout plan the LIVE tree in dev is the app
#            host's CMK EBS volume with PRICER_DEPLOY_MODE=local; this bucket is
#            the off-box copy it is seeded FROM and pushed back TO. Both
#            directions are MANUAL operator steps over SSM by decision — the
#            ec2-app bootstrap syncs the deploy bundle only, and automating the
#            data sync would replace the host (user_data_replace_on_change). Flipping the backend to
#            PRICER_DEPLOY_MODE=aws + PRICER_DATA_URI=s3://<this>/data later is a
#            config change, not a new bucket — the façade already speaks S3.
#   deploy/  the compose bundle (docker-compose.aws.yml + deploy.env) the app
#            tier pulls read-only at boot, exactly as ARag's filings bucket does.
#            The image tags live in deploy.env HERE, never in Terraform, so a
#            version bump is a deploy and not a reprovision (CLAUDE.md
#            provisioning principle 6).
#
# Access is ARN-scoped and lands with the consumer, not here: Q5 grants the app
# host read+write on the bucket for the data tree and read-only on deploy/. boto3
# reads credentials from the instance role, so there are no keys on disk. Objects
# are SSE-KMS with the project CMK, usable by the role via the key's s3 ViaService
# path (no extra KMS wiring).
#
# Creating the bucket does not fill it — empty it costs ~$0. The whole data tree
# measures 36 MB, so expect well under $0.10/mo even once seeded.
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
  bucket_name = "genai-${local.env.name}-qlp-data-${local.merged.region}"
  kms_key_arn = dependency.kms.outputs.key_arn

  # NO object expiry (0). Stated reason (the provisioning principles require one
  # for a 0): this store holds the reproducibility spine. Run manifests, snapshot
  # -addressed market data, golden baselines and sign-off records are audit
  # artifacts whose whole value is that a past run can still be reconstructed —
  # a timer that deletes them silently destroys that. The deploy/ prefix is
  # load-bearing for a different reason: expire it and a rebooted host cannot
  # start its stack at all. Growth is bounded by noncurrent-version cleanup
  # below, and the tree is MB-scale.
  expiration_days = 0

  # Versioning stays ON (default). Beyond the usual overwrite guard it REINFORCES
  # the provenance spine — content-addressed outputs are written once under a new
  # key, so versions only accrue on the genuinely mutable objects (deploy.env,
  # latest-pointers). Superseded copies are cleaned after 30 days.
  noncurrent_expiration_days = 30

  # NO storage-class transitions. Two independent reasons: the BFF's DuckDB layer
  # re-globs the parquet store on every read, so these objects are hot, not cold;
  # and IA bills a 128 KB minimum per object against a store of ~940 tiny parquet
  # files, which would cost MORE than STANDARD, not less. Transitions here would
  # be a cost regression dressed as an optimization.

  # Server access logging OFF for dev — a PROD hardening item. Turning it on
  # additionally requires extending the logs bucket policy to grant
  # logging.s3.amazonaws.com (a separate change). Compensating controls today:
  # block-public-access, SSE-KMS, TLS-enforced bucket policy, ARN-scoped role
  # access, and account CloudTrail. Revisit before prod.
  access_log_bucket = ""

  # A data store, not a log-delivery target.
  allow_aws_log_delivery = false

  # force_destroy stays false (default): destroy must fail on a non-empty bucket.
  # Losing the deploy bundle bricks the app tier's boot path.
}
