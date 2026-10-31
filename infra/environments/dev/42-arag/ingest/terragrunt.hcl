# dev / 42-arag/ingest — ARag on-demand ingest runner (A7).
#
# A private, usually-STOPPED EC2 that runs the ARag ingest pipeline (Arelle -> RDS
# facts, EDGAR filings -> S3, embeddings via RagInference -> shared Qdrant). NOT a
# service: an operator connects via SSM and runs `arag-ingest <cmd>`; the box bills
# only while running. Launch it, ingest, stop it.
#
# Reuses the shared `app` SG (already egresses to RDS, Qdrant, RagInference, and 443
# for EDGAR + OpenAI + AWS APIs) — the ingest's outbound set. It gets its own role
# with the one grant the app tier lacks: READ+WRITE on the filings bucket.
#
# OPERATE (once running, via SSM):
#   sudo arag-ingest python scripts/bootstrap_db.py --phase data --ticker <TICKER>
#   sudo arag-ingest python scripts/bootstrap_db.py --phase mv
# Then stop it:  aws ec2 stop-instances --instance-ids <id>
#
# Cost: ~$0.034/hr ONLY while running (a few hours per ingest); ~$3.20/mo for the
# stopped 40 GB root volume is the idle floor. Apply as: AWS_PROFILE=genai-tf
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

  app_az = "us-east-1a"

  # NO image tag here — see deploy.env in this folder. The tag used to live in
  # this file and reach the host through user_data, which meant every bump
  # replaced the instance. It also let the pin drift behind the code it runs:
  # the pinned tag sat five commits before scripts/bootstrap_db.py existed, so
  # the documented ingest command failed with a bare "No such file or directory".
  # The tag now rides an S3 pointer object, bumped by
  # scripts/deploy_arag_ingest_image.py with no Terraform run at all.
  image_pointer_key = "deploy/ingest.env"
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
    repository_urls = {
      "genai-dev/arag-ingest" = "000000000000.dkr.ecr.us-east-1.amazonaws.com/genai-dev/arag-ingest"
    }
    repository_arns = {
      "genai-dev/arag-ingest" = "arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/arag-ingest"
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
  source = "${get_repo_root()}/infra/modules/compute/ingest-runner"
}

inputs = {
  name_prefix = local.env.name_prefix
  app_name    = "arag-ingest"

  subnet_id = dependency.subnets.outputs.private_subnet_ids_by_az[local.app_az]
  # Reuse the shared app SG — its egress already covers the ingest's outbound.
  security_group_ids = [dependency.security_groups.outputs.app_security_group_id]

  # Arelle parsing wants memory; embeddings are offloaded to RagInference. Bump for
  # a large bulk ingest, then drop back.
  instance_type  = "t4g.medium"
  root_volume_gb = 40

  kms_key_arn              = dependency.kms.outputs.key_arn
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"

  # The pointer object, not the image. It rides the filings bucket's deploy/
  # prefix beside the app tier's deploy.env, and the runner's existing s3:GetObject
  # on that bucket already covers it — decoupling the image cost no new grant.
  image_pointer_uri   = "s3://${dependency.filings.outputs.bucket_id}/${local.image_pointer_key}"
  ecr_repository_arns = [dependency.ecr.outputs.repository_arns["${local.env.name_prefix}/arag-ingest"]]

  # App secret (OpenAI/Jina) verbatim, + the RDS-managed DB secret mapped to the
  # names ARag reads. The bootstrap re-fetches both before each ingest.
  secret_arns        = [dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/arag/app"]]
  app_env_secret_arn = dependency.secrets.outputs.secret_arns["${local.env.name_prefix}/arag/app"]
  app_env_file_path  = "/opt/arag/.env"
  db_secret_arn      = dependency.db.outputs.master_user_secret_arn
  db_secret_env_map = {
    username = "XBRL_DB_USER"
    password = "XBRL_DB_PASSWORD"
  }

  # READ+WRITE on filings: the ingest downloads from EDGAR and writes attachments,
  # manifest.yaml, and canonical HTML to S3.
  s3_bucket_arns = [dependency.filings.outputs.bucket_arn]

  # The ingest container runs boto3 (S3 FilingStore) -> instance-role creds through
  # the docker bridge -> hop 2.
  imds_hop_limit = 2

  # Non-secret runtime env (endpoints + deploy mode + bucket). Credentials come from
  # the secrets above.
  runtime_env = {
    ARAG_DEPLOY_MODE     = "aws"
    ARAG_STORAGE_BACKEND = "s3"
    ARAG_S3_BUCKET       = dependency.filings.outputs.bucket_id

    XBRL_DB_HOST    = dependency.db.outputs.address
    XBRL_DB_PORT    = tostring(dependency.db.outputs.port)
    XBRL_DB_NAME    = dependency.db.outputs.db_name
    XBRL_DB_SSLMODE = "require"

    QDRANT_HOST   = "qdrant.${local.env.name_prefix}.internal"
    QDRANT_PORT   = "6333"
    QDRANT_HTTPS  = "true"
    QDRANT_VERIFY = "false"

    RAGINFER_URL       = "http://raginference.${local.env.name_prefix}.internal:8799"
    RAGINFER_TIMEOUT_S = "1800"
  }
}
