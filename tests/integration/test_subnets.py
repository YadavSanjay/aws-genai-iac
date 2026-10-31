"""Post-apply verification for dev/00-networking/subnets against the LIVE AWS API.

The point of this step is that the public/private split is real and testable
now, rather than asserted and only discovered to be wrong once a workload sits
in it.

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
VPC_NAME = f"{NAME_PREFIX}-vpc"

EXPECTED_AZ_COUNT = 2
EXPECTED_PUBLIC_CIDRS = {"10.10.0.0/20", "10.10.16.0/20"}
EXPECTED_PRIVATE_CIDRS = {"10.10.128.0/20", "10.10.144.0/20"}


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
def vpc_id(ec2_client: Any) -> str:
    vpcs = ec2_client.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [VPC_NAME]}])["Vpcs"]
    assert vpcs, f"no VPC tagged Name={VPC_NAME}"
    return str(vpcs[0]["VpcId"])


def _subnets(ec2_client: Any, vpc_id: str, tier: str) -> list[dict[str, Any]]:
    return list(
        ec2_client.describe_subnets(
            Filters=[
                {"Name": "vpc-id", "Values": [vpc_id]},
                {"Name": "tag:Tier", "Values": [tier]},
            ]
        )["Subnets"]
    )


@pytest.fixture(scope="module")
def public_subnets(ec2_client: Any, vpc_id: str) -> list[dict[str, Any]]:
    subnets = _subnets(ec2_client, vpc_id, "public")
    assert subnets, "no subnets tagged Tier=public — is the component applied?"
    return subnets


@pytest.fixture(scope="module")
def private_subnets(ec2_client: Any, vpc_id: str) -> list[dict[str, Any]]:
    subnets = _subnets(ec2_client, vpc_id, "private")
    assert subnets, "no subnets tagged Tier=private — is the component applied?"
    return subnets


# --- Layout ------------------------------------------------------------------


def test_subnets_span_expected_azs(
    public_subnets: list[dict[str, Any]], private_subnets: list[dict[str, Any]]
) -> None:
    public_azs = {s["AvailabilityZone"] for s in public_subnets}
    private_azs = {s["AvailabilityZone"] for s in private_subnets}

    assert len(public_azs) == EXPECTED_AZ_COUNT, f"public subnets span {public_azs}"
    assert len(private_azs) == EXPECTED_AZ_COUNT, f"private subnets span {private_azs}"
    assert public_azs == private_azs, (
        "public and private tiers are in different AZs, so a private subnet may "
        f"have no same-AZ egress path: public={public_azs} private={private_azs}"
    )


def test_subnet_cidrs_match_the_documented_plan(
    public_subnets: list[dict[str, Any]], private_subnets: list[dict[str, Any]]
) -> None:
    assert {s["CidrBlock"] for s in public_subnets} == EXPECTED_PUBLIC_CIDRS
    assert {s["CidrBlock"] for s in private_subnets} == EXPECTED_PRIVATE_CIDRS


def test_subnets_carry_mandatory_tags(
    public_subnets: list[dict[str, Any]], private_subnets: list[dict[str, Any]]
) -> None:
    for subnet in public_subnets + private_subnets:
        tags = {t["Key"]: t["Value"] for t in subnet.get("Tags", [])}
        for required in ("Project", "Environment", "ManagedBy", "Tier"):
            assert required in tags, (
                f"{subnet['SubnetId']} missing tag {required!r}. Present: {sorted(tags)}"
            )


# --- Public IP assignment ----------------------------------------------------


def test_no_subnet_auto_assigns_public_ips(
    public_subnets: list[dict[str, Any]], private_subnets: list[dict[str, Any]]
) -> None:
    """Including the PUBLIC subnets — this is the point.

    Auto-assignment makes a workload internet-addressable purely by landing in a
    subnet, with no explicit decision recorded in code. Anything that genuinely
    needs a public address requests one at launch, where it shows up in a plan.
    """
    for subnet in public_subnets + private_subnets:
        assert subnet["MapPublicIpOnLaunch"] is False, (
            f"{subnet['SubnetId']} auto-assigns public IPs"
        )


# --- Routing -----------------------------------------------------------------


def _route_table_for(ec2_client: Any, subnet_id: str) -> dict[str, Any]:
    tables = ec2_client.describe_route_tables(
        Filters=[{"Name": "association.subnet-id", "Values": [subnet_id]}]
    )["RouteTables"]
    assert tables, (
        f"{subnet_id} has no explicit route table association — it falls through "
        "to the VPC main route table, which is not managed here"
    )
    return dict(tables[0])


def test_public_subnets_route_to_the_internet_gateway(
    ec2_client: Any, public_subnets: list[dict[str, Any]]
) -> None:
    for subnet in public_subnets:
        table = _route_table_for(ec2_client, subnet["SubnetId"])
        default = [r for r in table["Routes"] if r.get("DestinationCidrBlock") == "0.0.0.0/0"]
        assert default, f"public subnet {subnet['SubnetId']} has no default route"
        assert default[0].get("GatewayId", "").startswith("igw-"), (
            f"public default route does not target an IGW: {default[0]}"
        )


def test_private_subnets_never_route_directly_to_the_internet(
    ec2_client: Any, private_subnets: list[dict[str, Any]]
) -> None:
    """The enduring security property, restated now that egress exists.

    Before the NAT instance this asserted private subnets had NO default route
    at all. They now legitimately have one — that is the point of the NAT step —
    so the meaningful control narrows: a private subnet's default route must go
    to a NAT device (a network interface), NEVER to an Internet Gateway.

    A default route to an IGW is exactly what would silently turn these subnets
    public while every other test kept passing.
    """
    for subnet in private_subnets:
        table = _route_table_for(ec2_client, subnet["SubnetId"])
        default = [r for r in table["Routes"] if r.get("DestinationCidrBlock") == "0.0.0.0/0"]

        if not default:
            continue  # No egress at all is also acceptable — it is not exposure.

        route = default[0]
        assert not route.get("GatewayId", "").startswith("igw-"), (
            f"private subnet {subnet['SubnetId']} routes directly to an Internet "
            f"Gateway ({route.get('GatewayId')}). It is private in name only."
        )
        assert route.get("NetworkInterfaceId", "").startswith("eni-"), (
            f"private subnet {subnet['SubnetId']} default route targets "
            f"{route}, expected a NAT network interface."
        )


def test_each_private_subnet_has_its_own_route_table(
    ec2_client: Any, private_subnets: list[dict[str, Any]]
) -> None:
    """Per-AZ tables cost nothing and let a future egress device be same-AZ.

    A shared table would force cross-AZ traffic to whichever zone hosts the NAT
    device, at $0.01/GB in each direction.
    """
    table_ids = {
        _route_table_for(ec2_client, s["SubnetId"])["RouteTableId"] for s in private_subnets
    }
    assert len(table_ids) == len(private_subnets), (
        f"{len(private_subnets)} private subnets share {len(table_ids)} route table(s)"
    )


def test_no_subnet_relies_on_the_main_route_table(
    ec2_client: Any,
    vpc_id: str,
    public_subnets: list[dict[str, Any]],
    private_subnets: list[dict[str, Any]],
) -> None:
    """Explicit association everywhere, so nothing inherits connectivity."""
    main = ec2_client.describe_route_tables(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "association.main", "Values": ["true"]},
        ]
    )["RouteTables"]
    assert main, "no main route table found"

    main_subnets = {
        a.get("SubnetId") for a in main[0]["Associations"] if a.get("SubnetId") is not None
    }
    ours = {s["SubnetId"] for s in public_subnets + private_subnets}
    assert not (main_subnets & ours), (
        f"subnets associated with the main route table: {main_subnets & ours}"
    )
