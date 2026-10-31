"""Post-apply verification for dev/00-networking/endpoints against the LIVE AWS API.

The failure mode here is silent in both directions: a route table missing the
endpoint route keeps paying NAT charges with no error, and an over-tight policy
breaks ECR pulls with an opaque 403 that looks like a networking fault.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import json
import os
from typing import Any

import boto3
import pytest

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")
VPC_NAME = f"{NAME_PREFIX}-vpc"
ENDPOINT_NAME = f"{NAME_PREFIX}-s3-gateway"

# Reads that must keep working through the endpoint, or instance bootstrap and
# container pulls break.
REQUIRED_READ_ACTIONS = {"s3:GetObject", "s3:ListBucket"}


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


@pytest.fixture(scope="module")
def endpoint(ec2_client: Any, vpc_id: str) -> dict[str, Any]:
    endpoints = ec2_client.describe_vpc_endpoints(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "service-name", "Values": [f"com.amazonaws.{REGION}.s3"]},
        ]
    )["VpcEndpoints"]
    assert endpoints, "no S3 endpoint on the VPC — is the component applied?"
    return dict(endpoints[0])


# --- Endpoint shape ----------------------------------------------------------


def test_endpoint_is_a_gateway_and_available(endpoint: dict[str, Any]) -> None:
    """Gateway, not Interface — the latter costs ~$7.30/month per AZ."""
    assert endpoint["VpcEndpointType"] == "Gateway", (
        f"endpoint is {endpoint['VpcEndpointType']}, which carries an hourly charge"
    )
    assert endpoint["State"] == "available", f"endpoint state is {endpoint['State']}"


def test_endpoint_carries_mandatory_tags(endpoint: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in endpoint.get("Tags", [])}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"
    assert tags.get("Name") == ENDPOINT_NAME


# --- Route coverage: the silent cost leak ------------------------------------


def test_every_route_table_uses_the_endpoint(
    ec2_client: Any, vpc_id: str, endpoint: dict[str, Any]
) -> None:
    """A table left out keeps sending S3 traffic through NAT, with no error.

    That is a pure cost leak: nothing breaks, nothing logs, the bill just grows.
    """
    all_tables = {
        t["RouteTableId"]
        for t in ec2_client.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])[
            "RouteTables"
        ]
        # The main route table has no subnets associated by design.
        if any(not a.get("Main", False) for a in t.get("Associations", []))
    }
    associated = set(endpoint["RouteTableIds"])

    missing = all_tables - associated
    assert not missing, (
        f"route table(s) not associated with the S3 endpoint: {missing}. "
        "Their S3 traffic will route through NAT and be billed per GB."
    )


def test_endpoint_route_is_present_in_route_tables(
    ec2_client: Any, vpc_id: str, endpoint: dict[str, Any]
) -> None:
    """Association is configuration; the injected prefix-list route is the effect."""
    tables = ec2_client.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])[
        "RouteTables"
    ]

    with_endpoint = [
        t["RouteTableId"]
        for t in tables
        if any(r.get("GatewayId") == endpoint["VpcEndpointId"] for r in t["Routes"])
    ]
    assert len(with_endpoint) == len(endpoint["RouteTableIds"]), (
        f"{len(endpoint['RouteTableIds'])} tables associated but "
        f"{len(with_endpoint)} carry the endpoint route: {with_endpoint}"
    )


# --- Policy ------------------------------------------------------------------


@pytest.fixture(scope="module")
def policy(endpoint: dict[str, Any]) -> dict[str, Any]:
    raw = endpoint.get("PolicyDocument")
    assert raw, "endpoint has no policy — it is at AWS's full-access default"
    return dict(json.loads(raw))


def test_reads_still_work_against_aws_owned_buckets(policy: dict[str, Any]) -> None:
    """The over-tightening trap.

    Restricting the endpoint to our own buckets breaks ECR pulls, Amazon Linux
    repos and SSM agent downloads — all AWS-owned buckets whose names vary by
    region and change over time. The failure is an opaque S3 403 during
    bootstrap that presents as a networking fault.
    """
    read_all = [
        s
        for s in policy["Statement"]
        if s["Effect"] == "Allow"
        and ("*" in ([s["Resource"]] if isinstance(s["Resource"], str) else s["Resource"]))
    ]
    assert read_all, (
        "no statement grants access to buckets outside the project. ECR pulls "
        "and OS package installs will fail with opaque 403s."
    )

    granted: set[str] = set()
    for stmt in read_all:
        actions = stmt["Action"]
        granted.update([actions] if isinstance(actions, str) else actions)

    assert granted >= REQUIRED_READ_ACTIONS, (
        f"missing read actions for AWS-owned buckets: {REQUIRED_READ_ACTIONS - granted}"
    )


def test_writes_to_foreign_buckets_are_not_permitted(policy: dict[str, Any]) -> None:
    """The control this policy exists for.

    Exfiltration through an S3 endpoint means PutObject to a bucket someone else
    controls. Reading foreign buckets is fine and load-bearing; writing to them
    is not.
    """
    write_actions = {"s3:PutObject", "s3:*", "s3:Put*"}

    for stmt in policy["Statement"]:
        if stmt["Effect"] != "Allow":
            continue
        resources = stmt["Resource"]
        resources = [resources] if isinstance(resources, str) else resources
        if "*" not in resources:
            continue

        actions = stmt["Action"]
        actions = [actions] if isinstance(actions, str) else actions
        offending = write_actions & set(actions)
        assert not offending, (
            f"statement {stmt.get('Sid')!r} permits {offending} on ALL buckets — "
            "data can be written out to a bucket outside this account."
        )


def test_project_buckets_remain_fully_writable(policy: dict[str, Any]) -> None:
    """Positive control: the restriction must not have broken our own access."""
    scoped = [
        s
        for s in policy["Statement"]
        if s["Effect"] == "Allow"
        and "*" not in ([s["Resource"]] if isinstance(s["Resource"], str) else s["Resource"])
    ]
    assert scoped, "no statement grants full access to the project's own buckets"

    resources: set[str] = set()
    for stmt in scoped:
        res = stmt["Resource"]
        resources.update([res] if isinstance(res, str) else res)

    assert any("genai-" in r for r in resources), (
        f"project buckets are not in the writable set: {resources}"
    )
