"""Post-apply verification for dev/10-security/secrets against the LIVE AWS API.

Note what these tests never do: read a secret value. Verification asserts the
container's configuration — encryption key, recovery window, tags, policy —
because the value is set out of band and reading it here would put it in test
output and CI logs.

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
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")

SECRET_NAME = f"{NAME_PREFIX}/macrorag/app"
QDRANT_SECRET_NAME = f"{NAME_PREFIX}/qdrant/app"
ARAG_SECRET_NAME = f"{NAME_PREFIX}/arag/app"
QLP_SECRET_NAME = f"{NAME_PREFIX}/qlp/app"
EXPECTED_RECOVERY_DAYS = 7
MAX_SECRETS = 5


@pytest.fixture(scope="module")
def secrets_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("secretsmanager")


@pytest.fixture(scope="module")
def secret(secrets_client: Any) -> dict[str, Any]:
    try:
        return dict(secrets_client.describe_secret(SecretId=SECRET_NAME))
    except ClientError as exc:
        pytest.fail(f"secret {SECRET_NAME!r} not readable — is the component applied? {exc}")


@pytest.fixture(scope="module")
def kms_key_arn() -> str:
    sess = boto3.Session(region_name=REGION)
    return str(
        sess.client("kms").describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"]["Arn"]
    )


# --- Container configuration -------------------------------------------------


def test_secret_encrypts_with_the_project_cmk(secret: dict[str, Any], kms_key_arn: str) -> None:
    """Not aws/secretsmanager.

    The AWS-managed key carries no scoped key policy and does not rotate on our
    schedule, so a secret under it sits outside every control the KMS module
    establishes.
    """
    assert secret.get("KmsKeyId") == kms_key_arn, (
        f"secret encrypts with {secret.get('KmsKeyId')!r}, not the project CMK"
    )


def test_secret_is_not_scheduled_for_deletion(secret: dict[str, Any]) -> None:
    """A pending deletion is easy to miss and permanent once the window elapses."""
    assert "DeletedDate" not in secret, (
        f"secret is scheduled for deletion on {secret.get('DeletedDate')}. "
        "Restore it before the recovery window elapses."
    )


def test_secret_carries_mandatory_tags(secret: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in secret.get("Tags", [])}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"
    assert tags["ManagedBy"] == "terragrunt"


def test_no_rotation_is_falsely_advertised(secret: dict[str, Any]) -> None:
    """Rotation configured without a working rotator is worse than none.

    It reports the secret as rotating while nothing happens, so a stale
    credential looks managed. No rotation is configured here deliberately —
    rotating a third-party API key means calling that vendor's API, which
    differs per vendor and does not exist for some.
    """
    assert secret.get("RotationEnabled", False) is False, (
        "rotation is enabled but no rotation Lambda is managed by this module — "
        "the secret would report itself as rotating while doing nothing"
    )


# --- Cost ceiling ------------------------------------------------------------


def test_secret_count_stays_within_the_agreed_ceiling(secrets_client: Any) -> None:
    """$0.40 per secret per month, so the count IS the cost.

    Guards against the failure mode this module's design targets: one secret per
    credential instead of one JSON object per application, growing quietly.
    """
    paginator = secrets_client.get_paginator("list_secrets")
    ours = [
        s
        for page in paginator.paginate()
        for s in page["SecretList"]
        if s["Name"].startswith(f"{NAME_PREFIX}/")
    ]

    assert len(ours) <= MAX_SECRETS, (
        f"{len(ours)} secrets under {NAME_PREFIX}/ exceeds the agreed ceiling of "
        f"{MAX_SECRETS} (${0.40 * len(ours):.2f}/month). Prefer one JSON secret "
        f"per application: {[s['Name'] for s in ours]}"
    )


# --- Access policy -----------------------------------------------------------


def test_resource_policy_if_present_is_a_deny(secrets_client: Any) -> None:
    """Direction matters: an allow can be widened elsewhere, a deny cannot.

    No policy is attached yet — the application role does not exist, and naming
    a non-existent principal would deny everything including verification. When
    it is attached in Phase 3 it must be a deny-with-exception.
    """
    try:
        raw = secrets_client.get_resource_policy(SecretId=SECRET_NAME).get("ResourcePolicy")
    except ClientError as exc:
        pytest.fail(f"could not read resource policy: {exc}")

    if not raw:
        pytest.skip(
            "No resource policy attached yet — access is governed by IAM alone. "
            "This becomes a real assertion when the MacroRAG instance role lands "
            "in Phase 3. UNVERIFIED, not passing."
        )

    policy = json.loads(raw)
    effects = {s["Effect"] for s in policy["Statement"]}
    assert "Allow" not in effects, (
        "resource policy grants access with an Allow. Use a deny-with-exception "
        "so an unrelated allow elsewhere cannot widen it."
    )


def test_macrorag_reader_deny_excepts_the_instance_role(secrets_client: Any) -> None:
    """The deny must except the RIGHT principal — the MacroRAG instance role.

    'No Allow' above proves the shape; this proves the exception names the role
    that actually needs to read, not some unrelated ARN.
    """
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account}:role/{NAME_PREFIX}-macrorag"

    raw = secrets_client.get_resource_policy(SecretId=SECRET_NAME).get("ResourcePolicy")
    assert raw, f"{SECRET_NAME} has no resource policy — the reader deny is not attached"

    policy = json.loads(raw)
    deny = next(s for s in policy["Statement"] if s["Effect"] == "Deny")
    excepted = deny["Condition"]["ArnNotLike"]["aws:PrincipalArn"]
    excepted = [excepted] if isinstance(excepted, str) else excepted
    assert role_arn in excepted, (
        f"MacroRAG instance role {role_arn} is not in the reader exception set {excepted}"
    )


def test_arag_reader_deny_excepts_the_app_role(secrets_client: Any) -> None:
    """The XbrlRag secret's deny must except the XbrlRag app-tier role, and only it.

    Same per-secret shape as MacroRAG: the reader deny names the deterministic
    genai-<env>-arag role. The role does not exist until 42-arag/app lands, but
    the deny only blocks GetSecretValue, so put-secret-value (out of band) and
    describe/get-resource-policy verification still work meanwhile.
    """
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account}:role/{NAME_PREFIX}-arag"

    raw = secrets_client.get_resource_policy(SecretId=ARAG_SECRET_NAME).get("ResourcePolicy")
    assert raw, f"{ARAG_SECRET_NAME} has no resource policy — the reader deny is not attached"

    policy = json.loads(raw)
    deny = next(s for s in policy["Statement"] if s["Effect"] == "Deny")
    excepted = deny["Condition"]["ArnNotLike"]["aws:PrincipalArn"]
    excepted = [excepted] if isinstance(excepted, str) else excepted
    assert role_arn in excepted, (
        f"XbrlRag app role {role_arn} is not in the reader exception set {excepted}"
    )


def test_qlp_reader_deny_excepts_exactly_the_app_role(secrets_client: Any) -> None:
    """Set EQUALITY, not membership — leakage is the failure this design prevents.

    The two assertions above check the right role is IN each exception set. That
    still passes if another application's role has leaked in, which is precisely
    what per-secret reader sets exist to stop, so this one pins the set to the
    single role that needs it.

    The role does not exist until Q5 lands, and Q5 MUST name the host
    app_name="qlp": ArnNotLike does not wildcard, so a differently-named role is
    refused its own credentials. That refusal surfaces inside cloud-init under
    `set -euo pipefail`, so the box boots, aborts before pulling an image, and
    leaves nothing on disk saying why — how XbrlRag's ingest runner failed.
    """
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account}:role/{NAME_PREFIX}-qlp"

    raw = secrets_client.get_resource_policy(SecretId=QLP_SECRET_NAME).get("ResourcePolicy")
    assert raw, f"{QLP_SECRET_NAME} has no resource policy — the reader deny is not attached"

    policy = json.loads(raw)
    deny = next(s for s in policy["Statement"] if s["Effect"] == "Deny")
    excepted = deny["Condition"]["ArnNotLike"]["aws:PrincipalArn"]
    excepted = [excepted] if isinstance(excepted, str) else excepted
    assert set(excepted) == {role_arn}, (
        f"Faultline reader set is {sorted(excepted)}, expected exactly [{role_arn}]. "
        "An extra ARN means another application's role can read these credentials."
    )


def test_qlp_reader_deny_actually_refuses_a_non_excepted_principal(secrets_client: Any) -> None:
    """Behavioural control: exercise the deny rather than just reading its shape.

    Every assertion above inspects the policy DOCUMENT, which proves it is
    attached and worded correctly — not that it takes effect. This calls
    GetSecretValue as the exec role, which is NOT in the reader set and which
    holds a broad secretsmanager IAM grant, so an allow is exactly what would
    happen if the resource policy were ineffective. Nothing is printed either
    way: a denial returns no value, and the container is empty until the
    hand-off below.
    """
    with pytest.raises(ClientError) as caught:
        secrets_client.get_secret_value(SecretId=QLP_SECRET_NAME)

    code = caught.value.response["Error"]["Code"]
    assert code in ("AccessDeniedException", "AccessDenied"), (
        f"expected the reader deny to refuse the exec role, got {code}. "
        "An IAM allow elsewhere is reaching these credentials."
    )


def test_qlp_secret_has_a_value_set(secrets_client: Any) -> None:
    """The recorded hand-off between 'applied' and 'usable'.

    Terraform owns the container, never the value. Q5's host renders this secret
    into /opt/qlp/.env at boot inside `set -euo pipefail`, so an unset value does
    not degrade gracefully — the bootstrap aborts before pulling an image and
    leaves nothing on disk explaining why. XbrlRag's A6 was blocked on exactly this.
    """
    try:
        secret = secrets_client.describe_secret(SecretId=QLP_SECRET_NAME)
    except ClientError as exc:
        pytest.fail(f"secret {QLP_SECRET_NAME!r} not readable — is the component applied? {exc}")

    versions = secret.get("VersionIdsToStages", {})
    current = [vid for vid, stages in versions.items() if "AWSCURRENT" in stages]
    if not current:
        pytest.skip(
            f"No value set for {QLP_SECRET_NAME}. Terraform manages the container only. "
            "Set it before Q5 applies, as KEY=value lines:\n"
            f"  aws secretsmanager put-secret-value --secret-id {QLP_SECRET_NAME} "
            "--secret-string 'PRICER_API_KEY=...\\nQLP_WRITE_TOKEN=...\\nOPENAI_API_KEY=...\\n"
            "FRED_API_KEY=...' --region " + REGION + "\n"
            "Note FRED_API_KEY is UN-prefixed: the downloaders read that name, and a wrong "
            "name leaves ingest keyless and silent. UNVERIFIED, not passing."
        )

    assert len(current) == 1, f"expected one AWSCURRENT version, found {len(current)}"


def test_qdrant_secret_has_no_reader_policy(secrets_client: Any) -> None:
    """Per-secret isolation: the MacroRAG reader set must NOT leak onto Qdrant's secret.

    The two secrets share one component; a component-wide reader list would attach
    MacroRAG's deny-with-exception here too, locking the Qdrant host out of its own
    API key at phase-2. Qdrant declares no reader patterns, so it must have no policy.
    """
    try:
        raw = secrets_client.get_resource_policy(SecretId=QDRANT_SECRET_NAME).get("ResourcePolicy")
    except ClientError as exc:
        pytest.fail(f"could not read qdrant resource policy: {exc}")

    assert not raw, (
        "Qdrant secret carries a resource policy — MacroRAG's per-secret reader set "
        "leaked onto it, which would deny the Qdrant host its own key at phase 2."
    )


# --- Value ------------------------------------------------------------------


def test_secret_has_a_value_set(secrets_client: Any, secret: dict[str, Any]) -> None:
    """Checks that a version EXISTS. Never reads it.

    Terraform deliberately does not manage secret values, so this is the gap
    between 'applied' and 'usable'. An application will fail to start until
    someone runs put-secret-value.
    """
    versions = secret.get("VersionIdsToStages", {})
    current = [vid for vid, stages in versions.items() if "AWSCURRENT" in stages]

    if not current:
        pytest.skip(
            f"No value set for {SECRET_NAME}. Terraform manages the container "
            "only — set it with:\n"
            f"  aws secretsmanager put-secret-value --secret-id {SECRET_NAME} "
            "--secret-string '<json>' --region " + REGION + "\n"
            "The application cannot start until this is done. UNVERIFIED, not passing."
        )

    assert len(current) == 1, f"expected one AWSCURRENT version, found {len(current)}"
