"""Post-apply verification for dev/41-macrorag/app against the LIVE AWS API.

SCOPE NOTE: this verifies the HOST, not the application. Nothing has been pushed
to ECR and the secret has no value, so MacroRAG is not running and these tests
do not pretend otherwise. What is asserted is that the host is placed correctly,
hardened, manageable, and holds exactly the permissions it will need.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import ipaddress
import os
from typing import Any

import boto3
import pytest
from botocore.exceptions import ClientError

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")

APP_NAME = f"{NAME_PREFIX}-macrorag"
EXPECTED_INSTANCE_TYPE = "t4g.small"
EXPECTED_DATA_VOLUME_GB = 20

# Real networks, compared by CIDR containment. A string-prefix check looks
# equivalent and is not: 10.10.131.44 is squarely inside 10.10.128.0/20 but does
# not start with "10.10.128.".
PRIVATE_NETWORKS = (
    ipaddress.ip_network("10.10.128.0/20"),
    ipaddress.ip_network("10.10.144.0/20"),
)


@pytest.fixture(scope="module")
def ec2_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("ec2")


@pytest.fixture(scope="module")
def instance(ec2_client: Any) -> dict[str, Any]:
    reservations = ec2_client.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [APP_NAME]},
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running", "stopped", "stopping"],
            },
        ]
    )["Reservations"]
    instances = [i for r in reservations for i in r["Instances"]]
    assert instances, f"no instance tagged Name={APP_NAME} — is the component applied?"
    assert len(instances) == 1, f"expected one instance, found {len(instances)}"
    return dict(instances[0])


# --- Placement ---------------------------------------------------------------


def test_instance_has_no_public_address(instance: dict[str, Any]) -> None:
    """The core property. Ingress is via the ALB, egress via NAT."""
    assert not instance.get("PublicIpAddress"), (
        f"application host has a public IP ({instance.get('PublicIpAddress')}). "
        "It must be reachable only through the load balancer."
    )
    address = ipaddress.ip_address(instance["PrivateIpAddress"])
    assert any(address in network for network in PRIVATE_NETWORKS), (
        f"instance is at {address}, outside the private subnet ranges "
        f"{[str(n) for n in PRIVATE_NETWORKS]} — check it did not land in a "
        "public subnet"
    )


def test_instance_is_graviton(instance: dict[str, Any]) -> None:
    """arm64 is a constraint, not just a discount.

    A container image built for x86 fails at start with "exec format error",
    which reads like a corrupt image rather than an architecture mismatch.
    """
    assert instance["InstanceType"] == EXPECTED_INSTANCE_TYPE
    assert instance["Architecture"] == "arm64"


def test_instance_carries_mandatory_tags(instance: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
    for required in ("Project", "Environment", "ManagedBy", "Tier", "App"):
        assert required in tags, f"missing tag {required!r}. Present: {sorted(tags)}"
    assert tags["App"] == "macrorag"


# --- Hardening ---------------------------------------------------------------


def test_imdsv2_required_with_hop_limit_two(instance: dict[str, Any]) -> None:
    """IMDSv2 required; hop limit 2 because the app container needs the role.

    The default for this module is hop-limit 1 (a container CANNOT reach IMDS),
    but MacroRAG's app container runs boto3 for the corpus S3 access and reaches
    the instance role through the docker bridge — one extra hop — so it is set to
    2 here. The compensating control is that the instance role is tightly
    ARN-scoped (own images, own secret, own bucket), so a container assuming it
    gains only what the app already needs. Tokens stay required (IMDSv1 off).
    """
    options = instance["MetadataOptions"]
    assert options["HttpTokens"] == "required"
    assert options["HttpPutResponseHopLimit"] == 2, (
        f"hop limit is {options['HttpPutResponseHopLimit']}; the boto3 app "
        "container needs 2 to reach the instance role through the docker bridge"
    )


def test_root_volume_encrypted_with_project_cmk(ec2_client: Any, instance: dict[str, Any]) -> None:
    volume_ids = [m["Ebs"]["VolumeId"] for m in instance["BlockDeviceMappings"] if "Ebs" in m]
    assert volume_ids, "instance has no EBS volumes"

    kms = boto3.Session(region_name=REGION).client("kms")
    expected = kms.describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"]["Arn"]

    for volume in ec2_client.describe_volumes(VolumeIds=volume_ids)["Volumes"]:
        assert volume["Encrypted"] is True
        assert volume.get("KmsKeyId") == expected


def test_dedicated_data_volume_attached_and_encrypted(
    ec2_client: Any, instance: dict[str, Any]
) -> None:
    """SQLite/traces live on a separate volume so they survive instance replacement.

    A right-size of the (deliberately oversized) t4g.large would replace the
    instance; keeping this state off the root is what makes that non-destructive.
    """
    mappings = {
        m["DeviceName"]: m["Ebs"]["VolumeId"] for m in instance["BlockDeviceMappings"] if "Ebs" in m
    }
    # Root is /dev/xvda; the data volume attaches at /dev/sdf.
    data_devices = [d for d in mappings if d.endswith("sdf") or d.endswith("xvdf")]
    assert data_devices, f"no data volume attached at /dev/sdf; devices: {sorted(mappings)}"

    volume = ec2_client.describe_volumes(VolumeIds=[mappings[data_devices[0]]])["Volumes"][0]
    assert volume["Encrypted"] is True, "data volume is not encrypted"
    assert volume["Size"] == EXPECTED_DATA_VOLUME_GB, (
        f"data volume is {volume['Size']} GB, expected {EXPECTED_DATA_VOLUME_GB}"
    )


def test_no_key_pair(instance: dict[str, Any]) -> None:
    assert not instance.get("KeyName"), "access should be Session Manager only"


def test_instance_is_a_registered_ssm_managed_node(instance: dict[str, Any]) -> None:
    """Also proves NAT egress works from the private subnet.

    A private-subnet instance reaches the SSM endpoints THROUGH the NAT. If the
    NAT is stopped, this fails even though the instance is perfectly healthy.
    """
    if instance["State"]["Name"] != "running":
        pytest.skip(
            f"instance is {instance['State']['Name']}; SSM registration applies "
            "only while running. UNVERIFIED, not passing."
        )

    ssm = boto3.Session(region_name=REGION).client("ssm")
    try:
        info = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance["InstanceId"]]}]
        )["InstanceInformationList"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("ssm:DescribeInstanceInformation not granted. UNVERIFIED, not passing.")
        raise

    assert info, (
        f"{instance['InstanceId']} is not a registered managed node. Either the "
        "agent has not registered yet, or the NAT instance is stopped — a "
        "private-subnet host reaches SSM through it."
    )
    assert info[0]["PingStatus"] == "Online"


# --- Role scoping: what it may and may not reach -----------------------------


@pytest.fixture(scope="module")
def role_arn(instance: dict[str, Any]) -> str:
    profile_arn = instance["IamInstanceProfile"]["Arn"]
    profile_name = profile_arn.rsplit("/", 1)[-1]

    iam = boto3.Session(region_name=REGION).client("iam")
    roles = iam.get_instance_profile(InstanceProfileName=profile_name)["InstanceProfile"]["Roles"]
    assert roles, "instance profile has no role"
    return str(roles[0]["Arn"])


def _simulate(role: str, action: str, resource: str) -> str:
    iam = boto3.Session(region_name=REGION).client("iam")
    try:
        return str(
            iam.simulate_principal_policy(
                PolicySourceArn=role, ActionNames=[action], ResourceArns=[resource]
            )["EvaluationResults"][0]["EvalDecision"]
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise


def test_role_can_read_its_own_secret(role_arn: str) -> None:
    """Positive control — without this the app cannot start once a value is set."""
    sm = boto3.Session(region_name=REGION).client("secretsmanager")
    secret_arn = sm.describe_secret(SecretId=f"{NAME_PREFIX}/macrorag/app")["ARN"]

    decision = _simulate(role_arn, "secretsmanager:GetSecretValue", secret_arn)
    assert decision == "allowed", f"instance role cannot read its own secret (decision: {decision})"


def test_role_cannot_read_another_applications_secret(role_arn: str) -> None:
    """The negative control that makes the positive one meaningful.

    Uses REAL sibling secrets (qdrant/app, arag/app) that share the secrets
    component: MacroRAG once granted itself values(...) of the whole component and
    so could read both — this asserts that over-grant is gone. Resolve the real
    ARNs (they carry a random suffix simulate matches literally); skip any not yet
    created rather than fail on a not-yet-provisioned sibling.
    """
    sm = boto3.Session(region_name=REGION).client("secretsmanager")
    for sibling in (f"{NAME_PREFIX}/qdrant/app", f"{NAME_PREFIX}/arag/app"):
        try:
            arn = sm.describe_secret(SecretId=sibling)["ARN"]
        except sm.exceptions.ResourceNotFoundException:
            continue
        decision = _simulate(role_arn, "secretsmanager:GetSecretValue", arn)
        assert decision != "allowed", (
            f"instance role can read {sibling} — a cross-subsystem secret leak "
            "(scope secret_arns to macrorag/app, not values() of the component)"
        )


def test_role_can_pull_its_own_images(role_arn: str) -> None:
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    own = f"arn:aws:ecr:{REGION}:{account}:repository/{NAME_PREFIX}/macrorag"

    decision = _simulate(role_arn, "ecr:BatchGetImage", own)
    assert decision == "allowed", f"instance role cannot pull its own image (decision: {decision})"


def test_role_cannot_pull_unrelated_images(role_arn: str) -> None:
    """RagInference is a REAL repo in the shared ECR component, deliberately not
    granted here — the grant is scoped to MacroRAG's own four repos, not every
    repo in the account. A stronger negative than a non-existent repo name."""
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    foreign = f"arn:aws:ecr:{REGION}:{account}:repository/{NAME_PREFIX}/raginference"

    decision = _simulate(role_arn, "ecr:BatchGetImage", foreign)
    assert decision != "allowed", (
        "instance role can pull the raginference image — the ECR grant is not "
        "scoped to MacroRAG's own repositories"
    )


def test_role_cannot_write_to_ecr(role_arn: str) -> None:
    """Hosts pull; only the build pipeline pushes."""
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    own = f"arn:aws:ecr:{REGION}:{account}:repository/{NAME_PREFIX}/macrorag"

    decision = _simulate(role_arn, "ecr:PutImage", own)
    assert decision != "allowed", "instance role can push images; it should only pull"


# --- S3: corpus read+write, nothing else -------------------------------------

CORPUS_BUCKET = f"arn:aws:s3:::{NAME_PREFIX}-macrorag-corpus-{REGION}"


def test_role_can_read_write_its_corpus(role_arn: str) -> None:
    """Positive control — without object CRUD the app cannot ingest or index."""
    obj = f"{CORPUS_BUCKET}/corpus/raw/ingest/doc"
    for action in ("s3:GetObject", "s3:PutObject", "s3:DeleteObject"):
        decision = _simulate(role_arn, action, obj)
        assert decision == "allowed", (
            f"instance role cannot {action} on its corpus (decision: {decision})"
        )


def test_role_can_list_its_corpus_bucket(role_arn: str) -> None:
    """ListBucket is on the bucket ARN, not the object ARN — a separate grant.

    iter_documents pages the corpus with list_objects_v2; without this, index
    reads see an empty corpus.
    """
    decision = _simulate(role_arn, "s3:ListBucket", CORPUS_BUCKET)
    assert decision == "allowed", (
        f"instance role cannot list its corpus bucket (decision: {decision})"
    )


def test_role_cannot_touch_an_unrelated_bucket(role_arn: str) -> None:
    """The negative control that makes the positive one meaningful.

    An unscoped s3:* would pass the tests above while also handing this host the
    RagInference weights bucket and every other genai-* bucket in the account.
    """
    foreign = f"arn:aws:s3:::{NAME_PREFIX}-raginference-weights-{REGION}/models/x"
    decision = _simulate(role_arn, "s3:GetObject", foreign)
    assert decision != "allowed", (
        "instance role can read an unrelated bucket — the grant is not ARN-scoped"
    )
