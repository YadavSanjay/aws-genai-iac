"""Post-apply verification for dev/20-data/arag-filings against the LIVE AWS API.

Exercises the data/s3 module's security posture on the XbrlRag SEC-filings bucket:
encryption with the project CMK, public-access blocking, ACL suppression, TLS
enforcement, KMS-only uploads, and the lifecycle rules that bound cost. Like the
MacroRAG corpus and unlike the logs bucket this store is DURABLE — a test asserts
live objects never expire (the filings are the source of record and cannot be
re-derived, only re-downloaded from EDGAR).

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
BUCKET = os.environ.get("IAC_ARAG_FILINGS_BUCKET", f"genai-{ENV_NAME}-arag-filings-{REGION}")

EXPECTED_NONCURRENT_DAYS = 30
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


def test_bucket_uses_the_project_cmk(s3_client: Any) -> None:
    """A CMK, specifically the project key — not any random KMS key."""
    kms = boto3.Session(region_name=REGION).client("kms")
    expected = kms.describe_key(KeyId=f"alias/genai-{ENV_NAME}-primary")["KeyMetadata"]["Arn"]

    rules = s3_client.get_bucket_encryption(Bucket=BUCKET)["ServerSideEncryptionConfiguration"][
        "Rules"
    ]
    key_id = rules[0]["ApplyServerSideEncryptionByDefault"]["KMSMasterKeyID"]
    assert key_id == expected, (
        f"filings bucket encrypts with {key_id}, not the project CMK {expected}"
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
    ), "no aws:SecureTransport deny — filings may travel over plain HTTP"


def test_bucket_policy_rejects_non_kms_encryption(s3_client: Any) -> None:
    """Someone forcing AES256 would sidestep the CMK entirely."""
    policy = json.loads(s3_client.get_bucket_policy(Bucket=BUCKET)["Policy"])
    stmts = [s for s in policy["Statement"] if s.get("Sid") == "DenyNonKmsEncryption"]
    assert stmts, "DenyNonKmsEncryption statement is missing"

    condition = stmts[0]["Condition"]
    assert condition["StringNotEquals"]["s3:x-amz-server-side-encryption"] == "aws:kms"

    # The Null check keeps headerless (default-encrypted) uploads working.
    assert condition["Null"]["s3:x-amz-server-side-encryption"] in ("false", False), (
        "deny is missing its Null guard and will reject headerless uploads"
    )


def test_no_aws_log_delivery_statements(s3_client: Any) -> None:
    """This is a data store, not a log-delivery target — those grants must be absent."""
    policy = json.loads(s3_client.get_bucket_policy(Bucket=BUCKET)["Policy"])
    sids = {s.get("Sid") for s in policy["Statement"]}
    assert not sids & {"AWSLogDeliveryAclCheck", "AWSLogDeliveryWrite"}, (
        "filings bucket carries AWS log-delivery grants it should not have"
    )


# --- Durability + cost controls ----------------------------------------------


def test_versioning_is_enabled(s3_client: Any) -> None:
    status = s3_client.get_bucket_versioning(Bucket=BUCKET).get("Status")
    assert status == "Enabled", f"versioning is {status!r}"


def test_live_objects_never_expire(s3_client: Any) -> None:
    """Filings are the durable source of record — a live-object expiry would delete them.

    Distinct from the logs bucket, which DOES expire. Facts (RDS) and vectors
    (Qdrant) are derived and rebuildable; the filings themselves are only
    re-obtainable from EDGAR, so an Expiration rule here would erase the corpus.
    """
    config = s3_client.get_bucket_lifecycle_configuration(Bucket=BUCKET)
    for rule in config["Rules"]:
        assert "Expiration" not in rule, (
            f"lifecycle rule {rule.get('ID')!r} expires live objects — filings must be durable"
        )


def test_noncurrent_versions_are_bounded(s3_client: Any) -> None:
    """Versioning guards overwrites; noncurrent expiry stops old copies accruing cost."""
    config = s3_client.get_bucket_lifecycle_configuration(Bucket=BUCKET)
    rules = [r for r in config["Rules"] if r["Status"] == "Enabled"]
    assert rules, "no enabled lifecycle rules — superseded versions grow without bound"
    assert any(
        r.get("NoncurrentVersionExpiration", {}).get("NoncurrentDays") == EXPECTED_NONCURRENT_DAYS
        for r in rules
    ), f"no noncurrent-version expiry at {EXPECTED_NONCURRENT_DAYS} days"


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
