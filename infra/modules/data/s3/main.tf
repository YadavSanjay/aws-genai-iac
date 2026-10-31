# Secure-by-default S3 bucket.
#
# There is no unencrypted, publicly-reachable, or lifecycle-free path through
# this module: SSE-KMS is required, public access is blocked unconditionally,
# TLS is enforced by policy, and incomplete multipart uploads always expire.
# Callers choose retention, not whether to have any.

resource "aws_s3_bucket" "this" {
  # ACCEPTED — but read the caveat, these are not category errors.
  #
  # CKV2_AWS_62 (event notifications): notifications are a workflow trigger, not
  # a security control. Enabling them with no consumer creates an SNS/SQS/Lambda
  # target that costs money and does nothing. Modules that need eventing should
  # attach it at the call site.
  #
  # CKV_AWS_144 (cross-region replication): a real DR control, deliberately not
  # taken. CRR roughly doubles storage cost and adds cross-region transfer, which
  # is not justified for dev. KNOWN GAP: this module does not implement
  # replication at all, so a prod bucket that genuinely needs DR requires
  # extending it — see the README. That is a limitation, not a decision that
  # replication is unnecessary everywhere.
  #checkov:skip=CKV2_AWS_62:Event notifications are a workflow trigger with no consumer here; attach at the call site if needed
  #checkov:skip=CKV_AWS_144:CRR roughly doubles cost and is not justified for dev. Module does not implement replication — see README "Known gaps".
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name = var.bucket_name
  })
}

# --- Public access: blocked unconditionally, not a variable ------------------
# Deliberately not configurable. A bucket in this project is never public; an
# exception would be a new module, not a flag on this one.
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Ownership: ACLs disabled ------------------------------------------------
# BucketOwnerEnforced switches off ACLs entirely, so access is governed only by
# policy and IAM. This closes the classic "public via object ACL" hole that a
# public access block alone does not.
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- Encryption at rest ------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # S3 Bucket Keys cut KMS request charges by up to 99% by deriving a
    # short-lived bucket-level key instead of calling KMS per object. No
    # security tradeoff; large cost difference on write-heavy buckets.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

# --- Lifecycle ---------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Ordering matters for the provider: versioning must settle first, otherwise
  # noncurrent-version rules can be rejected.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "baseline"
    status = "Enabled"

    filter {}

    # Always on. Orphaned multipart parts are invisible in the console and
    # billed as storage forever.
    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_upload_days
    }

    dynamic "transition" {
      for_each = var.transitions

      content {
        days          = transition.value.days
        storage_class = transition.value.storage_class
      }
    }

    dynamic "expiration" {
      for_each = var.expiration_days > 0 ? [1] : []

      content {
        days = var.expiration_days
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_expiration_days
    }
  }
}

# --- Access logging (optional) ----------------------------------------------
resource "aws_s3_bucket_logging" "this" {
  count = var.access_log_bucket != "" ? 1 : 0

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_log_bucket
  target_prefix = var.access_log_prefix
}

# --- Bucket policy -----------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "bucket" {
  source_policy_documents = var.extra_policy_documents

  # --- AWS log delivery ----------------------------------------------------
  # Two statements, both required. The ACL check is not optional: the delivery
  # service calls GetBucketAcl to confirm it may write, and without it delivery
  # fails at flow-log creation time.
  #
  # Note the ABSENCE of an s3:x-amz-acl = bucket-owner-full-control condition.
  # Most published examples include it, and it is wrong for this module:
  # BucketOwnerEnforced disables ACLs, the delivery service does not send that
  # header, and the condition would deny every write.
  dynamic "statement" {
    for_each = var.allow_aws_log_delivery ? [1] : []

    content {
      sid    = "AWSLogDeliveryAclCheck"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }

      actions   = ["s3:GetBucketAcl"]
      resources = [aws_s3_bucket.this.arn]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = var.allow_aws_log_delivery ? [1] : []

    content {
      sid    = "AWSLogDeliveryWrite"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }

      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.this.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  # Encryption in transit. Without this, a plain-HTTP request is accepted and
  # the object travels unprotected.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Refuse an upload that explicitly asks for something other than KMS. See the
  # note on var.restrict_encryption_header for why this is not the stricter
  # "deny any upload lacking the header" form.
  dynamic "statement" {
    for_each = var.restrict_encryption_header ? [1] : []

    content {
      sid    = "DenyNonKmsEncryption"
      effect = "Deny"

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.this.arn}/*"]

      condition {
        test     = "StringNotEquals"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["aws:kms"]
      }

      # Scope to requests that DID set the header — a null check here is what
      # keeps headerless (default-encrypted) uploads working.
      condition {
        test     = "Null"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["false"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # The public access block must exist first, or a policy referencing a
  # wildcard principal can be transiently rejected as "public".
  depends_on = [aws_s3_bucket_public_access_block.this]
}
