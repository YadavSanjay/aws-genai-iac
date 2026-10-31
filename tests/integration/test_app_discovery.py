"""Post-apply verification for app-tier service discovery (Q4b), LIVE AWS API.

Faultline is the first subsystem here that calls another APP TIER rather
than a shared backend, so XbrlRag and MacroRAG need resolvable in-VPC names. Those
records are registered by the `compute/ec2-app` module itself, in the same state
as the instance, so Terraform rewrites them in the same apply that replaces the
host.

The test that earns its keep is the DRIFT one below: it compares each registered
address against the instance's CURRENT private IP. A stale record does not raise
anything — DNS resolves, the connection is refused or blackholed, and the caller
reports a timeout that looks like an application fault.

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
NAMESPACE = f"{NAME_PREFIX}.internal"

# Every app tier that must be reachable by name, mapped to the EC2 Name tag of
# the instance backing it. Both serve their API on 8000.
REGISTERED_APPS = {
    "arag": f"{NAME_PREFIX}-arag",
    "macrorag": f"{NAME_PREFIX}-macrorag",
}


@pytest.fixture(scope="module")
def sd_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("servicediscovery")


@pytest.fixture(scope="module")
def ec2_client() -> Any:
    return boto3.Session(region_name=REGION).client("ec2")


@pytest.fixture(scope="module")
def namespace_id(sd_client: Any) -> str:
    for page in sd_client.get_paginator("list_namespaces").paginate():
        for ns in page["Namespaces"]:
            if ns["Name"] == NAMESPACE:
                return str(ns["Id"])
    pytest.fail(f"private namespace {NAMESPACE!r} not found — is 00-networking/dns applied?")


@pytest.fixture(scope="module")
def services(sd_client: Any, namespace_id: str) -> dict[str, dict[str, Any]]:
    found = {}
    for page in sd_client.get_paginator("list_services").paginate(
        Filters=[{"Name": "NAMESPACE_ID", "Values": [namespace_id], "Condition": "EQ"}]
    ):
        for svc in page["Services"]:
            found[svc["Name"]] = dict(svc)
    return found


@pytest.fixture(scope="module")
def live_private_ips(ec2_client: Any) -> dict[str, str]:
    """Current private IP of each app instance, keyed by discovery name."""
    ips: dict[str, str] = {}
    for app, name_tag in REGISTERED_APPS.items():
        reservations = ec2_client.describe_instances(
            Filters=[
                {"Name": "tag:Name", "Values": [name_tag]},
                # A replaced host leaves a terminated shell behind for a while;
                # it is not a candidate for the record.
                {"Name": "instance-state-name", "Values": ["pending", "running", "stopped"]},
            ]
        )["Reservations"]
        instances = [i for r in reservations for i in r["Instances"]]
        assert len(instances) == 1, (
            f"expected exactly one live instance tagged {name_tag}, found "
            f"{[i['InstanceId'] for i in instances]}"
        )
        ips[app] = instances[0]["PrivateIpAddress"]
    return ips


def test_every_app_tier_is_registered(services: dict[str, dict[str, Any]]) -> None:
    missing = set(REGISTERED_APPS) - set(services)
    assert not missing, (
        f"no Cloud Map service for {sorted(missing)} in {NAMESPACE}. "
        "Callers cannot resolve them and would need a hardcoded private IP."
    )


def test_records_are_short_ttl_a_records(
    sd_client: Any, services: dict[str, dict[str, Any]]
) -> None:
    """A long TTL outlives the apply that fixes a replaced instance's address."""
    for app in REGISTERED_APPS:
        config = sd_client.get_service(Id=services[app]["Id"])["Service"]["DnsConfig"]
        records = config["DnsRecords"]
        assert [r["Type"] for r in records] == ["A"], f"{app} registers {records}, expected one A"
        assert records[0]["TTL"] <= 60, (
            f"{app} record TTL is {records[0]['TTL']}s; callers would cache a dead "
            "address well past the apply that replaced the instance"
        )


def test_registered_address_matches_the_live_instance(
    sd_client: Any, services: dict[str, dict[str, Any]], live_private_ips: dict[str, str]
) -> None:
    """THE drift check: the record must point at the instance running today.

    Registration lives in the same component as the instance, so Terraform keeps
    these in step by construction. This catches the case that construction
    cannot: something changing the instance outside Terraform. It fails loudly
    because the runtime symptom does not — a stale A record still resolves, and
    the caller just times out as though the remote application were broken.
    """
    for app, expected_ip in live_private_ips.items():
        instances = sd_client.list_instances(ServiceId=services[app]["Id"])["Instances"]
        assert len(instances) == 1, (
            f"{app} has {len(instances)} registered instances, expected exactly one: "
            f"{[i['Id'] for i in instances]}"
        )

        registered_ip = instances[0]["Attributes"].get("AWS_INSTANCE_IPV4")
        assert registered_ip == expected_ip, (
            f"{app}.{NAMESPACE} resolves to {registered_ip}, but the live instance is at "
            f"{expected_ip}. The record is STALE — callers will time out against a dead "
            f"address. Re-apply the {app} app component."
        )


def test_registration_id_is_the_instance_id(
    sd_client: Any, services: dict[str, dict[str, Any]], ec2_client: Any
) -> None:
    """Registering under the EC2 instance id keeps the record self-identifying.

    A replaced host registers under a NEW id, so a leftover registration from a
    previous instance shows up as a second entry rather than silently overwriting
    the first — which is what makes the single-instance assertion above a
    meaningful check rather than a tautology.
    """
    for app, name_tag in REGISTERED_APPS.items():
        registered = sd_client.list_instances(ServiceId=services[app]["Id"])["Instances"][0]["Id"]
        reservations = ec2_client.describe_instances(
            Filters=[
                {"Name": "tag:Name", "Values": [name_tag]},
                {"Name": "instance-state-name", "Values": ["pending", "running", "stopped"]},
            ]
        )["Reservations"]
        live_id = [i["InstanceId"] for r in reservations for i in r["Instances"]][0]
        assert registered == live_id, (
            f"{app} is registered under {registered}, but the live instance is {live_id}"
        )
