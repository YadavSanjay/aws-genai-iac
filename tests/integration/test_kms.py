"""Post-apply verification for dev/10-security/kms against the LIVE AWS API.

A successful apply proves Terraform got a 200. It does not prove rotation is on,
that the alias resolves, or that the key policy actually confines decryption —
which is the whole reason the key exists. These check the real thing.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import json
import os
from typing import Any

import boto3
import pytest
from botocore.exceptions import ClientError

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
ENV_PREFIX = os.environ.get("IAC_ENV_PREFIX", "genai-dev")
ALIAS = f"alias/{ENV_PREFIX}-primary"

EXPECTED_ROTATION_DAYS = 365
EXPECTED_DELETION_WINDOW = 7

# Services permitted to use the key on a caller's behalf. Anything outside this
# set means the data plane was widened without review.
EXPECTED_VIA_SERVICES = {
    "s3",
    "secretsmanager",
    "ssm",
    "sns",
    "sqs",
    "logs",
    "ecr",
    "rds",
    "dynamodb",
    "backup",
    "ebs",
    "elasticfilesystem",
    # EventBridge Scheduler encrypts each schedule's target input at rest.
    "scheduler",
}


@pytest.fixture(scope="module")
def kms_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("kms")


@pytest.fixture(scope="module")
def key_id(kms_client: Any) -> str:
    """Resolve through the ALIAS, not a hardcoded id.

    Downstream modules reference the alias, so if the alias does not resolve
    the key is effectively missing regardless of whether it exists.
    """
    try:
        return str(kms_client.describe_key(KeyId=ALIAS)["KeyMetadata"]["KeyId"])
    except ClientError as exc:
        pytest.fail(f"alias {ALIAS!r} does not resolve — is the component applied? {exc}")


@pytest.fixture(scope="module")
def metadata(kms_client: Any, key_id: str) -> dict[str, Any]:
    return dict(kms_client.describe_key(KeyId=key_id)["KeyMetadata"])


@pytest.fixture(scope="module")
def key_policy(kms_client: Any, key_id: str) -> dict[str, Any]:
    doc = kms_client.get_key_policy(KeyId=key_id, PolicyName="default")["Policy"]
    return dict(json.loads(doc))


# --- Key configuration -------------------------------------------------------


def test_key_is_enabled_and_customer_managed(metadata: dict[str, Any]) -> None:
    assert metadata["Enabled"] is True
    assert metadata["KeyState"] == "Enabled"
    assert metadata["KeyManager"] == "CUSTOMER", "not a customer-managed key"
    assert metadata["Origin"] == "AWS_KMS"


def test_key_spec_supports_service_side_encryption(metadata: dict[str, Any]) -> None:
    """S3/EBS/RDS/Logs accept only symmetric SYMMETRIC_DEFAULT keys."""
    assert metadata["KeyUsage"] == "ENCRYPT_DECRYPT"
    assert metadata["KeySpec"] == "SYMMETRIC_DEFAULT"


def test_rotation_is_enabled_with_expected_period(kms_client: Any, key_id: str) -> None:
    status = kms_client.get_key_rotation_status(KeyId=key_id)
    assert status["KeyRotationEnabled"] is True, "automatic key rotation is OFF"
    assert status.get("RotationPeriodInDays") == EXPECTED_ROTATION_DAYS


def test_key_is_not_pending_deletion(metadata: dict[str, Any]) -> None:
    """Catches a scheduled deletion nobody noticed — the data is lost when it elapses."""
    assert "DeletionDate" not in metadata, (
        f"key is PENDING DELETION on {metadata.get('DeletionDate')}. "
        "Cancel with kms:CancelKeyDeletion before the window elapses."
    )


def test_alias_points_at_this_key(kms_client: Any, key_id: str) -> None:
    aliases = kms_client.list_aliases(KeyId=key_id)["Aliases"]
    names = {a["AliasName"] for a in aliases}
    assert ALIAS in names, f"{ALIAS} not attached to key {key_id}. Found: {names}"


def test_key_carries_mandatory_tags(kms_client: Any, key_id: str) -> None:
    tags = {t["TagKey"]: t["TagValue"] for t in kms_client.list_resource_tags(KeyId=key_id)["Tags"]}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"
    assert tags["ManagedBy"] == "terragrunt"


# --- Key policy: the control that actually matters ---------------------------


def _statements(policy: dict[str, Any], sid: str) -> list[dict[str, Any]]:
    return [s for s in policy["Statement"] if s.get("Sid") == sid]


def test_data_plane_use_is_confined_to_aws_services(key_policy: dict[str, Any]) -> None:
    """kms:ViaService is what stops a leaked credential bulk-decrypting.

    Without it, any principal with kms:Decrypt in IAM could call the key
    directly rather than only through the service that produced the ciphertext.
    """
    stmts = _statements(key_policy, "AllowUseViaAwsServices")
    assert stmts, "AllowUseViaAwsServices statement is missing"

    condition = stmts[0]["Condition"]["StringEquals"]
    via = condition.get("kms:ViaService")
    assert via, "no kms:ViaService condition — the key is directly callable"

    via_list = [via] if isinstance(via, str) else via
    services = {v.split(".", 1)[0] for v in via_list}
    assert services == EXPECTED_VIA_SERVICES, (
        f"kms:ViaService drift. Unexpected: {services - EXPECTED_VIA_SERVICES}, "
        f"missing: {EXPECTED_VIA_SERVICES - services}"
    )

    assert condition.get("kms:CallerAccount"), "no kms:CallerAccount condition"


def test_service_grants_require_an_aws_resource(key_policy: dict[str, Any]) -> None:
    """CreateGrant must not be open to arbitrary principals."""
    stmts = _statements(key_policy, "AllowServiceGrants")
    assert stmts, "AllowServiceGrants statement is missing"

    condition = stmts[0]["Condition"]["Bool"]
    assert condition.get("kms:GrantIsForAWSResource") in ("true", True), (
        "kms:CreateGrant is not gated on kms:GrantIsForAWSResource"
    )


def test_cloudwatch_logs_grant_is_scoped_by_encryption_context(
    key_policy: dict[str, Any],
) -> None:
    """The Logs service principal bypasses ViaService, so it needs its own leash."""
    stmts = _statements(key_policy, "AllowCloudWatchLogs")
    assert stmts, "AllowCloudWatchLogs statement is missing"

    arn_like = stmts[0]["Condition"]["ArnLike"]
    context = arn_like.get("kms:EncryptionContext:aws:logs:arn")
    assert context, "CloudWatch Logs grant is not scoped by encryption context"

    values = [context] if isinstance(context, str) else context
    assert all(":log-group:" in v for v in values), (
        f"encryption context does not confine the grant to log groups: {values}"
    )


def test_log_delivery_can_use_the_key(key_policy: dict[str, Any]) -> None:
    """Prerequisite for flow logs reaching the SSE-KMS log archive.

    The log-delivery service encrypts with its own principal, so kms:ViaService
    does not cover it. Omitting this grant produces NO error — AWS reports the
    flow log as active and silently writes nothing.
    """
    stmts = _statements(key_policy, "AllowAwsLogDelivery")
    assert stmts, "AllowAwsLogDelivery missing — flow logs will silently not deliver"

    principal = stmts[0]["Principal"]["Service"]
    services = [principal] if isinstance(principal, str) else principal
    assert "delivery.logs.amazonaws.com" in services

    actions = stmts[0]["Action"]
    actions = [actions] if isinstance(actions, str) else actions
    assert any(a.startswith("kms:GenerateDataKey") for a in actions), (
        "log delivery needs GenerateDataKey to encrypt objects"
    )

    # Confused-deputy gate: another account's flow logs must not use our key.
    assert stmts[0]["Condition"]["StringEquals"].get("aws:SourceAccount"), (
        "AllowAwsLogDelivery lacks an aws:SourceAccount condition"
    )


def test_no_statement_grants_key_use_to_a_wildcard_principal(
    key_policy: dict[str, Any],
) -> None:
    """Negative control: an anonymous principal must never hold key access.

    The root delegation is deliberate and account-scoped; Principal "*" without
    a confining condition would be a genuine hole.
    """
    for stmt in key_policy["Statement"]:
        if stmt.get("Effect") != "Allow":
            continue
        principal = stmt.get("Principal", {})
        aws_principals = principal.get("AWS", []) if isinstance(principal, dict) else principal
        values = [aws_principals] if isinstance(aws_principals, str) else aws_principals

        if "*" in values:
            assert stmt.get("Condition"), (
                f"statement {stmt.get('Sid')!r} grants {stmt.get('Action')} to a "
                "wildcard principal with no confining condition"
            )
