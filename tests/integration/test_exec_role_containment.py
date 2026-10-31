"""Negative policy tests: prove the exec role CANNOT escalate.

The provisioning principles require asserting that the thing which should be
denied is actually denied. This uses `iam:SimulatePrincipalPolicy` — AWS's own
policy evaluator — so the verdict comes from the same engine that authorizes
real calls, not from reading the HCL and hoping.

Simulation evaluates policy only; it creates nothing and touches no resource.

Requires `iam:Simulate*` on the exec role (`ReadIamForPlan` in
infra/modules/security/iam-terraform-role/main.tf). Without it these SKIP with
an explicit reason rather than passing silently.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import os
from typing import Any

import boto3
import pytest
from botocore.exceptions import ClientError

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX", "genai")
EXEC_ROLE_NAME = os.environ.get("IAC_EXEC_ROLE_NAME", f"{NAME_PREFIX}-terraform-exec")
GUARDRAIL_POLICY_NAME = f"{NAME_PREFIX}-tf-guardrail"
BOUNDARY_POLICY_NAME = f"{NAME_PREFIX}-app-boundary"
STATE_BUCKET = os.environ.get("IAC_STATE_BUCKET", "aws-genai-iac-tfstate")
FOREIGN_BUCKET = "some-unrelated-third-party-bucket"

# Escalation paths the guardrail exists to close. Each must evaluate to an
# EXPLICIT deny — "implicitDeny" would mean nothing actively denies the action,
# so widening an Allow later would silently open it.
MUST_BE_EXPLICITLY_DENIED = [
    # Minting a new identity outside the boundary.
    "iam:CreateUser",
    "iam:DeleteUser",
    "iam:AttachUserPolicy",
    "iam:PutUserPolicy",
    # Long-lived credentials.
    "iam:CreateAccessKey",
    "iam:UpdateAccessKey",
    "iam:CreateLoginProfile",
    "iam:UpdateLoginProfile",
    # Federation backdoors.
    "iam:CreateSAMLProvider",
    "iam:CreateOpenIDConnectProvider",
    # Account-level tampering.
    "iam:UpdateAccountPasswordPolicy",
    "iam:CreateAccountAlias",
]


@pytest.fixture(scope="module")
def iam_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("iam")


@pytest.fixture(scope="module")
def account_id() -> str:
    return str(boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"])


@pytest.fixture(scope="module")
def exec_role_arn(iam_client: Any) -> str:
    try:
        return str(iam_client.get_role(RoleName=EXEC_ROLE_NAME)["Role"]["Arn"])
    except ClientError as exc:
        pytest.fail(f"cannot read exec role {EXEC_ROLE_NAME!r}: {exc}")


@pytest.fixture(scope="module")
def boundary_arn(account_id: str) -> str:
    return f"arn:aws:iam::{account_id}:policy/{BOUNDARY_POLICY_NAME}"


@pytest.fixture(scope="module")
def target_role_arn(account_id: str) -> str:
    """A role that neither exists nor needs to — simulation is evaluation only."""
    return f"arn:aws:iam::{account_id}:role/{NAME_PREFIX}-escalation-test"


def _simulate(
    iam_client: Any,
    source_arn: str,
    action: str,
    resource_arn: str | None = None,
    boundary: str | None = None,
) -> str:
    """Return AWS's decision for one action, optionally with a boundary in context."""
    kwargs: dict[str, Any] = {"PolicySourceArn": source_arn, "ActionNames": [action]}
    if resource_arn:
        kwargs["ResourceArns"] = [resource_arn]
    if boundary:
        kwargs["ContextEntries"] = [
            {
                "ContextKeyName": "iam:PermissionsBoundary",
                "ContextKeyValues": [boundary],
                "ContextKeyType": "string",
            }
        ]
    try:
        resp = iam_client.simulate_principal_policy(**kwargs)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip(
                "iam:SimulatePrincipalPolicy not granted to the exec role. Apply "
                "the iam-baseline change (admin step). UNVERIFIED, not passing."
            )
        raise
    return str(resp["EvaluationResults"][0]["EvalDecision"])


