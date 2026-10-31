"""Post-apply verification for dev/42-arag/ingest against the LIVE AWS API.

The XbrlRag ingest runner: a private, usually-stopped t4g.medium that runs the ingest
pipeline on demand. Asserts the instance posture (private, CMK root, IMDS hop 2, the
shared app SG) and its role scoping — the notable difference from the app tier is
that it may WRITE the filings bucket (it downloads and stores filings), so this
verifies that write is allowed here and denied for another repo/bucket.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import fnmatch
import json
import os
from typing import Any

import boto3
import pytest
from botocore.exceptions import ClientError

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")
ENV_NAME = os.environ.get("IAC_ENV_NAME", "dev")

INSTANCE_NAME = f"{NAME_PREFIX}-arag-ingest"
ROLE_NAME = f"{NAME_PREFIX}-arag-ingest"
FILINGS_BUCKET = f"genai-{ENV_NAME}-arag-filings-{REGION}"


@pytest.fixture(scope="module")
def session() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess


@pytest.fixture(scope="module")
def instance(session: Any) -> dict[str, Any]:
    ec2 = session.client("ec2")
    reservations = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [INSTANCE_NAME]},
            # On-demand: it may be stopped. Exclude only terminated.
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running", "stopping", "stopped"],
            },
        ]
    )["Reservations"]
    instances = [i for r in reservations for i in r["Instances"]]
    if not instances:
        pytest.fail(f"no instance tagged Name={INSTANCE_NAME} — is the component applied?")
    return dict(instances[0])


@pytest.fixture(scope="module")
def account_id(session: Any) -> str:
    return str(session.client("sts").get_caller_identity()["Account"])


@pytest.fixture(scope="module")
def role_arn(account_id: str) -> str:
    return f"arn:aws:iam::{account_id}:role/{ROLE_NAME}"


def _simulate(session: Any, role_arn: str, action: str, resource: str) -> str:
    iam = session.client("iam")
    try:
        results = iam.simulate_principal_policy(
            PolicySourceArn=role_arn, ActionNames=[action], ResourceArns=[resource]
        )["EvaluationResults"]
        return str(results[0]["EvalDecision"])
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise


# --- Instance posture --------------------------------------------------------


def test_instance_is_graviton_medium(instance: dict[str, Any]) -> None:
    assert instance["InstanceType"] == "t4g.medium", f"unexpected type {instance['InstanceType']}"
    assert instance["Architecture"] == "arm64"


def test_private_no_public_ip(instance: dict[str, Any]) -> None:
    assert not instance.get("PublicIpAddress"), "ingest runner has a public IP"


def test_imds_hop_limit_is_two(instance: dict[str, Any]) -> None:
    """The ingest container runs boto3, reaching the role through the docker bridge."""
    opts = instance.get("MetadataOptions", {})
    assert opts.get("HttpTokens") == "required", "IMDSv2 not enforced"
    assert opts.get("HttpPutResponseHopLimit") == 2, (
        f"IMDS hop limit is {opts.get('HttpPutResponseHopLimit')}, expected 2"
    )


def test_root_volume_encrypted_with_cmk(instance: dict[str, Any], session: Any) -> None:
    ec2 = session.client("ec2")
    vol_ids = [m["Ebs"]["VolumeId"] for m in instance.get("BlockDeviceMappings", []) if "Ebs" in m]
    cmk = session.client("kms").describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"][
        "Arn"
    ]
    for vol in ec2.describe_volumes(VolumeIds=vol_ids)["Volumes"]:
        assert vol["Encrypted"] is True, f"{vol['VolumeId']} not encrypted"
        assert vol.get("KmsKeyId") == cmk, f"{vol['VolumeId']} not under the project CMK"


def test_uses_the_shared_app_security_group(instance: dict[str, Any], session: Any) -> None:
    sg_ids = [g["GroupId"] for g in instance.get("SecurityGroups", [])]
    groups = session.client("ec2").describe_security_groups(GroupIds=sg_ids)["SecurityGroups"]
    names = {g["GroupName"] for g in groups}
    assert f"{NAME_PREFIX}-app" in names, f"not attached to the shared app SG (has {names})"


def test_instance_carries_mandatory_tags(instance: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"


# --- Role scoping ------------------------------------------------------------


def test_role_pulls_only_the_ingest_image(session: Any, role_arn: str, account_id: str) -> None:
    ecr = f"arn:aws:ecr:{REGION}:{account_id}:repository"
    allowed = _simulate(session, role_arn, "ecr:BatchGetImage", f"{ecr}/{NAME_PREFIX}/arag-ingest")
    assert allowed == "allowed", f"role cannot pull arag-ingest ({allowed})"
    # It must NOT be able to pull the serving image (different repo).
    denied = _simulate(session, role_arn, "ecr:BatchGetImage", f"{ecr}/{NAME_PREFIX}/arag")
    assert denied != "allowed", "ingest role can pull the serving image — ECR scope leaked"


def test_role_can_read_write_the_filings_bucket(session: Any, role_arn: str) -> None:
    """Unlike the app tier (read-only bundle), the ingest WRITES filings."""
    obj = f"arn:aws:s3:::{FILINGS_BUCKET}/AAPL/2024/10-K/manifest.yaml"
    read = _simulate(session, role_arn, "s3:GetObject", obj)
    assert read == "allowed", f"role cannot read filings ({read})"
    assert _simulate(session, role_arn, "s3:PutObject", obj) == "allowed", (
        "role cannot WRITE filings — the ingest needs to store downloaded filings"
    )


def test_role_cannot_touch_the_corpus_bucket(session: Any, role_arn: str) -> None:
    """Negative control: S3 access is scoped to the filings bucket, not every bucket."""
    other = f"arn:aws:s3:::genai-{ENV_NAME}-macrorag-corpus-{REGION}/x"
    assert _simulate(session, role_arn, "s3:PutObject", other) != "allowed", (
        "ingest role can write the MacroRAG corpus bucket — S3 scope leaked"
    )


def test_role_reads_app_and_db_secrets(session: Any, role_arn: str) -> None:
    sm = session.client("secretsmanager")
    get = "secretsmanager:GetSecretValue"
    app_arn = sm.describe_secret(SecretId=f"{NAME_PREFIX}/arag/app")["ARN"]
    assert _simulate(session, role_arn, get, app_arn) == "allowed", "role cannot read app secret"
    db_secret = session.client("rds").describe_db_instances(
        DBInstanceIdentifier=f"{NAME_PREFIX}-arag"
    )["DBInstances"][0]["MasterUserSecret"]["SecretArn"]
    assert _simulate(session, role_arn, get, db_secret) == "allowed", (
        "role cannot read the RDS-managed DB secret"
    )


def _as_list(value: Any) -> list[str]:
    """IAM policy fields are a string or a list of strings, interchangeably."""
    if value is None:
        return []
    return [str(value)] if isinstance(value, str) else [str(v) for v in value]


def test_app_secret_resource_policy_admits_the_ingest_role(session: Any, role_arn: str) -> None:
    """The identity check above is NOT sufficient, and once gave a false green.

    `simulate_principal_policy` evaluates IDENTITY policies. The app secret also
    carries a deny-with-exception RESOURCE policy naming its permitted readers, and
    the ingest runner's role was missing from that set — so the role held the IAM
    allow, the test above passed, and the live call still failed with "explicit deny
    in a resource-based policy", killing cloud-init before the image was pulled.

    This asserts on the live policy directly rather than through the simulator.
    That is a deliberate limitation, not an oversight: SimulatePrincipalPolicy
    requires CallerArn whenever a ResourcePolicy accompanies a non-user
    PolicySourceArn, and CallerArn only accepts an IAM *user* — so the role +
    resource-policy combination cannot be simulated at all.

    Scope of the check: the reader set of every Deny on GetSecretValue must match
    this role. It does not re-implement IAM evaluation, and it would not catch a
    deny expressed some other way (a different condition operator, a Principal
    carve-out). It does catch the failure that actually happened.
    """
    sm = session.client("secretsmanager")
    secret = sm.describe_secret(SecretId=f"{NAME_PREFIX}/arag/app")
    raw = sm.get_resource_policy(SecretId=secret["ARN"]).get("ResourcePolicy")
    if not raw:
        pytest.fail(
            f"{NAME_PREFIX}/arag/app has no resource policy — the second gate in front "
            "of the credential values is missing entirely"
        )

    denies = [
        st
        for st in json.loads(raw).get("Statement", [])
        if st.get("Effect") == "Deny"
        and "secretsmanager:GetSecretValue" in _as_list(st.get("Action"))
    ]
    assert denies, (
        "the app secret's resource policy no longer denies GetSecretValue to anyone — "
        "the reader gate in front of the credential values has been removed"
    )

    for statement in denies:
        # Deny UNLESS the caller matches one of these — so the role is admitted
        # exactly when it matches at least one pattern. fnmatch gives ArnLike's
        # `*`/`?` semantics.
        patterns = _as_list(
            statement.get("Condition", {}).get("ArnNotLike", {}).get("aws:PrincipalArn")
        )
        assert patterns, (
            f"Deny statement {statement.get('Sid')!r} has no ArnNotLike reader set — "
            "it denies GetSecretValue unconditionally, to every principal"
        )
        assert any(fnmatch.fnmatchcase(role_arn, pattern) for pattern in patterns), (
            f"{role_arn} is denied by {statement.get('Sid')!r}: it matches none of {patterns}. "
            "Add it to reader_role_arn_patterns in dev/10-security/secrets — the role's own "
            "IAM allow is not enough, the deny-with-exception overrides it. Note ArnNotLike "
            "does not wildcard: '<prefix>-arag' does NOT cover '<prefix>-arag-ingest'."
        )
