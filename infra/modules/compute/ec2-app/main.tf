# Application host: a private-subnet EC2 instance running containers.
#
# Reachable only through the ALB, egressing only through the NAT instance, and
# administered only through SSM Session Manager. No public address, no key pair,
# no inbound rule of its own.

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
  full_name = "${var.name_prefix}-${var.app_name}"

  # In-account ECR registry host for the bootstrap's `docker login`.
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"

  # Non-secret compose env, one KEY=value per line for /opt/app/.env.
  runtime_env_rendered = join("\n", [for k, v in var.runtime_env : "${k}=${v}"])

  # Mount only when a data volume was actually requested.
  effective_data_mount = var.data_volume_gb > 0 ? var.data_mount_point : ""

  # Register in Cloud Map only when a namespace was supplied.
  register_discovery = var.service_discovery_namespace_id != ""
  discovery_name     = var.discovery_service_name != "" ? var.discovery_service_name : var.app_name
}

# When a data volume is requested it must land in the instance's AZ; derive it
# from the subnet rather than take a second, redundant input that could disagree.
data "aws_subnet" "this" {
  id = var.subnet_id
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

resource "aws_iam_role" "app" {
  name                 = local.full_name
  description          = "Application host ${var.app_name}: SSM access, scoped ECR pull and secret read."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Everything the workload needs, ARN-scoped. Note this role can read ITS OWN
# secrets and pull ITS OWN images — not every secret and image in the account,
# which is what an unscoped ecr:* / secretsmanager:* grant would give.
data "aws_iam_policy_document" "app" {
  # GetAuthorizationToken takes no resource — it mints a registry-wide login
  # token. The pull itself is scoped by the statement below, which is where the
  # actual restriction lives.
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
      sid    = "EcrPullOwnImagesOnly"
      effect = "Allow"
      actions = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
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

  # ListBucket is on the bucket ARN itself; the object grant below is on its
  # contents. Split because s3:ListBucket does not accept an object-level ARN.
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

  # Read-only pull of the deploy bundle from a bucket the app does NOT own for
  # data (a stateless tier). ListBucket + GetObject only — no Put/Delete — so a
  # host can fetch its compose bundle without write access to the bucket it lives
  # in. MacroRAG leaves this empty (its bundle rides the corpus RW grant above).
  dynamic "statement" {
    for_each = var.bundle_read_bucket_arn != "" ? [1] : []

    content {
      sid    = "ReadDeployBundleOnly"
      effect = "Allow"
      actions = [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetObject",
      ]
      resources = [
        var.bundle_read_bucket_arn,
        "${var.bundle_read_bucket_arn}/*",
      ]
    }
  }

  # Decrypting a secret, pulling KMS-encrypted image layers, and reading/writing
  # SSE-KMS S3 objects all call KMS on the caller's behalf. kms:ViaService in the
  # key policy confines this to those service paths (s3 included), so the role
  # cannot call Decrypt directly.
  statement {
    sid       = "DecryptViaServices"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app-runtime"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = local.full_name
  role = aws_iam_role.app.name

  tags = var.tags
}

# --- Instance ----------------------------------------------------------------

resource "aws_instance" "app" {
  # CKV_AWS_126 (detailed monitoring): $2.10/instance/month for 1-minute rather
  # than 5-minute metrics. Not justified on a dev host that is stopped 14 hours
  # a day; the ALB health check is the signal that matters and it is per-request.
  #checkov:skip=CKV_AWS_126:Detailed monitoring is $2.10/mo per instance for finer metrics; ALB health checks provide the signal that matters in dev.
  ami           = data.aws_ami.al2023_arm64.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  ebs_optimized = true

  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.app.name

  # Private subnet, and explicitly no public address. Ingress arrives via the
  # ALB; egress leaves via the NAT instance.
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region                 = data.aws_region.current.region
    registry               = local.ecr_registry
    bundle_uri             = var.compose_bundle_s3_uri
    compose_file           = var.compose_file_relpath
    data_mount             = local.effective_data_mount
    secret_arn             = var.app_env_secret_arn
    secret_env_file        = var.app_env_file_path
    db_secret_arn          = var.db_secret_arn
    db_secret_env_map_json = jsonencode(var.db_secret_env_map)
    project_env            = local.runtime_env_rendered
    deploy_env_relpath     = var.deploy_env_relpath
  })
  # Only the STATIC config lives in user-data now (image tags live in the S3
  # deploy bundle), so a routine image bump no longer replaces the host.
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn

    delete_on_termination = true

    tags = merge(var.tags, {
      Name = "${local.full_name}-root"
    })
  }

  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"
    # Hop limit 1 (default) stops a container reaching instance metadata and
    # assuming the instance role — the standard container-escape-to-credentials
    # path. Raised to 2 only for hosts whose containers legitimately need the
    # instance role (a boto3 workload); see var.imds_hop_limit.
    http_put_response_hop_limit = var.imds_hop_limit
  }

  monitoring = false

  tags = merge(var.tags, {
    Name = local.full_name
    Tier = "app"
    App  = var.app_name
  })

  lifecycle {
    # A newer AL2023 release must not replace a running application host on an
    # unrelated plan. Patching is in-place via SSM; AMI refresh is deliberate.
    ignore_changes = [ami]
  }
}

