"""Post-apply verification for dev/20-data/qlp-data against the LIVE AWS API.

Exercises the data/s3 module's security posture on the Faultline object
store: encryption with the project CMK, public-access blocking, ACL suppression,
TLS enforcement, KMS-only uploads, and the lifecycle rules that bound cost.

Like the XbrlRag filings bucket and unlike the logs bucket this store is DURABLE.
The reason differs and is worth stating: filings cannot be re-derived, only
re-downloaded; here the live objects are the reproducibility spine (run
manifests, snapshot-addressed inputs, golden baselines, sign-off records) plus
the deploy bundle the app host boots from. A live-object expiry would quietly
destroy an audit trail whose entire value is that it survives.

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
BUCKET = os.environ.get("IAC_QLP_DATA_BUCKET", f"genai-{ENV_NAME}-qlp-data-{REGION}")

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
    assert key_id == expected, f"qlp-data encrypts with {key_id}, not the project CMK {expected}"


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
    ), "no aws:SecureTransport deny — pricing data may travel over plain HTTP"


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


def test_an_aes256_upload_is_actually_rejected(s3_client: Any) -> None:
    """Behavioural negative control: exercise the deny, don't just read it.

    The assertions above prove the DenyNonKmsEncryption STATEMENT exists and is
    shaped correctly. That is not the same as it working — a policy can be
    present and still be ineffective (wrong resource ARN, a broader Allow, an
    ordering mistake). This performs the PUT the statement is meant to stop,
    as a principal that otherwise HAS s3:PutObject on genai-*, so the only
    thing that can refuse it is the bucket policy.
    """
    # Positive control FIRST: without it, an AccessDenied below would also be
    # produced by a principal that simply cannot write here at all, and the
    # negative test would pass while proving nothing.
    control_key = "test/positive-control-kms"
    control = s3_client.put_object(
        Bucket=BUCKET, Key=control_key, Body=b"cmk upload", ServerSideEncryption="aws:kms"
    )
    s3_client.delete_object(Bucket=BUCKET, Key=control_key, VersionId=control["VersionId"])

    key = "test/negative-control-aes256"
    try:
        s3_client.put_object(
            Bucket=BUCKET, Key=key, Body=b"should never land", ServerSideEncryption="AES256"
        )
    except ClientError as exc:
        assert exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"), (
            f"AES256 upload failed for the wrong reason: {exc.response['Error']}"
        )
        return

    # It landed. Clean up before failing, so a broken policy does not also
    # leave unencrypted-by-CMK residue behind.
    s3_client.delete_object(Bucket=BUCKET, Key=key)
    pytest.fail("an AES256 upload SUCCEEDED — the CMK requirement is bypassable")


def test_no_aws_log_delivery_statements(s3_client: Any) -> None:
    """This is a data store, not a log-delivery target — those grants must be absent."""
    policy = json.loads(s3_client.get_bucket_policy(Bucket=BUCKET)["Policy"])
    sids = {s.get("Sid") for s in policy["Statement"]}
    assert not sids & {"AWSLogDeliveryAclCheck", "AWSLogDeliveryWrite"}, (
        "qlp-data carries AWS log-delivery grants it should not have"
    )


# --- Durability + cost controls ----------------------------------------------


def test_versioning_is_enabled(s3_client: Any) -> None:
    """Versioning is part of the provenance spine here, not just an undo button."""
    status = s3_client.get_bucket_versioning(Bucket=BUCKET).get("Status")
    assert status == "Enabled", f"versioning is {status!r}"


def test_live_objects_never_expire(s3_client: Any) -> None:
    """The store is durable by design — a live-object expiry would gut it.

    Two independent things would break: the reproducibility spine (run
    manifests, snapshot-addressed inputs, golden baselines, sign-offs), whose
    value is precisely that a past run stays reconstructable; and the deploy/
    bundle, without which a rebooted app host cannot start its stack at all.
    """
    config = s3_client.get_bucket_lifecycle_configuration(Bucket=BUCKET)
    for rule in config["Rules"]:
        assert "Expiration" not in rule, (
            f"lifecycle rule {rule.get('ID')!r} expires live objects — this store must be durable"
        )


def test_no_storage_class_transitions(s3_client: Any) -> None:
    """IA/Glacier would cost MORE here, so their absence is a deliberate control.

    The parquet store is ~940 tiny objects re-globbed by DuckDB on every read.
    IA bills a 128 KB minimum per object and adds retrieval charges, so a
    transition rule would be a cost regression dressed as an optimization.
    """
    config = s3_client.get_bucket_lifecycle_configuration(Bucket=BUCKET)
    for rule in config["Rules"]:
        assert not rule.get("Transitions"), (
            f"lifecycle rule {rule.get('ID')!r} transitions storage class: {rule['Transitions']}"
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
