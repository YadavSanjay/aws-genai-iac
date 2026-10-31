# Terraform execution role for the aws-genai-iac control plane.
#
# Design (see docs/runbooks/terraform-execution-role.md):
#   * Power lives on a ROLE, not a long-lived user. Humans/CI assume it for
#     short-lived credentials — no static access keys on disk.
#   * The role can manage the service surface the four subsystems actually use
#     (docs/design/aws-service-consolidation.md); managed AI services are absent
#     on purpose, so they are absent here too.
#   * It can create the per-tier app roles, but ONLY if each carries the
#     permissions boundary this module also defines — that is what stops
#     "Terraform mints a role more powerful than itself" escalation.
#   * A deny guardrail fences off account/org/IAM-user actions and protects the
#     exec role + boundary from self-modification.

locals {
  prefix         = var.name_prefix
  scoped_role    = "arn:aws:iam::${var.account_id}:role/${local.prefix}-*"
  scoped_profile = "arn:aws:iam::${var.account_id}:instance-profile/${local.prefix}-*"
  scoped_policy  = "arn:aws:iam::${var.account_id}:policy/${local.prefix}-*"
  exec_role_arn  = "arn:aws:iam::${var.account_id}:role/${local.prefix}-terraform-exec"
  # Constructed (not resource-referenced) to avoid a self-cycle in the guardrail doc.
  guardrail_arn = "arn:aws:iam::${var.account_id}:policy/${local.prefix}-tf-guardrail"
  boundary_arn  = aws_iam_policy.app_boundary.arn

  # Who may assume the exec role. A tfuser in assume-role mode is auto-trusted.
  user_trusted     = var.create_terraform_user && var.user_access_mode == "assume-role" ? [aws_iam_user.tf[0].arn] : []
  explicit_trusted = concat(var.trusted_principal_arns, local.user_trusted)
  # Fall back to account root ONLY when nothing else is trusted (no explicit
  # principals and no auto-trusted tfuser). Root widens the trust to every
  # principal in the account, so it must never be added just because
  # trusted_principal_arns happens to be empty while a tfuser exists. The
  # precondition on aws_iam_role.exec forces require_mfa in that degenerate case.
  trusted = length(local.explicit_trusted) > 0 ? local.explicit_trusted : ["arn:aws:iam::${var.account_id}:root"]

  # The five customer-managed policies — attached to the exec role, and to the
  # tfuser directly when user_access_mode = "direct-attach".
  managed_policies = {
    compute_net = aws_iam_policy.compute_net.arn
    data_ops    = aws_iam_policy.data_ops.arn
    iam_manage  = aws_iam_policy.iam_manage.arn
    state       = aws_iam_policy.state.arn
    guardrail   = aws_iam_policy.guardrail.arn
  }

  # Services the app roles get PassRole'd to when Terraform launches them.
  pass_role_services = [
    "ec2.amazonaws.com",
    "ecs-tasks.amazonaws.com",
    "ecs.amazonaws.com",
    "application-autoscaling.amazonaws.com",
    "scheduler.amazonaws.com",
    "backup.amazonaws.com",
    "monitoring.rds.amazonaws.com", # RDS enhanced monitoring
    "vpc-flow-logs.amazonaws.com",  # VPC flow logs delivery
    "events.amazonaws.com",         # EventBridge target invocation
  ]

  # AWS service-linked roles a fresh account may need created on first apply.
  service_linked_roles = [
    "ecs.amazonaws.com",
    "elasticloadbalancing.amazonaws.com",
    "ecs.application-autoscaling.amazonaws.com",
    "autoscaling.amazonaws.com",
    "spot.amazonaws.com",
    "spotfleet.amazonaws.com",
    "rds.amazonaws.com",
    # Cloud Map creates AWSServiceRoleForServiceDiscovery on first namespace
    # creation (it does not exist yet on this account).
    "servicediscovery.amazonaws.com",
  ]
}

