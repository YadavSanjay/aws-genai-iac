"""Post-apply verification for dev/00-networking/nat against the LIVE AWS API.

Most of what can go wrong here is silent: source/dest check left on, NAT rules
that vanish on the second boot, a route pointing at an instance id rather than
an ENI. None of those produce an error — they produce "the internet does not
work from private subnets".

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

NAT_NAME = f"{NAME_PREFIX}-nat"
VPC_NAME = f"{NAME_PREFIX}-vpc"
EXPECTED_INSTANCE_TYPE = "t4g.nano"
PRIVATE_CIDRS = {"10.10.128.0/20", "10.10.144.0/20"}


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
            {"Name": "tag:Name", "Values": [NAT_NAME]},
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running", "stopped", "stopping"],
            },
        ]
    )["Reservations"]
    instances = [i for r in reservations for i in r["Instances"]]
    assert instances, f"no instance tagged Name={NAT_NAME} — is the component applied?"
    assert len(instances) == 1, f"expected one NAT instance, found {len(instances)}"
    return dict(instances[0])


# --- The line that makes it a NAT --------------------------------------------


def test_source_dest_check_is_disabled(instance: dict[str, Any]) -> None:
    """The single most important setting, and the quietest failure.

    With the check ON, EC2 drops every packet whose source or destination is not
    this instance — which is every forwarded packet. Private instances then have
    a perfectly correct route and still reach nothing.
    """
    assert instance["SourceDestCheck"] is False, (
        "source/dest check is ENABLED — this instance will silently drop every "
        "forwarded packet despite the routes being correct."
    )


def test_instance_is_graviton_and_right_sized(instance: dict[str, Any]) -> None:
    assert instance["InstanceType"] == EXPECTED_INSTANCE_TYPE
    assert instance["Architecture"] == "arm64", (
        f"architecture is {instance['Architecture']} — the ~20% Graviton saving requires arm64"
    )


def test_instance_has_a_public_address(instance: dict[str, Any]) -> None:
    """Required, not a defect. Positive control for the CKV_AWS_88 skip.

    A NAT device translates private-tier traffic to its own public address; one
    without a public IP forwards packets nowhere.

    Only observable while RUNNING. The address is not elastic: it is released on
    stop and a fresh one assigned on start, and AWS exposes no attribute on a
    stopped instance saying whether one will be. The subnet is not the answer
    either — `MapPublicIpOnLaunch` is false on the public subnets here, because
    the address comes from the instance's own `associate_public_ip_address`,
    which is a launch-time argument rather than queryable state.

    Stopped is the normal state for this estate (nightly, and continuously while
    parked), so this reads as UNVERIFIED then rather than as a pass or a failure.
    """
    if instance["State"]["Name"] != "running":
        pytest.skip(
            f"instance is {instance['State']['Name']}; the auto-assigned public IP "
            "is released on stop and only exists while running. UNVERIFIED, not passing."
        )

    assert instance.get("PublicIpAddress"), (
        "NAT instance has no public IP and cannot forward traffic to the internet"
    )


# --- Hardening ---------------------------------------------------------------


def test_imdsv2_is_required(instance: dict[str, Any]) -> None:
    """IMDSv1's unauthenticated GET is the classic SSRF path to credentials."""
    options = instance["MetadataOptions"]
    assert options["HttpTokens"] == "required", (
        f"IMDS tokens are {options['HttpTokens']} — IMDSv1 remains reachable"
    )
    assert options["HttpPutResponseHopLimit"] == 1, (
        "a hop limit above 1 lets a container reach instance metadata"
    )


def test_root_volume_is_encrypted_with_the_project_cmk(
    ec2_client: Any, instance: dict[str, Any]
) -> None:
    volume_ids = [m["Ebs"]["VolumeId"] for m in instance["BlockDeviceMappings"] if "Ebs" in m]
    assert volume_ids, "instance has no EBS volumes"

    kms = boto3.Session(region_name=REGION).client("kms")
    expected = kms.describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"]["Arn"]

    for volume in ec2_client.describe_volumes(VolumeIds=volume_ids)["Volumes"]:
        assert volume["Encrypted"] is True, f"volume {volume['VolumeId']} is unencrypted"
        assert volume.get("KmsKeyId") == expected, (
            f"volume {volume['VolumeId']} uses {volume.get('KmsKeyId')}, not the project CMK"
        )


