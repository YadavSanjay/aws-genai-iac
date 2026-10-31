# Secret containers — deliberately WITHOUT their values.
#
# This module creates aws_secretsmanager_secret and never
# aws_secretsmanager_secret_version. That is the whole point.
#
# A secret value placed in Terraform is a secret in the STATE FILE, in plaintext,
# forever — every historical version of it, readable by anyone who can read the
# bucket, and printed in plan output. Marking an output `sensitive` hides it from
# the console; it does nothing to the state. So the value is set out of band, by
# a human or a rotation function, and Terraform manages only the container,
# its encryption and its access policy.
#
# The practical consequence: an application cannot start until someone sets the
# value. That is intended — a missing secret should fail loudly at deploy time,
# not silently resolve to an empty string.

data "aws_caller_identity" "current" {}

resource "aws_secretsmanager_secret" "this" {
  # ACCEPTED — but this is a real finding for some credentials, not a blanket
  # dismissal, so read before copying it elsewhere.
  #
  # CKV2_AWS_57 wants automatic rotation. Rotation is not a generic operation:
  # it means calling the credential issuer's rotation API. For an RDS password
  # AWS ships a working rotator and rotation should absolutely be on. For a
  # third-party LLM API key there is no such thing — each vendor differs, and
  # several offer no rotation API at all.
  #
  # Enabling rotation without a working rotator is WORSE than leaving it off: the
  # secret reports itself as rotating while nothing happens, so a stale
  # credential looks managed. There is a test asserting rotation is not falsely
  # advertised.
  #
  # When a DB password lands here, it should carry rotation and this skip should
  # be narrowed rather than inherited.
  #checkov:skip=CKV2_AWS_57:Third-party API keys have no generic rotator; enabling rotation without one falsely reports the secret as managed. DB passwords must enable it.
  for_each = var.secrets

  name        = each.key
  description = each.value.description

  # Our CMK, not the AWS-managed aws/secretsmanager key. The managed key cannot
  # carry a scoped key policy and does not rotate on our schedule, so a secret
  # encrypted under it sits outside every control the KMS module establishes.
  kms_key_id = var.kms_key_arn

  recovery_window_in_days = var.recovery_window_days

  tags = merge(var.tags, {
    Name = each.key
  })
}

# --- Resource policy ---------------------------------------------------------
# A second gate in front of the values. With this attached, reading a secret
# requires BOTH an IAM grant and a principal matching one of these patterns, so
# an over-broad IAM policy elsewhere in the account cannot on its own expose it.
#
# PER SECRET: only the secrets that declare their own reader_role_arn_patterns
# get a policy, and each uses ITS OWN set. A single component-wide list would
# attach one application's reader set to another application's secret — locking
# the real owner out of its own credential.
data "aws_iam_policy_document" "reader" {
  for_each = {
    for name, cfg in var.secrets : name => cfg
    if length(cfg.reader_role_arn_patterns) > 0
  }

  statement {
    sid    = "DenyPrincipalsOutsideTheReaderSet"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]

    # Deny unless the caller matches one of this secret's permitted patterns.
    # Expressed as a deny-with-exception rather than a bare allow, so adding an
    # unrelated allow elsewhere cannot widen it.
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = each.value.reader_role_arn_patterns
    }
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  for_each = data.aws_iam_policy_document.reader

  secret_arn = aws_secretsmanager_secret.this[each.key].arn
  policy     = each.value.json

  # Without this AWS rejects a policy that would lock out every principal,
  # which is a useful guard while the reader set is still being worked out.
  block_public_policy = true
}