# --------------------------------------------------------------------------
# Trust policy — who may assume the exec role
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.trusted
    }

    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []
      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "exec" {
  name                 = "${local.prefix}-terraform-exec"
  description          = "Terraform/Terragrunt execution role for aws-genai-iac. Assume for short-lived creds; do not attach to a user."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = var.max_session_seconds
  tags                 = var.tags

  lifecycle {
    # A bare account-root trust (no explicit principals, no tfuser) is only safe
    # if MFA is required — otherwise any account principal with sts:AssumeRole
    # inherits the exec role's power. Enforce the module's own guidance.
    precondition {
      condition     = length(local.explicit_trusted) > 0 || var.require_mfa
      error_message = "Exec-role trust would fall back to account root. Set require_mfa = true, or provide trusted_principal_arns / create the tfuser (create_terraform_user = true, user_access_mode = \"assume-role\")."
    }
  }
}

# --------------------------------------------------------------------------
# 1. Compute / network / edge
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "compute_net" {
  # ACCEPTED RISK — reviewed, not ignored.
  #
  # checkov evaluates each policy document in isolation and cannot see the two
  # things that actually contain this one:
  #   1. aws_iam_policy.guardrail, a DENY attached to the same role, which fences
  #      off the account/org/IAM-user surface and exec-role self-modification.
  #   2. The aws:RequestedRegion condition below, which confines every grant to
  #      the operating region.
  #
  # The wildcards are also not narrowable in a useful way: ec2:CreateVpc,
  # elasticloadbalancing:CreateLoadBalancer and friends are create-time actions
  # whose resource does not exist yet, so there is no ARN to scope to. route53
  # and acm are global services that accept no region condition.
  #
  # Compensating control: tests/integration/test_exec_role_containment.py proves
  # the containment with AWS's own policy evaluator — 12 escalation actions
  # confirmed explicitDeny, and role creation refused unless it carries our
  # permissions boundary. That is evidence checkov structurally cannot produce.
  #checkov:skip=CKV_AWS_111:Create-time actions have no ARN to scope to; contained by the guardrail deny + aws:RequestedRegion. Proven by test_exec_role_containment.py
  #checkov:skip=CKV_AWS_356:Same — resource "*" is the only expressible form for ec2/elb/ecs create actions and for global route53/acm
  statement {
    sid    = "RegionalCompute"
    effect = "Allow"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "application-autoscaling:*",
      "ecs:*",
      "ecr:*",
      # AWS Cloud Map — private DNS service discovery for backend Fargate
      # services (RagInference at raginference.<namespace>, later Qdrant). Also
      # needs route53 (granted globally below) and its service-linked role
      # (allowed by name in local.service_linked_roles).
      "servicediscovery:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # route53 is a global service; acm certs live in-region with the ALB.
  statement {
    sid       = "GlobalEdge"
    effect    = "Allow"
    actions   = ["route53:*", "acm:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "compute_net" {
  name        = "${local.prefix}-tf-compute-net"
  description = "Terraform: compute, networking and edge surface for aws-genai-iac."
  policy      = data.aws_iam_policy_document.compute_net.json
  tags        = var.tags
}

# --------------------------------------------------------------------------
# 2. Data stores + operational services
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "data_ops" {
  # ACCEPTED RISK — reviewed, not ignored. See the note on compute_net above.
  #
  # What remains on resource "*" after scoping:
  #   - RegionalDataAndOps (rds/backup/dynamodb/sqs/logs/cloudwatch/sns/...):
  #     create-time actions with no pre-existing ARN, confined by
  #     aws:RequestedRegion.
  #   - S3AccountRead: s3:ListAllMyBuckets and s3:GetAccountPublicAccessBlock
  #     accept no resource ARN at all. Read-only.
  #   - GlobalBilling: budgets/ce/cur are account-level APIs that take no ARN.
  #
  # NOT accepted, and fixed rather than skipped: this document previously
  # granted s3:* on "*", letting a single assumable identity delete any bucket
  # in the account. It is now ARN-scoped to the project's own buckets, with the
  # state bucket deliberately excluded (it has its own narrow policy). That fix
  # cleared checkov's CKV_AWS_108 data-exfiltration and CKV_AWS_109 findings —
  # evidence the check was pointing at something real.
  #checkov:skip=CKV_AWS_111:Regional create-time actions have no ARN to scope to; confined by aws:RequestedRegion and the guardrail deny
  #checkov:skip=CKV_AWS_356:Remaining "*" grants (ListAllMyBuckets, budgets/ce/cur) accept no resource ARN
  # Regional data + operational services — locked to the operating region so the
  # exec role can't stand up shadow infra (or dodge the blast-radius lock) in
  # another region. Mirrors the aws:RequestedRegion guard on compute_net.
  statement {
    sid    = "RegionalDataAndOps"
    effect = "Allow"
    actions = [
      "rds:*",
      "backup:*",
      "dynamodb:*",
      "sqs:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "scheduler:*",
      "events:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # S3 is a global namespace, so no RequestedRegion lock — but the grant IS
  # ARN-scoped to the project's own buckets. It previously read s3:* on "*",
  # which let this single assumable identity delete any bucket in the account.
  #
  # The remote-state bucket is deliberately NOT covered here: it has its own
  # narrow policy (aws_iam_policy.state) granting object read/write and nothing
  # else, so data_ops cannot destroy the state backend it depends on.
  statement {
    sid     = "ProjectBuckets"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${local.prefix}-*",
      "arn:aws:s3:::${local.prefix}-*/*",
    ]
  }

  # Account-level S3 operations that take no bucket ARN and so cannot be
  # scoped. Read-only — they list or describe, never mutate.
  statement {
    sid    = "S3AccountRead"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetAccountPublicAccessBlock",
    ]
    resources = ["*"]
  }

  # Billing/cost APIs run only from the us-east-1 global endpoint and are
  # account-scoped by nature — they accept no resource ARN, so "*" is the only
  # expressible form.
  statement {
    sid    = "GlobalBilling"
    effect = "Allow"
    actions = [
      "budgets:*",
      "ce:*",
      "cur:*",
    ]
    resources = ["*"]
  }

  # Secrets: manage only the project's own (genai-*) secrets. Stops the exec role
  # — a single assumable identity — from reading every secret in the account.
  statement {
    sid    = "ScopedSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:RestoreSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:DeleteResourcePolicy",
      "secretsmanager:RotateSecret",
      "secretsmanager:CancelRotateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${local.prefix}-*"]
  }

  # RDS-managed master-user secrets (manage_master_user_password) live under the
  # AWS-reserved "rds!" prefix, outside genai-*. RDS creates the secret AS THE
  # CALLER during CreateDBInstance, so the exec role needs CreateSecret/TagResource
  # on that prefix — narrow, since only RDS ever uses "rds!". No GetSecretValue: the
  # password never touches Terraform state or this role's reads; the app tier reads
  # it directly at runtime via its own grant. This is what keeps the DB credential
  # out of state while still letting Terraform provision the instance.
  statement {
    sid    = "RdsManagedSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:rds!*"]
  }

  # ListSecrets returns no secret material and is needed for plan/refresh.
  statement {
    sid       = "SecretsListForPlan"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }

  # KMS: create/read/use is broad (a fresh key's ARN is a UUID, unknown at
  # policy-write time), but the destructive / policy-rewriting verbs are gated to
  # project-tagged keys so the exec role can't delete or re-police an unrelated CMK.
  statement {
    sid    = "KmsCreateAndUse"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      "kms:ListAliases",
      "kms:ListKeys",
      "kms:ListResourceTags",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:EnableKey",
      "kms:EnableKeyRotation",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Read-only SSM, for post-apply verification of instances.
  #
  # "Is this instance a registered managed node?" is the single check that
  # proves an instance's IAM role, the permissions boundary and the SSM agent
  # all work together — everything else only reads configuration back. Without
  # it the check can run solely as readonlyagent through MCP, which pytest
  # cannot reach, so it stays a manual step forever.
  #
  # Strictly read-only: no SendCommand, no StartSession, no parameter access.
  # This grants the ability to OBSERVE managed nodes, not to act on them.
  statement {
    sid    = "ReadSsmForVerification"
    effect = "Allow"
    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeInstancePatchStates",
      "ssm:DescribeInstancePatches",
      "ssm:ListTagsForResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Grants for AWS services, and ONLY for AWS services.
  #
  # Several services attach a KMS grant on the caller's behalf when they start
  # using a CMK — ECR does this at CreateRepository, and RDS, EBS and Backup do
  # the equivalent. Without kms:CreateGrant the call fails with a KmsException
  # that names the missing action but not why the service wanted it.
  #
  # kms:GrantIsForAWSResource is doing real work here, not decoration. An
  # unconstrained kms:CreateGrant is an escalation path: a grant can delegate
  # key use to an arbitrary principal, so a role holding it could hand decrypt
  # rights to anything. The condition restricts it to grants an AWS service
  # creates for its own resources.
  #
  # The key policy already permits this (AllowServiceGrants, gated on the same
  # condition). Both sides are required — a key policy allowing the account does
  # not by itself grant the principal.
  statement {
    sid    = "KmsGrantsForAwsResourcesOnly"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RevokeGrant",
    ]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid    = "KmsDestructiveProjectOnly"
    effect = "Allow"
    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:DisableKey",
      "kms:DisableKeyRotation",
      "kms:PutKeyPolicy",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["aws-genai-iac"]
    }
  }
}

resource "aws_iam_policy" "data_ops" {
  name        = "${local.prefix}-tf-data-ops"
  description = "Terraform: data stores, messaging, secrets, observability and cost surface for aws-genai-iac."
  policy      = data.aws_iam_policy_document.data_ops.json
  tags        = var.tags
}

# --------------------------------------------------------------------------
# 3. IAM management — the sensitive one, boundary-constrained
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "iam_manage" {
  # ACCEPTED RISK — reviewed, not ignored.
  #
  # Every statement that CAN be ARN-scoped already is: role, instance-profile
  # and policy lifecycle ops are confined to genai-* (local.scoped_role /
  # local.scoped_policy), and CreateRole additionally requires our permissions
  # boundary via an iam:PermissionsBoundary condition.
  #
  # The three that remain on "*" cannot be scoped by construction:
  #   - ReadIamForPlan (iam:Get*/List*/Simulate*) — read-only, and Terraform
  #     must be able to refresh arbitrary IAM state during plan.
  #   - CreateServiceLinkedRole — scoped instead by iam:AWSServiceName condition.
  #   - PassRole — scoped by resource AND by iam:PassedToService condition.
  #
  # Compensating control: test_exec_role_containment.py proves via
  # iam:SimulatePrincipalPolicy that CreateRole is refused without our boundary
  # and refused with AdministratorAccess as the boundary.
  #checkov:skip=CKV_AWS_356:Read-only IAM for plan, plus CreateServiceLinkedRole/PassRole which are condition-scoped rather than ARN-scoped
  # Creating/boundary-setting a role is allowed ONLY when the boundary is ours.
  statement {
    sid       = "CreateRoleWithBoundary"
    effect    = "Allow"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = [local.scoped_role]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  # Remaining lifecycle ops on genai-* roles / instance profiles.
  statement {
    sid    = "ManageScopedRoles"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = [local.scoped_role, local.scoped_profile]
  }

  # Customer-managed policies under the genai-* namespace.
  statement {
    sid    = "ManageScopedPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.scoped_policy]
  }

  # Read-only IAM is needed for plan/refresh and is safe account-wide.
  #
  # iam:Simulate* is included so post-apply verification can run NEGATIVE policy
  # tests automatically — asserting that what should be denied IS denied, using
  # AWS's own policy evaluator rather than a comment claiming it. Without it the
  # only principal that can simulate is readonlyagent via MCP, which pytest
  # cannot reach, so negative tests stay manual.
  #
  # Marginal disclosure is zero: iam:Get*/List* above already exposes every
  # policy document in the account. Simulate* just evaluates those same
  # documents with AWS's engine instead of ours. Both actions are read-only and
  # both appear in the AWS-managed ReadOnlyAccess policy. Neither matches any
  # pattern in the guardrail deny (iam:*User*, iam:*AccessKey*, ...).
  statement {
    sid    = "ReadIamForPlan"
    effect = "Allow"
    actions = [
      "iam:Get*",
      "iam:List*",
      "iam:SimulatePrincipalPolicy",
      "iam:SimulateCustomPolicy",
    ]
    resources = ["*"]
  }

  # PassRole only to the app roles, and only to the services that launch them.
  statement {
    sid       = "PassScopedRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.scoped_role]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = local.pass_role_services
    }
  }

  # Let the relevant AWS services create their own service-linked roles on a
  # fresh account. Scoped by service name — cannot create arbitrary roles.
  statement {
    sid       = "CreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = local.service_linked_roles
    }
  }
}