def test_no_key_pair_is_attached(instance: dict[str, Any]) -> None:
    """Negative control: access is Session Manager, not SSH.

    A key pair implies someone intended SSH, which implies an inbound rule
    somewhere — the exact thing this project avoids.
    """
    assert not instance.get("KeyName"), (
        f"instance has key pair {instance.get('KeyName')!r}; access should be Session Manager only"
    )


# --- Security group ----------------------------------------------------------


@pytest.fixture(scope="module")
def security_group(ec2_client: Any, instance: dict[str, Any]) -> dict[str, Any]:
    group_id = instance["SecurityGroups"][0]["GroupId"]
    return dict(ec2_client.describe_security_groups(GroupIds=[group_id])["SecurityGroups"][0])


def test_nat_accepts_nothing_from_the_internet(security_group: dict[str, Any]) -> None:
    """The compensating control for having a public IP.

    Ingress is deliberately wide by PROTOCOL — a NAT forwards whatever the
    private tier sends — so the source restriction is the only thing standing
    between this box and the internet.
    """
    for rule in security_group["IpPermissions"]:
        public = [r for r in rule.get("IpRanges", []) if r["CidrIp"] == "0.0.0.0/0"]
        assert not public, (
            f"NAT security group accepts traffic from the internet: {rule}. "
            "It must accept only the private subnet CIDRs."
        )


def test_nat_ingress_is_exactly_the_private_subnets(security_group: dict[str, Any]) -> None:
    sources = {
        r["CidrIp"] for rule in security_group["IpPermissions"] for r in rule.get("IpRanges", [])
    }
    assert sources == PRIVATE_CIDRS, (
        f"NAT ingress sources are {sources}, expected exactly {PRIVATE_CIDRS}"
    )


# --- Routing -----------------------------------------------------------------


def test_private_route_tables_target_the_eni(ec2_client: Any, instance: dict[str, Any]) -> None:
    """Targeting the ENI rather than the instance is what survives a stop/start.

    An instance-id route is invalidated when the instance stops, so the
    scheduled shutdown would need automation to restore egress. The ENI persists.
    """
    eni_id = instance["NetworkInterfaces"][0]["NetworkInterfaceId"]

    tables = ec2_client.describe_route_tables(
        Filters=[{"Name": "tag:Tier", "Values": ["private"]}]
    )["RouteTables"]
    assert tables, "no route tables tagged Tier=private"

    for table in tables:
        default = [r for r in table["Routes"] if r.get("DestinationCidrBlock") == "0.0.0.0/0"]
        assert default, f"{table['RouteTableId']} has no default route"
        assert default[0].get("NetworkInterfaceId") == eni_id, (
            f"{table['RouteTableId']} default route targets "
            f"{default[0].get('NetworkInterfaceId') or default[0].get('InstanceId')}, "
            f"expected the NAT ENI {eni_id}"
        )


# --- The end-to-end proof ----------------------------------------------------


def test_instance_is_a_registered_ssm_managed_node(instance: dict[str, Any]) -> None:
    """Proves the boundary grant, instance role and agent all actually work.

    This is the only check here that exercises the whole chain rather than
    reading configuration. Until RuntimeSsmManagedNode was added to the app
    permissions boundary, the boundary capped SSM away entirely and the instance
    never appeared as a managed node — with no error anywhere to say why.

    Registration takes a few minutes after first boot.
    """
    if instance["State"]["Name"] != "running":
        pytest.skip(
            f"instance is {instance['State']['Name']}; SSM registration only "
            "applies while running. UNVERIFIED, not passing."
        )

    ssm = boto3.Session(region_name=REGION).client("ssm")
    try:
        info = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance["InstanceId"]]}]
        )["InstanceInformationList"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip(
                "ssm:DescribeInstanceInformation not granted to the exec role. "
                "Apply the iam-baseline change (admin step) to enable this check "
                "for every instance. UNVERIFIED, not passing."
            )
        raise

    assert info, (
        f"{instance['InstanceId']} is not a registered SSM managed node. Either "
        "the agent has not registered yet (wait a few minutes), or the app "
        "permissions boundary is capping away the SSM actions the instance role "
        "needs — the latter fails silently and looks like a networking problem."
    )
    assert info[0]["PingStatus"] == "Online", f"SSM agent status is {info[0]['PingStatus']}"
