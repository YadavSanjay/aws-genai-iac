"""Post-apply verification for dev/00-networking/vpc against the LIVE AWS API.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import os
import time
from typing import Any

import boto3
import pytest

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")
ENV_NAME = os.environ.get("IAC_ENV_NAME", "dev")

VPC_NAME = f"{NAME_PREFIX}-vpc"
EXPECTED_CIDR = os.environ.get("IAC_VPC_CIDR", "10.10.0.0/16")
LOGS_BUCKET = os.environ.get("IAC_LOGS_BUCKET", f"genai-{ENV_NAME}-logs-{REGION}")

# How long to wait for a flow-log object once the VPC actually has traffic.
# First delivery lags roughly 5-10 minutes behind the first flow.
DELIVERY_TIMEOUT_SECONDS = int(os.environ.get("IAC_FLOW_LOG_TIMEOUT", "600"))
DELIVERY_POLL_SECONDS = 30


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
def vpc(ec2_client: Any) -> dict[str, Any]:
    vpcs = ec2_client.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [VPC_NAME]}])["Vpcs"]
    assert vpcs, f"no VPC tagged Name={VPC_NAME} — is the component applied?"
    assert len(vpcs) == 1, f"expected exactly one VPC named {VPC_NAME}, found {len(vpcs)}"
    return dict(vpcs[0])


@pytest.fixture(scope="module")
def vpc_id(vpc: dict[str, Any]) -> str:
    return str(vpc["VpcId"])


# --- VPC ---------------------------------------------------------------------


def test_vpc_has_expected_cidr_and_is_available(vpc: dict[str, Any]) -> None:
    assert vpc["CidrBlock"] == EXPECTED_CIDR
    assert vpc["State"] == "available"
    assert vpc["IsDefault"] is False, "this must not be the account's default VPC"


def test_vpc_dns_is_enabled(ec2_client: Any, vpc_id: str) -> None:
    """Required for VPC endpoints and private hosted zones later."""
    for attribute in ("enableDnsSupport", "enableDnsHostnames"):
        result = ec2_client.describe_vpc_attribute(VpcId=vpc_id, Attribute=attribute)
        key = attribute[0].upper() + attribute[1:]
        assert result[key]["Value"] is True, f"{attribute} is disabled"


def test_vpc_carries_mandatory_tags(vpc: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in vpc.get("Tags", [])}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"
    assert tags["ManagedBy"] == "terragrunt"


# --- Default security group --------------------------------------------------


def test_default_security_group_has_no_rules(ec2_client: Any, vpc_id: str) -> None:
    """The control that matters most here.

    AWS creates the default SG with allow-all-from-self ingress and unrestricted
    egress, and it cannot be deleted. Anything launched without an explicit SG
    lands in it. Stripped of rules, such a workload fails closed and visibly.
    """
    groups = ec2_client.describe_security_groups(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "group-name", "Values": ["default"]},
        ]
    )["SecurityGroups"]
    assert groups, "no default security group found"

    default = groups[0]
    assert default["IpPermissions"] == [], (
        f"default SG still has ingress rules: {default['IpPermissions']}"
    )
    assert default["IpPermissionsEgress"] == [], (
        f"default SG still has egress rules: {default['IpPermissionsEgress']}"
    )


def test_nothing_is_attached_to_the_default_security_group(ec2_client: Any, vpc_id: str) -> None:
    """Negative control: the default SG is not meant to be used at all."""
    groups = ec2_client.describe_security_groups(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "group-name", "Values": ["default"]},
        ]
    )["SecurityGroups"]
    group_id = groups[0]["GroupId"]

    interfaces = ec2_client.describe_network_interfaces(
        Filters=[{"Name": "group-id", "Values": [group_id]}]
    )["NetworkInterfaces"]

    assert not interfaces, (
        f"{len(interfaces)} network interface(s) use the default security group. "
        "Workloads must carry a purpose-built SG."
    )


# --- Internet Gateway --------------------------------------------------------


def test_internet_gateway_is_attached(ec2_client: Any, vpc_id: str) -> None:
    igws = ec2_client.describe_internet_gateways(
        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
    )["InternetGateways"]
    assert igws, "no Internet Gateway attached"

    attachments = igws[0]["Attachments"]
    assert any(a["State"] in ("available", "attached") for a in attachments), (
        f"IGW is not attached: {attachments}"
    )


def test_only_public_route_tables_reach_the_internet_gateway(ec2_client: Any, vpc_id: str) -> None:
    """An IGW is not exposure on its own; a 0.0.0.0/0 route to it is.

    Before the subnet step this asserted NO such route existed anywhere. Now
    that public subnets legitimately have one, the meaningful control is
    narrower but stronger: every route to the IGW must belong to a route table
    explicitly tagged Tier=public. A default route appearing on a private table
    is what would silently un-private those subnets.
    """
    tables = ec2_client.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])[
        "RouteTables"
    ]

    offenders = []
    for table in tables:
        has_igw_default = any(
            r.get("DestinationCidrBlock") == "0.0.0.0/0"
            and r.get("GatewayId", "").startswith("igw-")
            for r in table["Routes"]
        )
        if not has_igw_default:
            continue

        tags = {t["Key"]: t["Value"] for t in table.get("Tags", [])}
        if tags.get("Tier") != "public":
            offenders.append((table["RouteTableId"], tags))

    assert not offenders, (
        f"route table(s) reach the internet without being tagged Tier=public: {offenders}"
    )


# --- Flow logs ---------------------------------------------------------------


@pytest.fixture(scope="module")
def flow_log(ec2_client: Any, vpc_id: str) -> dict[str, Any]:
    logs = ec2_client.describe_flow_logs(Filters=[{"Name": "resource-id", "Values": [vpc_id]}])[
        "FlowLogs"
    ]
    assert logs, f"no flow log on {vpc_id} — CKV2_AWS_11 would be a real finding"
    return dict(logs[0])


def test_flow_log_is_active_and_targets_the_archive(flow_log: dict[str, Any]) -> None:
    assert flow_log["FlowLogStatus"] == "ACTIVE", f"flow log status is {flow_log['FlowLogStatus']}"
    assert flow_log["LogDestinationType"] == "s3"
    assert LOGS_BUCKET in flow_log["LogDestination"]
    assert flow_log["TrafficType"] == "ALL"

    # DeliverLogsStatus and DeliverLogsErrorMessage are the only loud signals
    # this path produces. They are necessary but NOT sufficient: SUCCESS with
    # zero objects delivered is a normal state for a VPC with no traffic, so
    # test_flow_logs_actually_deliver_objects still has to do its own work.
    error = flow_log.get("DeliverLogsErrorMessage")
    assert not error, f"flow log reports a delivery error: {error}"

    status = flow_log.get("DeliverLogsStatus")
    assert status in (None, "SUCCESS"), (
        f"DeliverLogsStatus is {status!r} — the destination is rejecting writes. "
        "Check the bucket policy and the CMK grant for delivery.logs.amazonaws.com."
    )


def test_flow_log_uses_cost_efficient_format(flow_log: dict[str, Any]) -> None:
    """Parquet + hourly partitions is a real cost decision, not cosmetics."""
    options = flow_log.get("DestinationOptions", {})
    assert options.get("FileFormat") == "parquet"
    assert options.get("PerHourPartition") is True
    assert options.get("HiveCompatiblePartitions") is True
    assert flow_log["MaxAggregationInterval"] == 600


def test_flow_logs_actually_deliver_objects(ec2_client: Any, vpc_id: str) -> None:
    """The assertion that a config read cannot substitute for.

    A missing KMS grant or bucket-policy statement leaves the flow log reporting
    ACTIVE while delivering nothing — it presents as a networking problem, not a
    permissions one. So verify objects genuinely arrive.

    Flow logs only publish when there are flows. A VPC with no network
    interfaces generates no traffic and therefore no objects, so this SKIPS
    until something exists to generate traffic. That is honest: delivery is
    UNVERIFIED at that point, not proven.
    """
    interfaces = ec2_client.describe_network_interfaces(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
    )["NetworkInterfaces"]

    if not interfaces:
        pytest.skip(
            "VPC has no network interfaces, so it generates no traffic and flow "
            "logs have nothing to publish. End-to-end delivery is UNVERIFIED "
            "until a workload exists — not passing. This test becomes a real "
            "assertion once subnets and an instance land."
        )

    s3 = boto3.Session(region_name=REGION).client("s3")
    deadline = time.monotonic() + DELIVERY_TIMEOUT_SECONDS
    prefix = "AWSLogs/"

    while True:
        listing = s3.list_objects_v2(Bucket=LOGS_BUCKET, Prefix=prefix, MaxKeys=1)
        if listing.get("KeyCount", 0) > 0:
            return
        if time.monotonic() >= deadline:
            break
        time.sleep(DELIVERY_POLL_SECONDS)

    pytest.fail(
        f"no flow-log objects under s3://{LOGS_BUCKET}/{prefix} after "
        f"{DELIVERY_TIMEOUT_SECONDS}s despite {len(interfaces)} network "
        "interface(s) in the VPC. Check the bucket policy "
        "(AWSLogDeliveryWrite/AclCheck) and the CMK grant for "
        "delivery.logs.amazonaws.com — both fail silently."
    )