resource "aws_iam_policy" "iam_manage" {
  name        = "${local.prefix}-tf-iam"
  description = "Terraform: create/manage the per-tier app roles, boundary-constrained to prevent escalation."
  policy      = data.aws_iam_policy_document.iam_manage.json
  tags        = var.tags
}

# --------------------------------------------------------------------------
# 4. Remote-state backend (created out-of-band; role only reads/writes state)
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "state" {
  # Covers both the state object and its sibling `<key>.tflock` lock object —
  # the backend uses S3-native locking, so there is no separate lock grant.
  statement {
    sid       = "StateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }
  statement {
    sid       = "StateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_policy" "state" {
  name        = "${local.prefix}-tf-state"
  description = "Terraform: read/write remote state + lock. No backend-creation rights."
  policy      = data.aws_iam_policy_document.state.json
  tags        = var.tags
}

# --------------------------------------------------------------------------
# 5. Deny guardrail — account/org/user surface + self-protection
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "guardrail" {
  statement {
    sid    = "DenyAccountAndUsers"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:*",
      "iam:*User*",
      "iam:*AccessKey*",
      "iam:*LoginProfile*",
      "iam:CreateAccountAlias",
      "iam:DeleteAccountAlias",
      "iam:*SAMLProvider*",
      "iam:*OpenIDConnectProvider*",
      "iam:UpdateAccountPasswordPolicy",
    ]
    resources = ["*"]
  }

  # The exec role, its own policies, and the boundary are off-limits to itself.
  #
  # EXPECTED PLAN ARTIFACT: whenever any policy referenced below is changing,
  # `terraform plan` reports THIS policy as "will be updated in-place" too, and
  # may render its whole document as (known after apply). That is because the
  # provider treats the referenced .arn attributes as not-yet-known while those
  # resources are being updated, so this document cannot be rendered at plan
  # time. At apply the ARNs resolve unchanged, the document is byte-identical,
  # and nothing is written — verified 2026-07-21: the live policy was still v1
  # with UpdateDate == CreateDate after three iam-baseline applies.
  #
  # Do NOT "fix" this by substituting constructed ARN strings. It would silence
  # the diff at the cost of a security policy that silently drifts if a policy
  # is ever renamed. The resource references are self-maintaining; the phantom
  # diff is cosmetic.
  statement {
    sid    = "ProtectSelfAndBoundary"
    effect = "Deny"
    actions = [
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
    ]
    resources = [
      local.exec_role_arn,
      local.guardrail_arn,
      aws_iam_policy.compute_net.arn,
      aws_iam_policy.data_ops.arn,
      aws_iam_policy.iam_manage.arn,
      aws_iam_policy.state.arn,
      aws_iam_policy.app_boundary.arn,
    ]
  }

  # An app role must never have its boundary stripped.
  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = [local.scoped_role]
  }
}

resource "aws_iam_policy" "guardrail" {
  name        = "${local.prefix}-tf-guardrail"
  description = "Terraform: explicit denies for account/org/user actions and exec-role self-modification."
  policy      = data.aws_iam_policy_document.guardrail.json
  tags        = var.tags
}

# --------------------------------------------------------------------------
# Permissions boundary applied to EVERY app role Terraform creates
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "app_boundary" {
  # ACCEPTED RISK — and here checkov is making a category error, not finding a
  # weakness.
  #
  # This document is a PERMISSIONS BOUNDARY, not a grant. A boundary defines the
  # MAXIMUM privilege a role may ever hold; it confers nothing by itself. An
  # identity is limited to the INTERSECTION of its boundary and its policies, so
  # a role with this boundary and no policies can do precisely nothing.
  #
  # checkov evaluates it as though it were an attached grant, which inverts the
  # meaning: findings like "allows write access without constraints" describe
  # the ceiling, not an entitlement. A boundary narrow enough to satisfy these
  # checks would break every app role it is meant to cap — the boundary must be
  # at least as wide as the union of what the app tiers legitimately need.
  #
  # The security property that matters is enforced elsewhere and IS tested:
  # iam_manage permits CreateRole only when iam:PermissionsBoundary equals this
  # document's ARN, so Terraform cannot mint a role outside the ceiling. See
  # test_exec_role_containment.py — refused without a boundary, refused with
  # AdministratorAccess, allowed only with ours.
  #checkov:skip=CKV_AWS_107:Permissions boundary, not a grant — it caps privilege rather than conferring it
  #checkov:skip=CKV_AWS_109:Same — a boundary narrow enough to pass would break the app roles it exists to cap
  #checkov:skip=CKV_AWS_111:Same — this is the ceiling, not an entitlement
  #checkov:skip=CKV_AWS_356:Same — boundaries are expressed against "*" because they bound actions, not resources
  # Object/data-plane access, confined to the project's own resource namespace
  # (${local.prefix}-*). An app role can never be granted access to a
  # bucket/queue/secret outside the project — including the Terraform state bucket.
  statement {
    sid    = "RuntimeObjectStore"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "arn:aws:s3:::${local.prefix}-*",
      "arn:aws:s3:::${local.prefix}-*/*",
    ]
  }

  statement {
    sid    = "RuntimeMessaging"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ChangeMessageVisibility",
    ]
    resources = ["arn:aws:sqs:${var.region}:${var.account_id}:${local.prefix}-*"]
  }

  statement {
    sid    = "RuntimeSecretsAndConfig"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${local.prefix}-*",
      "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${local.prefix}/*",
      "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${local.prefix}-*",
    ]
  }

  # RDS-managed master-user secrets (manage_master_user_password) live under the
  # AWS-reserved "rds!" prefix, OUTSIDE the genai-* namespace above. An app tier
  # backed by RDS reads its DB credential from that secret at boot (the bootstrap
  # fetches it as the instance role), so the boundary must permit GetSecretValue
  # there too — read-only, and only that prefix. Without this the app role is
  # capped away from its own DB password and the stack never starts. The role's
  # own policy still scopes to the one specific rds! secret; this is the ceiling.
  statement {
    sid       = "RuntimeRdsManagedSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:rds!*"]
  }

  # Crypto, registry pull, telemetry, DB-auth — actions that take no resource
  # scope (or whose ARNs aren't known at policy time). Read-only or additive.
  #
  # The KMS set is what an encrypted-EBS instance START requires, not just data
  # decryption: when EventBridge Scheduler starts an instance whose root/data
  # volume is a CMK, EC2 must Decrypt + GenerateDataKey + ReEncrypt + DescribeKey
  # the volume IN THE CALLER'S CONTEXT (the scheduler role), and the boundary caps
  # every role Terraform creates. Without ReEncrypt*/DescribeKey here the start
  # dies with `Client.InvalidKMSKey` and the instance stops seconds after
  # launching — a silent failure that reads as "the schedule didn't fire" when it
  # did. CreateGrant is the other half, in its own gated statement below.
  statement {
    sid    = "RuntimePlatform"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
      "kms:DescribeKey",
      "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "cloudwatch:PutMetricData",
      "rds-db:connect",
      "ec2:Describe*",
    ]
    resources = ["*"]
  }

  # Grant creation for AWS-service-managed encryption, gated to service resources.
  #
  # Starting an instance with a CMK-encrypted EBS volume makes EC2 create a grant
  # on the key for the volume; the caller (here the scheduler role) needs
  # kms:CreateGrant or the start fails with `Client.InvalidKMSKey`. This is the
  # boundary ceiling, not a grant — a role still needs the action in its own
  # policy. kms:GrantIsForAWSResource is load-bearing: an unconstrained CreateGrant
  # is an escalation path (a grant can delegate key use to an arbitrary principal),
  # so this caps it to grants AWS services create on the caller's behalf.
  statement {
    sid    = "RuntimeKmsGrantsForAwsResources"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:ListGrants",
    ]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  # Instance start/stop, for scheduled shutdown.
  #
  # Scale-to-zero is a core cost decision (design doc §2), and it needs a role
  # that EventBridge Scheduler can assume to stop and start instances. Every
  # role Terraform creates carries this boundary, so without these actions the
  # scheduler role is capped to nothing and the schedule fires successfully
  # while changing nothing — a silent failure that presents as "the instance
  # never stopped" and shows up only on the bill.
  #
  # Tag-scoped rather than open: only instances carrying Project=aws-genai-iac
  # can be stopped or started. That keeps an app role, if one were ever granted
  # these actions, from touching unrelated instances in the account.
  #
  # Note this is deliberately NOT ec2:RebootInstances or ec2:TerminateInstances.
  # Stopping is recoverable; terminating is not.
  statement {
    sid    = "RuntimeInstanceScheduling"
    effect = "Allow"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["aws-genai-iac"]
    }
  }

  # Database start/stop, for the same scheduled-shutdown reason as instances.
  #
  # A stopped RDS instance stops billing compute (storage and backups continue),
  # so a dev database that is only useful while its app tier is up should follow
  # the same window. Without these actions the RDS scheduler role is capped to
  # nothing and fails exactly like the instance case above: the schedule fires,
  # reports success, and the database runs 24x7 anyway.
  #
  # Scoped by ARN rather than by tag, unlike the EC2 statement. DB identifiers
  # are ours and deterministic (<prefix>-<env>-<component>), where instance ids
  # are assigned by EC2 and unknowable at policy time — so the name prefix is
  # both a tighter bound and a more reliable one, since it does not depend on
  # the service populating aws:ResourceTag into the request context.
  #
  # Deliberately NOT rds:DeleteDBInstance, ModifyDBInstance or RebootDBInstance:
  # stopping is recoverable, deleting is not, and modifying could relax the very
  # posture (encryption, public access, backups) the module sets.
  #
  # No KMS actions beyond RuntimePlatform are needed here, and this is the
  # difference from an EC2 start: RDS decrypts its own storage under a standing
  # service grant created when the instance was created (verified on the project
  # CMK — grantee rds.<region>.amazonaws.com, retired by RDS), so the caller
  # never touches the storage key. The kms:Decrypt in RuntimePlatform covers the
  # only key operation the scheduler role performs: decrypting its own encrypted
  # target input at invocation time.
  statement {
    sid    = "RuntimeDatabaseScheduling"
    effect = "Allow"
    actions = [
      "rds:StartDBInstance",
      "rds:StopDBInstance",
    ]
    resources = ["arn:aws:rds:${var.region}:${var.account_id}:db:${local.prefix}-*"]
  }

  # SSM Session Manager and Patch Manager.
  #
  # This project has no SSH rule, no key pairs and no bastion — administrative
  # access to an instance is Session Manager, whose agent dials OUTBOUND and
  # needs no inbound rule at all. Without these actions in the boundary an
  # instance role carrying AmazonSSMManagedInstanceCore is capped to nothing,
  # and Session Manager fails in a way that looks like a networking problem
  # rather than a permissions one: the instance simply never appears as a
  # managed node.
  #
  # This is a BOUNDARY, so listing an action grants nothing on its own — a role
  # still needs its own policy allowing it. What this does is stop the boundary
  # from silently capping SSM away.
  #
  # None of these accept resource-level scoping; the ssmmessages and ec2messages
  # channels are session transports, not resources.
  statement {
    sid    = "RuntimeSsmManagedNode"
    effect = "Allow"
    actions = [
      # Session Manager transport.
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      # Agent <-> SSM control plane.
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
      # Registration, inventory and patch compliance.
      "ssm:UpdateInstanceInformation",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:DescribeAssociation",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:PutInventory",
      "ssm:PutComplianceItems",
      "ssm:GetDocument",
      "ssm:DescribeDocument",
    ]
    resources = ["*"]
  }

  # Belt-and-suspenders: the state bucket is never named ${local.prefix}-*, but
  # deny it explicitly so no future boundary edit can ever expose Terraform
  # state to an app role. With S3-native locking the lock object lives in this
  # same bucket, so this one statement now covers state AND locks.
  statement {
    sid    = "DenyStateBucket"
    effect = "Deny"
    actions = [
      "s3:*",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket}",
      "arn:aws:s3:::${var.state_bucket}/*",
    ]
  }

  # Hard ceiling: an app role can never touch IAM/org/account or hop to another
  # role, so a created role can never be used to escalate — regardless of its
  # own inline policy.
  statement {
    sid    = "BoundaryDenyEscalation"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
      "sts:AssumeRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "app_boundary" {
  name        = "${local.prefix}-app-boundary"
  description = "Permissions boundary for app roles created by Terraform. Referenced by ${local.prefix}-tf-iam; do not delete."
  policy      = data.aws_iam_policy_document.app_boundary.json
  tags        = var.tags
}

