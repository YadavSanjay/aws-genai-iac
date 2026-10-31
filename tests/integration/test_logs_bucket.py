"""Post-apply verification for dev/20-data/logs-bucket against the LIVE AWS API.

Exercises the data/s3 module's security posture on a real bucket: encryption,
public-access blocking, ACL suppression, TLS enforcement, and — the ones a
config read alone cannot establish — the lifecycle rules that keep cost bounded.

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
ENV_NAME = os.environ.get("IAC_ENV_NAME", "dev")

# The "genai-" prefix is load-bearing, not cosmetic: the exec role's s3 grant is
# ARN-scoped to arn:aws:s3:::genai-*, so a bucket named outside it cannot be
# created. Region suffix is for S3's global-namespace uniqueness.
BUCKET = os.environ.get("IAC_LOGS_BUCKET", f"genai-{ENV_NAME}-logs-{REGION}")

EXPECTED_EXPIRATION_DAYS = 90
EXPECTED_NONCURRENT_DAYS = 7
EXPECTED_ABORT_MPU_DAYS = 7


@pytest.fixture(scope="module")
def s3_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    client = sess.client("s3")
    try:
        client.head_bucket(Bucket=BUCKET)
    except ClientError as exc:
        pytest.fail(f"bucket {BUCKET!r} not reachable — is the component applied? {exc}")
    return client


# --- Encryption --------------------------------------------------------------


def test_bucket_encrypts_with_kms_and_bucket_keys(s3_client: Any) -> None:
    config = s3_client.get_bucket_encryption(Bucket=BUCKET)
    rules = config["ServerSideEncryptionConfiguration"]["Rules"]
    assert rules, "no server-side encryption configured"

    default = rules[0]["ApplyServerSideEncryptionByDefault"]
    assert default["SSEAlgorithm"] == "aws:kms", (
        f"bucket uses {default['SSEAlgorithm']}, not the project CMK"
    )
    assert default.get("KMSMasterKeyID"), (
        "SSE-KMS without a key id falls back to the AWS-managed key"
    )

    # Not cosmetic: bucket keys cut KMS request charges by up to 99%.
    assert rules[0].get("BucketKeyEnabled") is True, (
        "S3 Bucket Keys disabled — KMS costs will be high"
    )


# --- Public exposure ---------------------------------------------------------


def test_all_four_public_access_blocks_are_on(s3_client: Any) -> None:
    config = s3_client.get_public_access_block(Bucket=BUCKET)["PublicAccessBlockConfiguration"]
    for setting in (
        "BlockPublicAcls",
        "BlockPublicPolicy",
        "IgnorePublicAcls",
        "RestrictPublicBuckets",
    ):
        assert config[setting] is True, f"{setting} is OFF"


def test_acls_are_disabled(s3_client: Any) -> None:
    """BucketOwnerEnforced closes the 'public via object ACL' path.

    A public access block alone does not; ACLs must be switched off entirely.
    """
    controls = s3_client.get_bucket_ownership_controls(Bucket=BUCKET)
    rules = controls["OwnershipControls"]["Rules"]
    assert any(r["ObjectOwnership"] == "BucketOwnerEnforced" for r in rules), (
        f"ACLs are still active: {rules}"
    )


def test_bucket_policy_denies_plaintext_transport(s3_client: Any) -> None:
    """Negative control: the thing that should be denied is actually denied."""
    policy = json.loads(s3_client.get_bucket_policy(Bucket=BUCKET)["Policy"])
    denies = [s for s in policy["Statement"] if s["Effect"] == "Deny"]

    assert any(
        s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") in ("false", False)
        for s in denies
    ), "no aws:SecureTransport deny — objects may travel over plain HTTP"


def test_bucket_policy_rejects_non_kms_encryption(s3_client: Any) -> None:
    """Someone forcing AES256 would sidestep the CMK entirely."""
    policy = json.loads(s3_client.get_bucket_policy(Bucket=BUCKET)["Policy"])
    stmts = [s for s in policy["Statement"] if s.get("Sid") == "DenyNonKmsEncryption"]
    assert stmts, "DenyNonKmsEncryption statement is missing"

    condition = stmts[0]["Condition"]
    assert condition["StringNotEquals"]["s3:x-amz-server-side-encryption"] == "aws:kms"

    # The Null check is what keeps headerless (default-encrypted) uploads and AWS
    # log delivery working. Losing it turns this into a silent delivery failure.
    assert condition["Null"]["s3:x-amz-server-side-encryption"] in ("false", False), (
        "deny is missing its Null guard and will reject headerless uploads, "
        "including AWS log delivery"
    )


def test_aws_log_delivery_is_permitted(s3_client: Any) -> None:
    """Both statements are required, and the write must be account-scoped.

    CreateFlowLogs validates the bucket policy up front, so a missing ACL-check
    statement fails the flow log outright rather than degrading quietly.
    """
    policy = json.loads(s3_client.get_bucket_policy(Bucket=BUCKET)["Policy"])
    by_sid = {s.get("Sid"): s for s in policy["Statement"]}

    for sid in ("AWSLogDeliveryAclCheck", "AWSLogDeliveryWrite"):
        assert sid in by_sid, f"{sid} missing — AWS log delivery will be refused"
        stmt = by_sid[sid]
        principal = stmt["Principal"]["Service"]
        services = [principal] if isinstance(principal, str) else principal
        assert "delivery.logs.amazonaws.com" in services
        assert stmt["Condition"]["StringEquals"].get("aws:SourceAccount"), (
            f"{sid} lacks an aws:SourceAccount condition"
        )

    write = by_sid["AWSLogDeliveryWrite"]
    resource = write["Resource"]
    resources = [resource] if isinstance(resource, str) else resource
    assert all("/AWSLogs/" in r for r in resources), (
        f"write grant is not scoped to the AWSLogs prefix: {resources}"
    )


def test_log_delivery_write_has_no_acl_condition(s3_client: Any) -> None:
    """The trap most published examples fall into.

    Nearly every AWS log-delivery bucket-policy example carries an
    s3:x-amz-acl = bucket-owner-full-control condition. With
    BucketOwnerEnforced, ACLs are disabled and the delivery service does not
    send that header — so the condition would deny every write.
    """
    policy = json.loads(s3_client.get_bucket_policy(Bucket=BUCKET)["Policy"])
    write = next(s for s in policy["Statement"] if s.get("Sid") == "AWSLogDeliveryWrite")

    acl_condition = write.get("Condition", {}).get("StringEquals", {}).get("s3:x-amz-acl")
    assert acl_condition is None, (
        "AWSLogDeliveryWrite carries an s3:x-amz-acl condition. ACLs are "
        "disabled on this bucket, so this denies every delivery write."
    )


# --- Cost controls -----------------------------------------------------------


def test_versioning_is_enabled(s3_client: Any) -> None:
    status = s3_client.get_bucket_versioning(Bucket=BUCKET).get("Status")
    assert status == "Enabled", f"versioning is {status!r}"


def test_lifecycle_bounds_storage_growth(s3_client: Any) -> None:
    """The provisioning principles require lifecycle on anything that accumulates."""
    config = s3_client.get_bucket_lifecycle_configuration(Bucket=BUCKET)
    rules = [r for r in config["Rules"] if r["Status"] == "Enabled"]
    assert rules, "no enabled lifecycle rules — this bucket grows without bound"

    rule = rules[0]
    assert rule["Expiration"]["Days"] == EXPECTED_EXPIRATION_DAYS
    assert rule["NoncurrentVersionExpiration"]["NoncurrentDays"] == EXPECTED_NONCURRENT_DAYS


def test_incomplete_multipart_uploads_are_aborted(s3_client: Any) -> None:
    """Orphaned parts are invisible in the console but billed as storage forever."""
    config = s3_client.get_bucket_lifecycle_configuration(Bucket=BUCKET)
    aborts = [
        r["AbortIncompleteMultipartUpload"]["DaysAfterInitiation"]
        for r in config["Rules"]
        if "AbortIncompleteMultipartUpload" in r
    ]
    assert aborts, "no AbortIncompleteMultipartUpload rule — a silent cost leak"
    assert EXPECTED_ABORT_MPU_DAYS in aborts


def test_bucket_carries_mandatory_tags(s3_client: Any) -> None:
    tags = {t["Key"]: t["Value"] for t in s3_client.get_bucket_tagging(Bucket=BUCKET)["TagSet"]}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"
    assert tags["ManagedBy"] == "terragrunt"
