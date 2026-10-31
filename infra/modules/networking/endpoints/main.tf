# S3 gateway endpoint.
#
# Free, and it does more than save money: S3 traffic stays on the AWS network
# instead of traversing the internet gateway or a NAT device. Because ECR image
# layers are stored in S3, this removes the bulk of container-pull traffic from
# the NAT path — which is where per-GB charges would otherwise accumulate.
#
# A gateway endpoint works by injecting a prefix-list route into the route
# tables listed. There is no ENI and no hourly charge, unlike an interface
# endpoint at $7.30/month per AZ.

locals {
  # Object-level ARNs derived from the bucket ARNs, so callers pass each bucket
  # once rather than remembering to supply both forms.
  writable_arns = concat(
    var.writable_bucket_arns,
    [for arn in var.writable_bucket_arns : "${arn}/*"],
  )
}

# --- Endpoint policy ---------------------------------------------------------
#
# The split that matters is WRITE vs READ, not "our buckets vs everything".
#
# Exfiltration through an S3 endpoint means PutObject to a bucket someone else
# controls. Reading foreign buckets is not the risk — and it is load-bearing:
# ECR layer buckets, Amazon Linux repositories and SSM agent downloads all live
# in AWS-owned S3 buckets whose names vary by region and change over time.
#
# So: full access to our own buckets, read-only everywhere else. That closes the
# write-out path without an allow-list of AWS bucket names that would silently
# break instance bootstrap the first time AWS renamed one.
#
# This is defence in depth, not the primary control — the app permissions
# boundary already scopes s3 to genai-*. It matters because it applies to
# ANYTHING in the VPC, including a compromised process using credentials that
# IAM would otherwise permit.
data "aws_iam_policy_document" "s3" {
  # ACCEPTED — checkov is applying IAM-policy heuristics to a VPC endpoint
  # policy, and the two are different in a way that inverts the reading.
  #
  # An endpoint policy is an INTERSECTION FILTER, not a grant. It cannot give
  # any principal a permission it does not already hold via IAM; it can only
  # subtract. So this document is strictly MORE restrictive than the AWS default
  # (which is a bare Allow "*" on "*"), yet checkov scores it as though we had
  # attached it to a role.
  #
  # CKV_AWS_108 ("data exfiltration") specifically misreads the direction here.
  # It fires on s3:GetObject over "*", which through an endpoint means READING
  # AWS-owned buckets — ECR layers, Amazon Linux repos, SSM agent downloads.
  # The exfiltration vector is writing OUT, and that is precisely what the
  # resource-scoped split below prevents; there is a dedicated test
  # (test_writes_to_foreign_buckets_are_not_permitted) asserting no write action
  # is ever granted over "*".
  #
  # CKV_AWS_356 is unavoidable for the same reason it is on the KMS key policy:
  # the read statement must cover buckets whose ARNs are not knowable in advance
  # and change over time.
  #checkov:skip=CKV_AWS_108:Endpoint policies filter rather than grant; GetObject over "*" is inbound reads of AWS-owned buckets. Writes are resource-scoped and tested.
  #checkov:skip=CKV_AWS_356:AWS-owned bucket ARNs (ECR layers, OS repos) are not knowable in advance and change over time
  count = var.restrict_endpoint_policy ? 1 : 0

  statement {
    sid    = "FullAccessToProjectBuckets"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = local.writable_arns
  }

  # Read-only elsewhere. Without this, ECR pulls and OS package installs fail
  # with opaque S3 403s that look like networking faults.
  statement {
    sid    = "ReadOnlyEverywhereElse"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = ["*"]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids

  policy = var.restrict_endpoint_policy ? data.aws_iam_policy_document.s3[0].json : null

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3-gateway"
  })
}
