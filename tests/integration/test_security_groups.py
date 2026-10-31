"""Post-apply verification for dev/00-networking/security-groups.

Security groups are inert until something attaches to them, so what is testable
here is the rule set itself — which is exactly where the mistakes live: a stray
SSH rule, a CIDR where a group reference belongs, egress opened to every port.

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

ALB_SG_NAME = f"{NAME_PREFIX}-alb"
APP_SG_NAME = f"{NAME_PREFIX}-app"
EXPECTED_APP_PORT = 8000

# Ports that must never accept traffic from the internet on any group here.
NEVER_PUBLIC_PORTS = {22, 3389, 5432, 6333, 6334, 27017, 3306, 6379}


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


def _group(ec2_client: Any, vpc_id: str, name: str) -> dict[str, Any]:
    groups = ec2_client.describe_security_groups(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "group-name", "Values": [name]},
        ]
    )["SecurityGroups"]
    assert groups, f"no security group named {name!r} — is the component applied?"
    return dict(groups[0])


@pytest.fixture(scope="module")
def alb_sg(ec2_client: Any, vpc_id: str) -> dict[str, Any]:
    return _group(ec2_client, vpc_id, ALB_SG_NAME)


@pytest.fixture(scope="module")
def app_sg(ec2_client: Any, vpc_id: str) -> dict[str, Any]:
    return _group(ec2_client, vpc_id, APP_SG_NAME)


def _public_ingress_ports(group: dict[str, Any]) -> set[int]:
    ports: set[int] = set()
    for rule in group["IpPermissions"]:
        if not any(r["CidrIp"] == "0.0.0.0/0" for r in rule.get("IpRanges", [])):
            continue
        from_port = rule.get("FromPort")
        to_port = rule.get("ToPort")
        if from_port is None:
            # All-protocol rule: treat as every port.
            ports.update(range(0, 65536))
        else:
            ports.update(range(from_port, to_port + 1))
    return ports


# --- ALB ---------------------------------------------------------------------


def test_alb_accepts_nothing_from_the_internet(alb_sg: dict[str, Any]) -> None:
    """The ALB is INTERNAL — no rule should reference 0.0.0.0/0 at all.

    Combined with the internal scheme this is belt and braces: even if the
    scheme were changed to internet-facing by mistake, no security group rule
    would admit public traffic.
    """
    public = _public_ingress_ports(alb_sg)
    assert not public, (
        f"ALB security group accepts internet traffic on {sorted(public)}. "
        "This ALB is internal; ingress should be the VPC CIDR only."
    )


def test_alb_accepts_the_vpc_on_the_listener_port(
    ec2_client: Any, vpc_id: str, alb_sg: dict[str, Any]
) -> None:
    """VPC CIDR, not a group reference, and deliberately so.

    Legitimate callers include a Session Manager tunnel opened through ANY
    instance — which no single security group captures. The ALB being internal
    is what makes a CIDR acceptable here.

    Port 80 because there is no domain and therefore no certificate; expect 443
    once ACM can issue one.
    """
    vpc_cidr = ec2_client.describe_vpcs(VpcIds=[vpc_id])["Vpcs"][0]["CidrBlock"]

    ports = {
        rule["FromPort"]
        for rule in alb_sg["IpPermissions"]
        if any(r["CidrIp"] == vpc_cidr for r in rule.get("IpRanges", []))
    }
    assert ports == {80}, (
        f"ALB accepts {sorted(ports)} from the VPC; expected only 80. Once a "
        "certificate exists this becomes 443."
    )


def test_app_tier_can_reach_the_alb_for_east_west(
    app_sg: dict[str, Any], alb_sg: dict[str, Any]
) -> None:
    """Applications calling each other go out through the internal ALB.

    Egress here is deliberately not wide open, so this rule is required — and
    its absence presents as an unexplained timeout, since egress rules are the
    last place anyone looks.
    """
    referenced = [
        pair["GroupId"]
        for rule in app_sg["IpPermissionsEgress"]
        for pair in rule.get("UserIdGroupPairs", [])
    ]
    assert alb_sg["GroupId"] in referenced, (
        f"app tier has no egress to the ALB group {alb_sg['GroupId']} — "
        "east-west calls between subsystems will time out"
    )


def test_alb_forwards_to_the_app_tier_by_group_reference(
    alb_sg: dict[str, Any], app_sg: dict[str, Any]
) -> None:
    """A CIDR here would be either broader than the tier or need constant editing."""
    referenced = [
        pair["GroupId"]
        for rule in alb_sg["IpPermissionsEgress"]
        for pair in rule.get("UserIdGroupPairs", [])
    ]
    assert app_sg["GroupId"] in referenced, (
        f"ALB egress does not reference the app group {app_sg['GroupId']}: {referenced}"
    )


def test_alb_egress_is_not_wide_open(alb_sg: dict[str, Any]) -> None:
    """The ALB has exactly one job — reach the app tier."""
    open_egress = [
        rule
        for rule in alb_sg["IpPermissionsEgress"]
        if any(r["CidrIp"] == "0.0.0.0/0" for r in rule.get("IpRanges", []))
    ]
    assert not open_egress, f"ALB has unrestricted egress: {open_egress}"


# --- App tier ----------------------------------------------------------------


def test_app_tier_is_unreachable_from_the_internet(app_sg: dict[str, Any]) -> None:
    """The core property: the app tier is reachable only via the ALB."""
    public = _public_ingress_ports(app_sg)
    assert not public, (
        f"app tier accepts public traffic on {sorted(public)[:20]}. "
        "It must be reachable only through the ALB."
    )


def test_app_ingress_comes_only_from_known_groups(
    app_sg: dict[str, Any], alb_sg: dict[str, Any]
) -> None:
    """Two permitted sources, both by group reference: the ALB and the tier itself.

    The self-reference is the Q4a east-west rule — app hosts calling each other's
    REST APIs, which no other rule covers. It is a DELIBERATE relaxation (see the
    module README): one shared app group means it admits any app host to any
    other on this port, bounded to a single TCP port in private subnets.

    Written as set equality on both the sources and the ports rather than as a
    count, so a third source, a widened port range, or any CIDR rule fails here
    instead of passing quietly under a bumped expected-count.
    """
    for rule in app_sg["IpPermissions"]:
        assert not rule.get("IpRanges"), f"app ingress carries a CIDR rule: {rule['IpRanges']}"
        assert not rule.get("Ipv6Ranges"), f"app ingress carries an IPv6 CIDR rule: {rule}"
        assert (rule["FromPort"], rule["ToPort"]) == (EXPECTED_APP_PORT, EXPECTED_APP_PORT), (
            f"app ingress opens {rule['FromPort']}-{rule['ToPort']}, expected only "
            f"{EXPECTED_APP_PORT}"
        )

    sources = {
        pair["GroupId"] for rule in app_sg["IpPermissions"] for pair in rule["UserIdGroupPairs"]
    }
    assert sources == {alb_sg["GroupId"], app_sg["GroupId"]}, (
        f"app ingress sources are {sorted(sources)}; expected exactly the ALB "
        f"({alb_sg['GroupId']}) and the app tier itself ({app_sg['GroupId']})"
    )


def test_app_tier_can_reach_its_peers_directly(app_sg: dict[str, Any]) -> None:
    """The egress half of the east-west path — both halves are required.

    A security group is stateful per rule, but caller and callee are different
    roles: the caller needs egress and the callee needs ingress. Here they are
    the same group wearing both hats, so a missing egress rule would leave
    Faultline unable to call XbrlRag while the ingress side looked correct.
    """
    peers = [
        rule
        for rule in app_sg["IpPermissionsEgress"]
        if any(p["GroupId"] == app_sg["GroupId"] for p in rule.get("UserIdGroupPairs", []))
    ]
    assert peers, (
        "app tier has no self-referencing egress rule — it can be called by its "
        "peers but cannot call them"
    )
    assert any(
        r["FromPort"] == EXPECTED_APP_PORT and r["ToPort"] == EXPECTED_APP_PORT for r in peers
    ), f"no app-to-app egress on {EXPECTED_APP_PORT}: {peers}"


def test_no_ssh_anywhere(alb_sg: dict[str, Any], app_sg: dict[str, Any]) -> None:
    """Administrative access is SSM Session Manager, which needs no inbound rule.

    An SSH rule is the single most likely thing to be left open by accident.
    """
    for group in (alb_sg, app_sg):
        for rule in group["IpPermissions"]:
            from_port, to_port = rule.get("FromPort"), rule.get("ToPort")
            if from_port is None:
                pytest.fail(f"{group['GroupName']} has an all-ports ingress rule")
            assert not (from_port <= 22 <= to_port), f"{group['GroupName']} exposes port 22: {rule}"


def test_no_sensitive_port_is_publicly_reachable(
    alb_sg: dict[str, Any], app_sg: dict[str, Any]
) -> None:
    """Negative control covering ports that later tiers will use."""
    for group in (alb_sg, app_sg):
        public = _public_ingress_ports(group)
        exposed = NEVER_PUBLIC_PORTS & public
        assert not exposed, f"{group['GroupName']} exposes {sorted(exposed)} to the internet"


def test_app_egress_is_port_restricted(app_sg: dict[str, Any]) -> None:
    """0.0.0.0/0 egress is unavoidable for external LLM APIs — all-ports is not.

    The compensating control for the wide destination is the narrow port set.
    """
    for rule in app_sg["IpPermissionsEgress"]:
        if not any(r["CidrIp"] == "0.0.0.0/0" for r in rule.get("IpRanges", [])):
            continue
        assert rule.get("IpProtocol") != "-1", (
            "app tier egresses to the internet on ALL protocols and ports; "
            "it should be restricted to 443"
        )
        assert rule["FromPort"] == 443 and rule["ToPort"] == 443, (
            f"unexpected internet egress port range: {rule['FromPort']}-{rule['ToPort']}"
        )


def test_app_can_resolve_dns(app_sg: dict[str, Any], vpc_id: str, ec2_client: Any) -> None:
    """Easy to forget, and it fails looking like a network fault rather than an SG one."""
    vpc_cidr = ec2_client.describe_vpcs(VpcIds=[vpc_id])["Vpcs"][0]["CidrBlock"]

    protocols = {
        rule["IpProtocol"]
        for rule in app_sg["IpPermissionsEgress"]
        if rule.get("FromPort") == 53
        and any(r["CidrIp"] == vpc_cidr for r in rule.get("IpRanges", []))
    }
    assert {"tcp", "udp"} <= protocols, (
        f"DNS egress to the VPC resolver is incomplete: {protocols}. "
        "TCP is needed for responses over 512 bytes."
    )


# --- Tagging -----------------------------------------------------------------


def test_groups_carry_mandatory_tags(alb_sg: dict[str, Any], app_sg: dict[str, Any]) -> None:
    for group in (alb_sg, app_sg):
        tags = {t["Key"]: t["Value"] for t in group.get("Tags", [])}
        for required in ("Project", "Environment", "ManagedBy", "Tier"):
            assert required in tags, (
                f"{group['GroupName']} missing tag {required!r}. Present: {sorted(tags)}"
            )
