# Shared customer-managed KMS key for data at rest.
#
# One key per environment rather than one per data store. Per-store keys give
# finer blast-radius isolation, but each carries a fixed $1/month charge and the
# isolation only pays off when different stores have genuinely different access
# populations. At dev scale that is paying for separation nobody enforces —
# prod can split later, which is a key-policy change plus a re-encrypt, not a
# redesign.

locals {
  key_name = "${var.name_prefix}-${var.alias}"

  # kms:ViaService takes fully-qualified regional service principals.
  via_service_principals = [for s in var.via_services : "${s}.${var.region}.amazonaws.com"]
}

data "aws_iam_policy_document" "key" {
  # ACCEPTED RISK — reviewed, not ignored. Two distinct reasons.
  #
  # CKV_AWS_356 ("* as a statement's resource") is structurally unavoidable in
  # ANY KMS key policy: Resource refers to the key the policy is attached to,
  # and naming the key's own ARN here is self-referential — Terraform cannot
  # resolve it without a cycle. Every valid key policy AWS publishes uses "*".
  #
  # CKV_AWS_109/111 flag the root delegation below. A KMS key policy is
  # AUTHORITATIVE: unlike almost every other AWS resource, IAM permissions alone
  # do not grant access to a key. Omit the delegation and the key becomes
  # permanently unmanageable the moment the administering principal is deleted,
  # with no recovery path and the encrypted data lost with it.
  #
  # Compensating controls: the delegation confers nothing on its own — it defers
  # to IAM, where the exec role holds only scoped KMS actions. Data-plane access
  # is separately confined by kms:ViaService + kms:CallerAccount, so no principal
  # can call Decrypt directly against this key. Asserted in tests/integration/
  # test_kms.py.
  #checkov:skip=CKV_AWS_356:KMS key policies are self-referential; "*" is the only expressible resource
  #checkov:skip=CKV_AWS_109:Root delegation is AWS's documented anti-lockout requirement; access is decided by IAM and confined by kms:ViaService
  #checkov:skip=CKV_AWS_111:Same — omitting it makes the key permanently unmanageable if the administering principal is deleted

  # --- Anti-lockout -------------------------------------------------------
  # A KMS key policy is authoritative: unlike most resources, IAM permissions
  # alone do NOT grant access to a key. Without this delegation the key can
  # become permanently unmanageable if the administering principal is deleted,
  # and AWS provides no way back. This statement does not hand out access —
  # kms:* to the account root means "defer the decision to IAM policies", which
  # is precisely how the exec role's scoped KMS grants take effect.
  statement {
    sid    = "EnableIAMPolicyDelegation"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # --- Data-plane use, only through AWS services --------------------------
  # kms:ViaService is the control that matters here: a principal cannot call
  # Decrypt directly against this key. Only the listed services may, and only
  # while acting for a caller in this account. So a leaked role credential
  # cannot bulk-decrypt ciphertext outside the service path that produced it.
  statement {
    sid    = "AllowUseViaAwsServices"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = local.via_service_principals
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.account_id]
    }
  }

  # --- Grant management for AWS services ----------------------------------
  # Services such as RDS, EBS and Backup create grants on the caller's behalf
  # when they attach an encrypted volume or snapshot. Without this they fail
  # with a KMSGrantMissing-style error at resource-creation time.
  statement {
    sid    = "AllowServiceGrants"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  # --- AWS log delivery ---------------------------------------------------
  # VPC flow logs / ALB access logs written to an SSE-KMS bucket are encrypted
  # by the log-delivery service using its OWN principal, so kms:ViaService does
  # not cover it (the caller is AWS, not a principal in this account).
  #
  # Omitting this does not produce an error: AWS reports the flow log as active
  # and silently writes nothing. That failure mode is why step 3's verification
  # asserts an object actually landed, not merely that the resource exists.
  dynamic "statement" {
    for_each = var.allow_aws_log_delivery ? [1] : []

    content {
      sid    = "AllowAwsLogDelivery"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }

      actions = [
        "kms:GenerateDataKey*",
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [var.account_id]
      }
    }
  }

  # --- CloudWatch Logs ----------------------------------------------------
  # Logs calls KMS with its OWN service principal rather than on behalf of the
  # requester, so kms:ViaService above does not cover it. Scoped by encryption
  # context to log groups in this account and region, so the grant cannot be
  # used against log groups elsewhere.
  dynamic "statement" {
    for_each = var.allow_cloudwatch_logs ? [1] : []

    content {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["logs.${var.region}.amazonaws.com"]
      }

      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]
      resources = ["*"]

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:*"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description = var.description

  # Symmetric SYMMETRIC_DEFAULT: the only spec S3/EBS/RDS/Logs server-side
  # encryption accepts. Asymmetric keys are for signing, not storage.
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"

  deletion_window_in_days = var.deletion_window_days
  enable_key_rotation     = var.enable_rotation
  rotation_period_in_days = var.enable_rotation ? var.rotation_period_days : null

  policy = data.aws_iam_policy_document.key.json

  tags = merge(var.tags, {
    Name = local.key_name
  })
}

# Stable name for the key. Everything downstream references the alias, never
# the key id — so a future key rotation or replacement does not require editing
# every consumer.
resource "aws_kms_alias" "this" {
  name          = "alias/${local.key_name}"
  target_key_id = aws_kms_key.this.key_id
}
