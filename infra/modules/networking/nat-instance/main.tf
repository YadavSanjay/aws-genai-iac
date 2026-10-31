# NAT instance — a t4g.nano replacement for the NAT Gateway.
#
# Rationale in docs/design/aws-service-consolidation.md §2a. In short: a NAT
# Gateway bills $0.045/hour for every hour it EXISTS and has no stop state, so
# with dev instances scheduled off-hours it would become the largest line item
# in the environment. An EC2 instance genuinely stops.
#
# Accepted costs: we own patching, and it is a single point of failure. Both are
# fine for dev. prod keeps the NAT Gateway.

# Latest AL2023 arm64 image. NOT the SSM public-parameter lookup that most
# examples use — the exec role holds no ssm: actions at all, so that data source
# fails with AccessDenied. DescribeImages is covered by its ec2:* grant.
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

# --- Instance role -----------------------------------------------------------
# Session Manager only. There is no SSH rule and no key pair anywhere in this
# project, so this role is the ONLY way to reach the instance — which is why it
# exists on a box that needs no AWS permissions to perform its actual job.

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

resource "aws_iam_role" "nat" {
  name                 = "${var.name_prefix}-nat"
  description          = "NAT instance: Session Manager access only."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

# The AWS-managed policy, capped by our boundary. The boundary is what actually
# bounds this role — the managed policy is broader than we would write, and the
# intersection is what applies.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name = "${var.name_prefix}-nat"
  role = aws_iam_role.nat.name

  tags = var.tags
}

# --- Security group ----------------------------------------------------------

resource "aws_security_group" "nat" {
  name        = "${var.name_prefix}-nat"
  description = "NAT instance: accepts traffic from private subnets, egresses to the internet."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat"
    Tier = "nat"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# All protocols from the private subnets. Wide by necessity: a NAT forwards
# whatever the private tier sends, and narrowing this to specific ports would
# break any protocol not anticipated here. The SOURCE is the control — only the
# private subnet ranges, never the internet.
resource "aws_vpc_security_group_ingress_rule" "from_private" {
  for_each = toset(var.private_subnet_cidrs)

  security_group_id = aws_security_group.nat.id
  description       = "All traffic from the private tier, for forwarding"

  cidr_ipv4   = each.value
  ip_protocol = "-1"
}

# Egress must be unrestricted: the whole purpose is to reach arbitrary internet
# destinations on behalf of the private tier. Narrowing here would silently
# break whatever protocol was not foreseen.
resource "aws_vpc_security_group_egress_rule" "to_internet" {
  security_group_id = aws_security_group.nat.id
  description       = "Forwarded traffic to the internet"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

# --- Instance ----------------------------------------------------------------

resource "aws_instance" "nat" {
  # CKV_AWS_88 ("EC2 instance should not have public IP") is the one check this
  # module exists to violate. A NAT device sits in a public subnet with a public
  # address BY DEFINITION — that address is what private-tier traffic is
  # translated to. An instance here without one would forward packets nowhere.
  #
  # The compensating controls are the ones that matter for a public-facing box:
  # the security group accepts traffic only from the private subnet CIDRs and
  # never from the internet (asserted by test), there is no SSH rule and no key
  # pair, IMDSv2 is required, and the only administrative path is Session
  # Manager, which dials outbound.
  #
  # CKV_AWS_126 (detailed monitoring) is a deliberate cost decision. Detailed
  # monitoring is $2.10/instance/month — roughly 30% of this instance's entire
  # cost — to move CloudWatch metrics from 5-minute to 1-minute granularity on a
  # box whose job is forwarding packets. Basic monitoring is free and sufficient;
  # if this instance is unhealthy the symptom is total egress loss, which is
  # obvious within seconds regardless of metric resolution.
  #checkov:skip=CKV_AWS_88:A NAT device requires a public IP by definition. Ingress is restricted to private subnet CIDRs; no SSH, IMDSv2 required, SSM-only access.
  #checkov:skip=CKV_AWS_126:Detailed monitoring costs $2.10/mo (~30% of this instance) for 1-minute metrics on a packet forwarder. Egress loss is self-evident.
  ami           = data.aws_ami.al2023_arm64.id
  instance_type = var.instance_type
  subnet_id     = var.public_subnet_id

  # t4g is Nitro, where EBS optimization is always on — stating it explicitly
  # costs nothing and keeps the intent visible.
  ebs_optimized = true

  vpc_security_group_ids = [aws_security_group.nat.id]
  iam_instance_profile   = aws_iam_instance_profile.nat.name

  # THE line that makes this a NAT rather than an ordinary instance. With the
  # check on, EC2 drops any packet whose source or destination is not this
  # instance — which is every forwarded packet.
  source_dest_check = false

  # Auto-assigned rather than an Elastic IP. An EIP would cost the same $0.005/h
  # while the instance runs AND keep billing while it is stopped. The address
  # changes on restart, which is irrelevant for outbound-only NAT since nothing
  # allowlists our egress address.
  associate_public_ip_address = true

  user_data                   = file("${path.module}/user-data.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn

    delete_on_termination = true
  }

  # IMDSv2 required. IMDSv1's unauthenticated GET is the classic SSRF path to
  # instance credentials; requiring a token makes it a two-step exchange that a
  # simple request-forgery cannot complete.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring = false # detailed monitoring is $2.10/instance/month; basic is free

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat"
    Tier = "nat"
  })

  lifecycle {
    # A newer AL2023 AMI must not silently replace the instance on an unrelated
    # plan — that would drop every private-tier connection mid-apply. Patching
    # happens in place via SSM; an AMI refresh is a deliberate taint-and-replace.
    ignore_changes = [ami]
  }
}

# --- Routes ------------------------------------------------------------------
# Target the ENI, not the instance id. The ENI survives a stop/start, so the
# route stays valid across the scheduled shutdown — traffic blackholes while the
# instance is down and resumes when it returns, with no route churn.

resource "aws_route" "private_default" {
  for_each = toset(var.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}
