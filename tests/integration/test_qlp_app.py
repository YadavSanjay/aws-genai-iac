"""Post-apply verification for dev/40-quantlibpricer/app against the LIVE AWS API.

The Faultline application host: a private t4g.large running the backend +
bff + ui compose stack. Asserts the instance posture (private, CMK-encrypted root
AND data volume, IMDS hop 1, the shared app SG) and — the part that matters most —
that its instance role is tightly scoped: it pulls ONLY the three qlp images and
reads ONLY its own app secret.

Unlike XbrlRag this tier is STATEFUL: the pricing data tree lives on the data volume,
so its encryption is asserted rather than its absence.

On-host checks (containers Up, /health, /api/health, a real pricing run) are a
separate SSM step — readonlyagent/genai-tf cannot Session-Manager onto the host.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import os
from typing import Any

import boto3
import pytest

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")
ENV_NAME = os.environ.get("IAC_ENV_NAME", "dev")

INSTANCE_NAME = f"{NAME_PREFIX}-qlp"
ROLE_NAME = f"{NAME_PREFIX}-qlp"
DATA_BUCKET = f"genai-{ENV_NAME}-qlp-data-{REGION}"

EXPECTED_REPOS = [f"{NAME_PREFIX}/qlp-backend", f"{NAME_PREFIX}/qlp-bff", f"{NAME_PREFIX}/qlp-ui"]


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
            {"Name": "instance-state-name", "Values": ["pending", "running", "stopped"]},
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
def role_policy(session: Any) -> dict[str, Any]:
    iam = session.client("iam")
    doc = iam.get_role_policy(RoleName=ROLE_NAME, PolicyName="app-runtime")["PolicyDocument"]
    return dict(doc)


def _statements(doc: dict[str, Any], sid: str) -> list[dict[str, Any]]:
    return [s for s in doc["Statement"] if s.get("Sid") == sid]


def _as_list(value: Any) -> list[str]:
    return [value] if isinstance(value, str) else list(value)


# --- Instance posture --------------------------------------------------------


def test_instance_has_no_public_address(instance: dict[str, Any]) -> None:
    """The core property: no path from the internet, in either direction."""
    assert "PublicIpAddress" not in instance, (
        f"host has a public IP ({instance.get('PublicIpAddress')}); it must be private-only"
    )
    assert instance.get("PrivateIpAddress"), "host has no private address at all"


def test_instance_runs_on_graviton(instance: dict[str, Any]) -> None:
    """arm64 is the estate default and ~20% cheaper for equal performance.

    It is also the architecture the golden-PV suite must have been re-verified
    against (CL-Q5) — an x86 host here would mean the images were built for a
    different architecture than the one that was validated.
    """
    assert instance["Architecture"] == "arm64", (
        f"host is {instance['Architecture']}, not arm64 — see the plan's architecture decision"
    )
    assert instance["InstanceType"].startswith("t4g."), (
        f"instance type {instance['InstanceType']} is not a Graviton family"
    )


def test_imds_requires_v2_and_stays_on_the_host(instance: dict[str, Any]) -> None:
    """Hop limit 1 keeps the instance role out of the containers.

    The compose stack makes no AWS calls in local mode — the S3 seed/sync runs
    host-side — so a container reaching IMDS through the docker bridge would be
    an unnecessary path to the role's credentials. Raising this to 2 is required
    only if the backend is switched to PRICER_DEPLOY_MODE=aws.
    """
    options = instance["MetadataOptions"]
    assert options["HttpTokens"] == "required", "IMDSv1 is permitted — SSRF can mint credentials"
    assert options["HttpPutResponseHopLimit"] == 1, (
        f"IMDS hop limit is {options['HttpPutResponseHopLimit']}; containers can reach the role"
    )


def test_both_volumes_are_cmk_encrypted(session: Any, instance: dict[str, Any]) -> None:
    """Root AND data. The data volume is the one holding the pricing tree."""
    ec2 = session.client("ec2")
    kms = session.client("kms")
    expected = kms.describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"]["Arn"]

    volume_ids = [m["Ebs"]["VolumeId"] for m in instance["BlockDeviceMappings"] if m.get("Ebs")]
    assert len(volume_ids) == 2, f"expected a root and a data volume, found {volume_ids}"

    for vol in ec2.describe_volumes(VolumeIds=volume_ids)["Volumes"]:
        assert vol["Encrypted"] is True, f"volume {vol['VolumeId']} is unencrypted"
        assert vol["KmsKeyId"] == expected, (
            f"volume {vol['VolumeId']} uses {vol['KmsKeyId']}, not the project CMK"
        )


def test_data_volume_survives_instance_replacement(session: Any, instance: dict[str, Any]) -> None:
    """The data volume must NOT be delete-on-termination.

    It holds the live pricing tree. If it died with the instance, a routine
    user-data change — which replaces the host — would take the data with it.
    """
    ec2 = session.client("ec2")
    root = instance["RootDeviceName"]
    data = [m for m in instance["BlockDeviceMappings"] if m["DeviceName"] != root]
    assert data, "no non-root volume attached — the data volume is missing"

    for mapping in data:
        vol_id = mapping["Ebs"]["VolumeId"]
        attachment = ec2.describe_volumes(VolumeIds=[vol_id])["Volumes"][0]["Attachments"][0]
        assert attachment["DeleteOnTermination"] is False, (
            f"data volume {vol_id} is delete-on-termination; replacing the host would "
            "destroy the pricing tree"
        )


# --- Least privilege ---------------------------------------------------------


def test_role_pulls_only_the_three_qlp_repositories(
    role_policy: dict[str, Any], account_id: str
) -> None:
    stmts = _statements(role_policy, "EcrPullOwnImagesOnly")
    assert stmts, "no scoped ECR pull statement"

    resources = set(_as_list(stmts[0]["Resource"]))
    expected = {f"arn:aws:ecr:{REGION}:{account_id}:repository/{r}" for r in EXPECTED_REPOS}
    assert resources == expected, (
        f"ECR pull is scoped to {sorted(resources)}, expected exactly {sorted(expected)}"
    )


def test_role_reads_only_its_own_secret(role_policy: dict[str, Any]) -> None:
    """Negative control: no other application's credentials are reachable.

    This tier has no database, so unlike XbrlRag there is no second (RDS-managed)
    secret to admit — exactly one ARN is correct here.
    """
    stmts = _statements(role_policy, "ReadOwnSecretsOnly")
    assert stmts, "no scoped secret-read statement"

    resources = _as_list(stmts[0]["Resource"])
    assert len(resources) == 1, f"role reads {len(resources)} secrets, expected exactly one"
    assert f"{NAME_PREFIX}/qlp/app" in resources[0], (
        f"role reads {resources[0]}, which is not the Faultline app secret"
    )


def test_role_has_no_wildcard_resource_grants(role_policy: dict[str, Any]) -> None:
    """A bare "*" resource on anything but the login token defeats the scoping.

    ecr:GetAuthorizationToken is the documented exception: it takes no resource,
    and the pull itself is scoped by the statement above.
    """
    for stmt in role_policy["Statement"]:
        if stmt.get("Sid") == "EcrLogin":
            continue
        assert "*" not in _as_list(stmt["Resource"]), (
            f"statement {stmt.get('Sid')!r} grants {stmt['Action']} on *"
        )


def test_role_writes_only_its_own_bucket(role_policy: dict[str, Any]) -> None:
    stmts = _statements(role_policy, "ReadWriteOwnObjectsOnly")
    assert stmts, "no scoped S3 object statement"

    resources = _as_list(stmts[0]["Resource"])
    assert resources == [f"arn:aws:s3:::{DATA_BUCKET}/*"], (
        f"S3 write access is {resources}, expected only the qlp-data bucket"
    )


def test_instance_is_managed_by_session_manager(session: Any, instance: dict[str, Any]) -> None:
    """No SSH key, so SSM is the ONLY administrative path — it must work."""
    if instance["State"]["Name"] != "running":
        pytest.skip(
            f"instance is {instance['State']['Name']}; SSM only reports running hosts. "
            "UNVERIFIED, not passing."
        )
    ssm = session.client("ssm")
    managed = ssm.describe_instance_information(
        Filters=[{"Key": "InstanceIds", "Values": [instance["InstanceId"]]}]
    )["InstanceInformationList"]
    assert managed, (
        f"{instance['InstanceId']} is not SSM-managed — there is no other way in, "
        "and no on-host verification is possible"
    )


def test_instance_carries_mandatory_tags(instance: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in instance["Tags"]}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"
    assert tags["ManagedBy"] == "terragrunt"