# --- Dedicated data volume (optional) ----------------------------------------
#
# Separate from root so application state survives instance replacement and can
# carry its own snapshot lifecycle. CMK-encrypted, attached at /dev/sdf. The
# bootstrap formats it once (labelled) and mounts it by label — resilient to
# NVMe device renaming across a stop/start. Created only when data_volume_gb > 0,
# so consumers that keep everything on root are unaffected.
resource "aws_ebs_volume" "data" {
  count = var.data_volume_gb > 0 ? 1 : 0

  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "${local.full_name}-data"
  })
}

resource "aws_volume_attachment" "data" {
  count = var.data_volume_gb > 0 ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data[0].id
  instance_id = aws_instance.app.id

  # Detach cleanly if the instance is replaced; the volume (a separate resource)
  # is untouched, so the data persists across the replacement.
  stop_instance_before_detaching = true
}

# --- Service discovery (optional) ---------------------------------------------
#
# A stable in-VPC name (<discovery_name>.<namespace>) so a CALLER configures a
# DNS host rather than a churny private IP. Needed once one app tier calls
# another directly: Faultline's scenariogen reaches ARag and MacroRAG over
# REST, and neither had a resolvable name before this.
#
# Same mechanism data/qdrant already uses, and deliberately in THIS module rather
# than a component of its own. The record's value references
# aws_instance.app.private_ip, so Terraform's graph rewrites it in the same apply
# that replaces the instance — there is no window in which the name points at a
# dead host, and no second component to remember to re-apply. That second
# component is precisely the shape that leaves an app-schedule pinned to a
# terminated instance id.
#
# These resources reference the instance but nothing on the instance references
# them, so adding discovery to an existing host is an ADD, never a replacement.
resource "aws_service_discovery_service" "app" {
  count = local.register_discovery ? 1 : 0

  name        = local.discovery_name
  description = "In-VPC discovery for the ${var.app_name} application tier."

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      type = "A"
      # Short, because the address changes when the instance is replaced. A
      # long TTL would leave callers holding a dead address well past the apply
      # that fixed it.
      ttl = 10
    }

    routing_policy = "MULTIVALUE"
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.service_discovery_namespace_name != ""
      error_message = "service_discovery_namespace_name is required when service_discovery_namespace_id is set: the id cannot be resolved back to a DNS suffix, so discovery_fqdn would be wrong. The dns component outputs both."
    }
  }
}

resource "aws_service_discovery_instance" "app" {
  count = local.register_discovery ? 1 : 0

  instance_id = aws_instance.app.id
  service_id  = aws_service_discovery_service.app[0].id

  attributes = {
    AWS_INSTANCE_IPV4 = aws_instance.app.private_ip
  }
}

# --- Start/stop schedule (optional) -------------------------------------------
#
# Reuses scheduler/eventbridge rather than reimplementing it, but instantiates it
# HERE so the schedule and the instance share one state. A separate
# `<app>-app-schedule` component — the estate's older pattern — stores a COPY of
# the instance id, so reprovisioning the host without re-applying that component
# silently leaves the schedule targeting a terminated instance. MacroRAG's is in
# exactly that state. As a nested module the target is a REFERENCE
# (aws_instance.app.id), rewritten by the same apply that replaces the host.
#
# The schedule resources do not feed user_data, so adding a window to an existing
# host is an ADD, never a replacement.
module "schedule" {
  count  = var.start_cron != "" && var.stop_cron != "" ? 1 : 0
  source = "../../scheduler/eventbridge"

  name_prefix  = var.name_prefix
  workload     = var.app_name
  instance_ids = [aws_instance.app.id]

  start_cron = var.start_cron
  stop_cron  = var.stop_cron
  timezone   = var.schedule_timezone
  enabled    = var.schedule_enabled

  kms_key_arn              = var.kms_key_arn
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}
