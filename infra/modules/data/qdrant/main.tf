# Shared Qdrant vector store: a private-subnet EC2 host running the mirrored
# Qdrant container, with a dedicated EBS data volume and Cloud Map discovery.
#
# Reachable only from its consumer SGs on 6333/6334 (TLS + API key), egressing
# only through the NAT instance, administered only through SSM Session Manager.
# No public address, no key pair. Serves MacroRAG + ARag over the VPC; see
# docs/design/qdrant-cloud-vs-self-hosted.md §6a.

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

# The data volume must land in the instance's AZ; derive it from the subnet
# rather than take it as a second, redundant input that could disagree.
data "aws_subnet" "this" {
  id = var.subnet_id
}

data "aws_region" "current" {}

locals {
  full_name      = "${var.name_prefix}-qdrant"
  discovery_fqdn = "qdrant.${var.service_discovery_namespace_name}"
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

resource "aws_iam_role" "qdrant" {
  name                 = local.full_name
  description          = "Qdrant host: SSM access, scoped ECR pull of its own image, and read of its own API-key secret."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.qdrant.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ARN-scoped: this host pulls ONLY the qdrant image and reads ONLY its own
# secret — not every repo and secret in the account.
data "aws_iam_policy_document" "qdrant" {
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

  # Only when a secret is wired (auth enabled). Auth-off bring-up grants the host
  # no secret-read at all — least privilege follows the actual need.
  dynamic "statement" {
    for_each = var.secret_arn != "" ? [1] : []
    content {
      sid       = "ReadOwnApiKeySecretOnly"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [var.secret_arn]
    }
  }

  # Decrypting the secret and pulling KMS-encrypted image layers both call KMS on
  # the caller's behalf; kms:ViaService in the key policy confines this to those
  # service paths, so the role cannot call Decrypt directly.
  statement {
    sid       = "DecryptViaServices"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "qdrant" {
  name   = "qdrant-runtime"
  role   = aws_iam_role.qdrant.id
  policy = data.aws_iam_policy_document.qdrant.json
}

resource "aws_iam_instance_profile" "qdrant" {
  name = local.full_name
  role = aws_iam_role.qdrant.name
  tags = var.tags
}

# --- Dedicated data volume ---------------------------------------------------
#
# Separate from root so vector data survives instance replacement and gets its
# own snapshot lifecycle. CMK-encrypted. Attached at /dev/sdf; the bootstrap
# finds it as the non-root disk, formats it once (labelled qdrant-data) and
# mounts it by label so it is resilient to NVMe device renaming.
resource "aws_ebs_volume" "data" {
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
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.qdrant.id

  # Let the attachment be torn down when the instance is replaced; the volume
  # itself (a separate resource) is untouched, so the data persists.
  stop_instance_before_detaching = true
}

# --- Instance ----------------------------------------------------------------

resource "aws_instance" "qdrant" {
  # CKV_AWS_126 (detailed monitoring): $2.10/instance/month for 1-minute metrics,
  # not justified on a dev host stopped 14 hours a day. The scheduled CloudWatch
  # alarms use the standard 5-minute metrics.
  #checkov:skip=CKV_AWS_126:Detailed monitoring is $2.10/mo per instance; standard 5-minute metrics suffice on a scheduled dev host.
  ami           = data.aws_ami.al2023_arm64.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  ebs_optimized = true

  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.qdrant.name

  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region          = data.aws_region.current.region
    require_api_key = var.secret_arn != "" ? "true" : "false"
    secret_id       = var.secret_arn
    image           = var.image
    registry        = split("/", var.image)[0]
    rest_port       = var.rest_port
    grpc_port       = var.grpc_port
    cert_cn         = local.discovery_fqdn
  })
  user_data_replace_on_change = true

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

  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"
    # Hop limit 2 (not 1): the Qdrant container must reach IMDS to obtain the
    # instance-role credentials it uses for the ECR pull and Secrets Manager
    # read at boot. A containerized workload adds one network hop, so hop-limit-1
    # would deny it credentials. Egress is still SG-restricted to AWS services.
    http_put_response_hop_limit = 2
  }

  monitoring = false

  tags = merge(var.tags, {
    Name = local.full_name
    Tier = "data"
    App  = "qdrant"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# --- Cloud Map discovery -----------------------------------------------------
#
# A stable in-VPC name (qdrant.<namespace>) so consumers configure a DNS host,
# not a churny private IP. Registered against the existing private namespace,
# same mechanism the design's *.internal discovery uses for RagInference.
resource "aws_service_discovery_service" "qdrant" {
  name = "qdrant"

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      type = "A"
      ttl  = 10
    }

    routing_policy = "MULTIVALUE"
  }

  tags = var.tags
}

resource "aws_service_discovery_instance" "qdrant" {
  instance_id = aws_instance.qdrant.id
  service_id  = aws_service_discovery_service.qdrant.id

  attributes = {
    AWS_INSTANCE_IPV4 = aws_instance.qdrant.private_ip
  }
}
