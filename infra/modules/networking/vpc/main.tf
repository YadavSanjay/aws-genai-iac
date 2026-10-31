# VPC skeleton: the network container, its egress gateway, a locked-down default
# security group, and flow logging.
#
# Deliberately no subnets, route tables or NAT — those are separate, independently
# appliable steps. What is here has no dependency on any of them.

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

# --- Default security group: stripped, not merely unused ---------------------
# AWS creates a default SG with every VPC, carrying an allow-all-from-self
# ingress rule and unrestricted egress. It cannot be deleted. Anything launched
# without an explicit SG lands in it.
#
# Declaring it with NO ingress or egress blocks removes every rule, so the
# default becomes deny-all and a workload that accidentally uses it fails
# closed and visibly, rather than silently getting broad connectivity.
#
# Managed here rather than in the later security-group step because AWS creates
# it the instant the VPC exists — deferring would leave a window where it is
# open.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-default-DO-NOT-USE"
  })
}

# --- Internet Gateway --------------------------------------------------------
# Free. Attaching one exposes nothing on its own: traffic also needs a route
# table entry, a public subnet, and a permissive security group.
resource "aws_internet_gateway" "this" {
  count = var.create_internet_gateway ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

# --- Flow logs ---------------------------------------------------------------
# Delivered to S3, not CloudWatch Logs: $0.25/GB vs $0.50/GB, and dev traffic
# does not justify Logs Insights. Parquet is ~20% smaller again and far cheaper
# to query with Athena.
#
# NOTE: no IAM role. That is required only for the CloudWatch Logs destination;
# S3 delivery is authorised entirely by the bucket policy plus, for SSE-KMS, the
# key policy.
resource "aws_flow_log" "this" {
  count = var.flow_log_destination_arn != "" ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_log_traffic_type
  log_destination_type     = "s3"
  log_destination          = var.flow_log_destination_arn
  max_aggregation_interval = var.flow_log_max_aggregation_interval

  destination_options {
    file_format = var.flow_log_file_format

    # Hourly Hive-style partitions. Athena then scans one hour's objects instead
    # of the whole bucket, which is the difference between cents and dollars per
    # query once the archive has any size.
    per_hour_partition         = true
    hive_compatible_partitions = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-flow-logs"
  })
}