def _simulate_with_context(
    iam_client: Any,
    source_arn: str,
    action: str,
    context_key: str,
    context_value: str,
    context_type: str = "string",
) -> str:
    """Simulate one action with a single arbitrary condition key in context."""
    try:
        resp = iam_client.simulate_principal_policy(
            PolicySourceArn=source_arn,
            ActionNames=[action],
            ContextEntries=[
                {
                    "ContextKeyName": context_key,
                    "ContextKeyValues": [context_value],
                    "ContextKeyType": context_type,
                },
                # The KMS statements are region-conditioned, so without this the
                # simulation reports a missing context value rather than a verdict.
                {
                    "ContextKeyName": "aws:RequestedRegion",
                    "ContextKeyValues": [REGION],
                    "ContextKeyType": "string",
                },
            ],
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip(
                "iam:SimulatePrincipalPolicy not granted to the exec role. Apply "
                "the iam-baseline change (admin step). UNVERIFIED, not passing."
            )
        raise
    return str(resp["EvaluationResults"][0]["EvalDecision"])


@pytest.fixture(scope="module")
def evaluations(iam_client: Any, exec_role_arn: str) -> dict[str, str]:
    try:
        resp = iam_client.simulate_principal_policy(
            PolicySourceArn=exec_role_arn, ActionNames=MUST_BE_EXPLICITLY_DENIED
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip(
                "iam:SimulatePrincipalPolicy not granted to the exec role. Apply "
                "the iam-baseline change (admin step). UNVERIFIED, not passing."
            )
        raise
    return {r["EvalActionName"]: r["EvalDecision"] for r in resp["EvaluationResults"]}


# --- The guardrail deny set --------------------------------------------------


@pytest.mark.parametrize("action", MUST_BE_EXPLICITLY_DENIED)
def test_escalation_action_is_explicitly_denied(evaluations: dict[str, str], action: str) -> None:
    decision = evaluations.get(action)
    assert decision is not None, f"{action} was not evaluated"
    assert decision == "explicitDeny", (
        f"{action} evaluates to {decision!r}, expected 'explicitDeny'. "
        "An implicitDeny means no guardrail statement covers this action — "
        "widening an Allow would silently open the escalation path."
    )


def test_exec_role_carries_the_guardrail_policy(iam_client: Any) -> None:
    """The exec role's own containment is the guardrail DENY policy.

    It has no permissions boundary of its own, and that is by design — the
    boundary constrains the app roles it *creates* (see below).
    """
    attached = {
        p["PolicyName"]
        for p in iam_client.list_attached_role_policies(RoleName=EXEC_ROLE_NAME)["AttachedPolicies"]
    }
    assert GUARDRAIL_POLICY_NAME in attached, (
        f"{GUARDRAIL_POLICY_NAME} is not attached to {EXEC_ROLE_NAME} — the exec "
        f"role is uncontained. Attached: {sorted(attached)}"
    )


# --- Escalation containment: "Terraform cannot mint a role more powerful than itself"
#
# These assert `implicitDeny`, unlike the tests above, and that difference is
# structural rather than sloppy: containment here comes from a CONDITIONED ALLOW
# (iam:CreateRole permitted only when iam:PermissionsBoundary equals ours), not
# from a Deny. With the condition unmet, no statement matches at all.
#
# Worth stating the tradeoff: a conditioned allow has no deny backstop, so a
# future broad `iam:*` Allow elsewhere would reopen this path. Catching that is
# precisely why these tests exist.


def test_cannot_create_role_without_a_permissions_boundary(
    iam_client: Any, exec_role_arn: str, target_role_arn: str
) -> None:
    decision = _simulate(iam_client, exec_role_arn, "iam:CreateRole", target_role_arn)
    assert decision == "implicitDeny", (
        f"exec role may create an UNBOUNDED role (decision: {decision}). "
        "Escalation containment is broken."
    )


def test_can_create_role_when_carrying_the_project_boundary(
    iam_client: Any, exec_role_arn: str, target_role_arn: str, boundary_arn: str
) -> None:
    """Positive control — proves the denials above come from the condition.

    Without this, a misspelled action name would make every negative test pass
    for entirely the wrong reason.
    """
    decision = _simulate(
        iam_client, exec_role_arn, "iam:CreateRole", target_role_arn, boundary=boundary_arn
    )
    assert decision == "allowed", (
        f"exec role cannot create a properly-bounded role (decision: {decision}) — "
        "provisioning of app roles will fail."
    )


# --- KMS grants --------------------------------------------------------------
#
# The exec role needs kms:CreateGrant because ECR, RDS, EBS and Backup attach a
# grant on the caller's behalf when they first use a CMK. Unconstrained, that is
# an escalation path: a grant can delegate key use to an arbitrary principal.
# kms:GrantIsForAWSResource confines it to grants an AWS service creates for its
# own resources.


def test_can_create_kms_grants_for_aws_resources(iam_client: Any, exec_role_arn: str) -> None:
    """Positive control — without this, ECR repository creation fails outright."""
    decision = _simulate_with_context(
        iam_client,
        exec_role_arn,
        "kms:CreateGrant",
        context_key="kms:GrantIsForAWSResource",
        context_value="true",
        context_type="boolean",
    )
    assert decision == "allowed", (
        f"exec role cannot create AWS-service KMS grants (decision: {decision}) — "
        "ECR, RDS, EBS and Backup will fail with a KmsException."
    )


def test_cannot_create_arbitrary_kms_grants(iam_client: Any, exec_role_arn: str) -> None:
    """The escalation this constraint exists to close.

    A grant delegates key use to a principal of the grantee's choosing. If the
    exec role could create grants outside the AWS-service path, it could hand
    decrypt rights on the project CMK to anything.
    """
    decision = _simulate_with_context(
        iam_client,
        exec_role_arn,
        "kms:CreateGrant",
        context_key="kms:GrantIsForAWSResource",
        context_value="false",
        context_type="boolean",
    )
    assert decision == "implicitDeny", (
        f"exec role may create arbitrary KMS grants (decision: {decision}). "
        "That delegates key use to any principal it chooses."
    )


# --- S3 blast radius --------------------------------------------------------
#
# data_ops previously granted s3:* on Resource "*". Simulation confirmed the
# exec role could delete arbitrary third-party buckets, read any object in the
# account, and — worst — delete the Terraform state bucket it depends on.
# The grant is now ARN-scoped to the project's own buckets, with the state
# bucket served by its own narrow object-level policy.


def test_cannot_touch_buckets_outside_the_project(iam_client: Any, exec_role_arn: str) -> None:
    """No blanket S3 reach. Covers both destruction and data exfiltration."""
    for action in ("s3:DeleteBucket", "s3:GetObject"):
        decision = _simulate(iam_client, exec_role_arn, action, f"arn:aws:s3:::{FOREIGN_BUCKET}")
        assert decision == "implicitDeny", (
            f"exec role may perform {action} on an unrelated bucket "
            f"(decision: {decision}). s3 grant is not ARN-scoped."
        )


def test_cannot_delete_the_state_bucket(iam_client: Any, exec_role_arn: str) -> None:
    """The exec role must not be able to destroy its own state backend."""
    decision = _simulate(
        iam_client, exec_role_arn, "s3:DeleteBucket", f"arn:aws:s3:::{STATE_BUCKET}"
    )
    assert decision == "implicitDeny", (
        f"exec role may DELETE the Terraform state bucket (decision: {decision}). "
        "A stray destroy or a compromised role would take the state with it."
    )


def test_state_backend_access_still_works(iam_client: Any, exec_role_arn: str) -> None:
    """Positive control for the narrowing above.

    Scoping s3 removed a blanket grant that was also masking the dedicated state
    policy. If that policy has a gap, Terraform loses its backend — so assert
    the object-level access the S3 backend actually needs.
    """
    for action in ("s3:GetObject", "s3:PutObject", "s3:DeleteObject"):
        decision = _simulate(
            iam_client,
            exec_role_arn,
            action,
            f"arn:aws:s3:::{STATE_BUCKET}/global/cost-guardrails/terraform.tfstate",
        )
        assert decision == "allowed", (
            f"exec role cannot {action} on remote state (decision: {decision}) — "
            "the S3 backend is broken."
        )


def test_project_buckets_remain_manageable(iam_client: Any, exec_role_arn: str) -> None:
    """Positive control: provisioning must still work after the narrowing."""
    decision = _simulate(
        iam_client, exec_role_arn, "s3:PutBucketPolicy", f"arn:aws:s3:::{NAME_PREFIX}-dev-data"
    )
    assert decision == "allowed", (
        f"exec role cannot manage its own project buckets (decision: {decision}) — "
        "the s3 scoping is too tight and provisioning will fail."
    )


def test_cannot_create_role_with_a_foreign_boundary(
    iam_client: Any, exec_role_arn: str, target_role_arn: str
) -> None:
    """The actual escalation attempt: mint a role bounded by AdministratorAccess."""
    decision = _simulate(
        iam_client,
        exec_role_arn,
        "iam:CreateRole",
        target_role_arn,
        boundary="arn:aws:iam::aws:policy/AdministratorAccess",
    )
    assert decision == "implicitDeny", (
        f"exec role may create a role bounded by AdministratorAccess "
        f"(decision: {decision}). This is a direct privilege-escalation path."
    )
