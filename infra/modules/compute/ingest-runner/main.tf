# On-demand ingest runner: a private EC2 that runs the ARag ingest pipeline.
#
# NOT a service. The bootstrap installs docker, renders the runtime env-files, and
# pulls the ingest image; then an operator connects via SSM and runs the pipeline
# with the `arag-ingest` wrapper (docker run with both env-files + a scratch mount).
# Launch it, ingest, stop it — it bills only while running.
#
# The image is torch-free and embeds over RagInference; it downloads filings from
# EDGAR and writes them to S3, writes facts to RDS, and vectors to the shared Qdrant
# — all reached over the VPC via the reused app-tier SG. See the ingest Dockerfile
# and ARag_AWS_Deployment_Plan_July2026.md §5.

data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  full_name            = "${var.name_prefix}-${var.app_name}"
  ecr_registry         = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
  runtime_env_rendered = join("\n", [for k, v in var.runtime_env : "${k}=${v}"])
}

# --- Instance role -----------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name                 = local.full_name
  description          = "ARag ingest runner: SSM access, scoped ECR pull, secret read, filings S3 read/write."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped to its own image, its own secrets, and the filings bucket — not every
# repo/secret/bucket in the account.
data "aws_iam_policy_document" "runner" {
  dynamic "statement" {
    for_each = length(var.ecr_repository_arns) > 0 ? [1] : []
    content {
      sid       = "EcrLogin"
      effect    = "Allow"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.ecr_repository_arns) > 0 ? [1] : []
    content {
      sid       = "EcrPullOwnImageOnly"
      effect    = "Allow"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      resources = var.ecr_repository_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 || var.db_secret_arn != "" ? [1] : []
    content {
      sid       = "ReadOwnSecretsOnly"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = concat(var.secret_arns, var.db_secret_arn != "" ? [var.db_secret_arn] : [])
    }
  }

  dynamic "statement" {
    for_each = length(var.s3_bucket_arns) > 0 ? [1] : []
    content {
      sid    = "ListOwnBucketsOnly"
      effect = "Allow"
      actions = [
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      resources = var.s3_bucket_arns
    }
  }

  # Read+WRITE: the ingest downloads filings and writes them to S3 (unlike the app
  # tier, which only reads its deploy bundle).
  dynamic "statement" {
    for_each = length(var.s3_bucket_arns) > 0 ? [1] : []
    content {
      sid    = "ReadWriteOwnObjectsOnly"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      resources = [for arn in var.s3_bucket_arns : "${arn}/*"]
    }
  }

  statement {
    sid       = "DecryptViaServices"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "runner" {
  name   = "ingest-runtime"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner.json
}

resource "aws_iam_instance_profile" "runner" {
  name = local.full_name
  role = aws_iam_role.runner.name
  tags = var.tags
}

# --- Instance ----------------------------------------------------------------

resource "aws_instance" "runner" {
  # CKV_AWS_126 (detailed monitoring): $2.10/mo per instance for 1-minute metrics —
  # not justified on an on-demand box that is stopped most of the time.
  #checkov:skip=CKV_AWS_126:Detailed monitoring not justified on an on-demand, usually-stopped ingest box.
  ami           = data.aws_ami.al2023_arm64.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  ebs_optimized = true

  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.runner.name

  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region                 = data.aws_region.current.region
    registry               = local.ecr_registry
    image_pointer_uri      = var.image_pointer_uri
    secret_arn             = var.app_env_secret_arn
    secret_env_file        = var.app_env_file_path
    db_secret_arn          = var.db_secret_arn
    db_secret_env_map_json = jsonencode(var.db_secret_env_map)
    project_env            = local.runtime_env_rendered
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
    tags = merge(var.tags, {
      Name = "${local.full_name}-root"
    })
  }

  tags = merge(var.tags, {
    Name = local.full_name
    Tier = "ingest"
  })
}
