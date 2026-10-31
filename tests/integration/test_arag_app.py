"""Post-apply verification for dev/42-arag/app against the LIVE AWS API.

The XbrlRag application host: a private t4g.small running the ui + api + mcp compose
stack. Asserts the instance posture (private, CMK-encrypted root, IMDS hop 1, no
data volume, the shared app SG) and — the part that matters most — that its
instance role is tightly scoped: it pulls ONLY the arag images, reads ONLY its own
app secret plus the RDS-managed secret, and has READ-ONLY access to the deploy
bundle bucket (no writes to the filings store).

On-host checks (containers Up, /healthz, a real query) are a separate SSM step —
readonlyagent/genai-tf cannot Session-Manager onto the host.

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
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")

INSTANCE_NAME = f"{NAME_PREFIX}-arag"
ROLE_NAME = f"{NAME_PREFIX}-arag"
FILINGS_BUCKET = f"genai-{os.environ.get('IAC_ENV_NAME', 'dev')}-arag-filings-{REGION}"


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
    """The provisioned host, running or not.

    Deliberately includes `stopped`. Everything asserted here — instance type,
    architecture, IMDS options, volume encryption, security group, tags — is a
    property of the provisioned instance, not of its power state, and stopped is
    the NORMAL state for this estate: nightly outside the window, and continuously
    while `parked = true` in dev/env.hcl. Filtering to running-only turned every
    one of these security assertions into an error the moment the schedule fired,
    which is the opposite of what a security check should do.
    """
    ec2 = session.client("ec2")
    reservations = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [INSTANCE_NAME]},
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


def _simulate(session: Any, role_arn: str, action: str, resource: str, ctx=None):
    iam = session.client("iam")
    kwargs: dict[str, Any] = {
        "PolicySourceArn": role_arn,
        "ActionNames": [action],
        "ResourceArns": [resource],
    }
    if ctx:
        kwargs["ContextEntries"] = ctx
    try:
        return iam.simulate_principal_policy(**kwargs)["EvaluationResults"][0]["EvalDecision"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise


# --- Instance posture --------------------------------------------------------


def test_instance_is_graviton_and_right_sized(instance: dict[str, Any]) -> None:
    """Shape, not power state.

    Whether the host is up is decided by its schedule and the park switch, so it
    is asserted in test_arag_schedule.py against what dev/env.hcl declares —
    not here, where it would just make a correctly-parked estate look broken.
    """
    assert instance["InstanceType"] == "t4g.small", f"unexpected type {instance['InstanceType']}"
    assert instance["Architecture"] == "arm64", (
        f"architecture is {instance['Architecture']} — the ~20% Graviton saving requires arm64"
    )


def test_private_no_public_ip(instance: dict[str, Any]) -> None:
    """A stateless app tier reached only via SSM — never a public address."""
    assert not instance.get("PublicIpAddress"), "instance has a public IP"


def test_imds_requires_token_and_hop_limit_is_one(instance: dict[str, Any]) -> None:
    """IMDSv2 enforced; hop 1 because the slim container is boto3-free and makes
    no AWS calls, so it never needs instance-role creds through the docker bridge."""
    opts = instance.get("MetadataOptions", {})
    assert opts.get("HttpTokens") == "required", "IMDSv2 not enforced"
    assert opts.get("HttpPutResponseHopLimit") == 1, (
        f"IMDS hop limit is {opts.get('HttpPutResponseHopLimit')}, expected 1"
    )


def test_no_data_volume_only_root(instance: dict[str, Any], session: Any) -> None:
    """Stateless: state lives in RDS + Qdrant, so exactly one (root) volume."""
    mappings = instance.get("BlockDeviceMappings", [])
    assert len(mappings) == 1, f"expected only a root volume, found {len(mappings)} devices"


def test_root_volume_encrypted_with_cmk(instance: dict[str, Any], session: Any) -> None:
    ec2 = session.client("ec2")
    vol_ids = [m["Ebs"]["VolumeId"] for m in instance.get("BlockDeviceMappings", []) if "Ebs" in m]
    kms = session.client("kms")
    cmk = kms.describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"]["Arn"]
    for vol in ec2.describe_volumes(VolumeIds=vol_ids)["Volumes"]:
        assert vol["Encrypted"] is True, f"{vol['VolumeId']} not encrypted"
        assert vol.get("KmsKeyId") == cmk, f"{vol['VolumeId']} not under the project CMK"


def test_uses_the_shared_app_security_group(instance: dict[str, Any], session: Any) -> None:
    sg_ids = [g["GroupId"] for g in instance.get("SecurityGroups", [])]
    ec2 = session.client("ec2")
    groups = ec2.describe_security_groups(GroupIds=sg_ids)["SecurityGroups"]
    names = {g["GroupName"] for g in groups}
    assert f"{NAME_PREFIX}-app" in names, f"not attached to the shared app SG (has {names})"


def test_instance_carries_mandatory_tags(instance: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"


# --- Instance role scoping (the security core) -------------------------------


def test_role_pulls_only_arag_images(session: Any, role_arn: str, account_id: str) -> None:
    """ECR pull allowed for arag / arag-ui, denied for another subsystem's repo."""
    ecr = f"arn:aws:ecr:{REGION}:{account_id}:repository"
    for repo in ("arag", "arag-ui"):
        decision = _simulate(session, role_arn, "ecr:BatchGetImage", f"{ecr}/{NAME_PREFIX}/{repo}")
        assert decision == "allowed", f"role cannot pull {repo} ({decision})"
    denied = _simulate(session, role_arn, "ecr:BatchGetImage", f"{ecr}/{NAME_PREFIX}/macrorag")
    assert denied != "allowed", "role can pull macrorag's image — ECR scope leaked"


def test_role_reads_app_and_db_secrets_only(session: Any, role_arn: str) -> None:
    """Resolve the REAL secret ARNs (they carry a random suffix simulate matches
    literally) and assert the role reads its app secret + the RDS-managed DB
    secret, but not another subsystem's."""
    sm = session.client("secretsmanager")
    get = "secretsmanager:GetSecretValue"

    app_arn = sm.describe_secret(SecretId=f"{NAME_PREFIX}/arag/app")["ARN"]
    assert _simulate(session, role_arn, get, app_arn) == "allowed", (
        "role cannot read its app secret"
    )

    db_secret = session.client("rds").describe_db_instances(
        DBInstanceIdentifier=f"{NAME_PREFIX}-arag"
    )["DBInstances"][0]["MasterUserSecret"]["SecretArn"]
    assert _simulate(session, role_arn, get, db_secret) == "allowed", (
        "role cannot read the RDS-managed DB secret"
    )

    other = sm.describe_secret(SecretId=f"{NAME_PREFIX}/macrorag/app")["ARN"]
    assert _simulate(session, role_arn, get, other) != "allowed", (
        "role can read macrorag's secret — secret scope leaked"
    )


def test_role_bundle_access_is_read_only(session: Any, role_arn: str) -> None:
    """The bootstrap READS the deploy bundle; the app tier must not WRITE the
    filings bucket (that is the ingest runner's job)."""
    obj = f"arn:aws:s3:::{FILINGS_BUCKET}/deploy/deploy.env"
    read = _simulate(session, role_arn, "s3:GetObject", obj)
    assert read == "allowed", f"role cannot read the deploy bundle ({read})"
    write = _simulate(session, role_arn, "s3:PutObject", f"arn:aws:s3:::{FILINGS_BUCKET}/x")
    assert write != "allowed", "role can WRITE the filings bucket — should be read-only"