# --------------------------------------------------------------------------
# Attach the five managed policies to the exec role
# --------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "exec" {
  for_each   = local.managed_policies
  role       = aws_iam_role.exec.name
  policy_arn = each.value
}

# --------------------------------------------------------------------------
# Optional dedicated Terraform IAM user (tfuser)
# --------------------------------------------------------------------------
# Created by the admin apply of this component (the exec role's guardrail denies
# iam:*User*, so the exec role can never create or modify it). Access keys are
# NOT managed here — run `aws iam create-access-key --user-name <name>` so the
# secret never lands in Terraform state.
resource "aws_iam_user" "tf" {
  count = var.create_terraform_user ? 1 : 0
  name  = var.terraform_user_name
  tags  = var.tags
}

# assume-role mode: the user holds ONLY the right to assume the exec role.
data "aws_iam_policy_document" "user_assume" {
  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.exec.arn]
  }
}

resource "aws_iam_user_policy" "tf_assume" {
  count  = var.create_terraform_user && var.user_access_mode == "assume-role" ? 1 : 0
  name   = "assume-${aws_iam_role.exec.name}"
  user   = aws_iam_user.tf[0].name
  policy = data.aws_iam_policy_document.user_assume.json
}

# direct-attach mode: the five scoped policies hang straight off the user.
#
# ACCEPTED RISK — and NOT INSTANTIATED in this deployment. checkov scans
# statically and cannot evaluate the for_each guard: this project runs
# user_access_mode = "assume-role", so the expression yields {} and no
# attachment is created. tfuser holds only sts:AssumeRole (see tf_assume above),
# which is the whole point — its long-lived keys carry no standing power.
#
# The finding is legitimate for anyone who switches to "direct-attach": that
# mode trades this control away for a simpler `--profile tfuser` flow, and the
# variable's own documentation says so. Keeping the skip here rather than in
# .checkov.yaml means the check still fires for every other module.
resource "aws_iam_user_policy_attachment" "tf_direct" {
  #checkov:skip=CKV_AWS_40:Not instantiated — user_access_mode is "assume-role", so for_each yields {}. The direct-attach path is a documented opt-in tradeoff.
  for_each   = var.create_terraform_user && var.user_access_mode == "direct-attach" ? local.managed_policies : {}
  user       = aws_iam_user.tf[0].name
  policy_arn = each.value
}
