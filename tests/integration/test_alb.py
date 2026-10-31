"""Post-apply verification for dev/30-shared-svc/alb against the LIVE AWS API.

These tests adapt to the ingress mode. When the load balancer is disabled they
assert it does NOT exist — "disabled" must mean "not billing", and a surviving
ALB after a flip to ssm is exactly the failure that would go unnoticed until
the bill arrives.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import os
from typing import Any

import boto3
import pytest

from tests.integration.conftest import env_ingress_mode

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")

ALB_NAME = f"{NAME_PREFIX}-alb"
MACRORAG_TG = f"{NAME_PREFIX}-macrorag"

# Read from dev/env.hcl (see conftest.env_ingress_mode), not from an environment
# variable. The previous `os.environ.get("IAC_INGRESS_MODE", "alb")` defaulted to
# the mode the environment is NOT in, so the toggle's headline assertion failed
# on every ordinary run. An env var still overrides, for running against another
# environment.
EXPECTED_MODE = os.environ.get("IAC_INGRESS_MODE") or env_ingress_mode()

EXPECTED_IDLE_TIMEOUT = 120
EXPECTED_LISTENER_PORT = 80  # HTTP: no domain, so no certificate


@pytest.fixture(scope="module")
def elbv2() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("elbv2")


@pytest.fixture(scope="module")
def load_balancer(elbv2: Any) -> dict[str, Any] | None:
    try:
        found = elbv2.describe_load_balancers(Names=[ALB_NAME])["LoadBalancers"]
    except elbv2.exceptions.LoadBalancerNotFoundException:
        return None
    return dict(found[0])


# --- The switch --------------------------------------------------------------


def test_load_balancer_presence_matches_ingress_mode(
    load_balancer: dict[str, Any] | None,
) -> None:
    """The assertion the whole toggle depends on.

    An ALB cannot be stopped, so ingress_mode = "ssm" has to DESTROY it. A load
    balancer that survives the flip keeps billing $16.43/month while everyone
    believes ingress is off — a pure cost leak with no functional symptom.
    """
    if EXPECTED_MODE == "alb":
        assert load_balancer is not None, (
            f"ingress_mode is 'alb' but no load balancer named {ALB_NAME} exists"
        )
    else:
        assert load_balancer is None, (
            f"ingress_mode is '{EXPECTED_MODE}' but {ALB_NAME} still EXISTS and "
            "is billing ~$16.43/month. Apply dev/30-shared-svc/alb to destroy it."
        )


@pytest.fixture(scope="module")
def alb(load_balancer: dict[str, Any] | None) -> dict[str, Any]:
    if load_balancer is None:
        pytest.skip(
            f"ingress_mode is '{EXPECTED_MODE}' — no load balancer exists, so "
            "its configuration cannot be verified. Applications are reached via "
            "SSM port forwarding."
        )
    return load_balancer


# --- Placement and shape -----------------------------------------------------


def test_alb_is_internal_and_active(alb: dict[str, Any]) -> None:
    """Internal, not internet-facing. This is the security property.

    The ALB exists for east-west traffic — subsystems calling each other and
    RagInference. Internal means it resolves to private addresses and is
    unreachable from the internet, which is also what makes the missing TLS
    certificate tolerable: that traffic never leaves the VPC.
    """
    assert alb["Scheme"] == "internal", (
        f"ALB scheme is {alb['Scheme']} — an internet-facing load balancer here "
        "would expose unencrypted HTTP to the internet AND still fail to serve "
        "in-VPC callers, whose source is the NAT's rotating public address."
    )
    assert alb["Type"] == "application"
    assert alb["State"]["Code"] == "active", f"ALB state is {alb['State']}"


def test_alb_spans_two_availability_zones(alb: dict[str, Any]) -> None:
    """AWS rejects a single-AZ ALB, but a misconfigured subnet list can still
    put both nodes in one zone's subnets on a future edit."""
    zones = {az["ZoneName"] for az in alb["AvailabilityZones"]}
    assert len(zones) >= 2, f"ALB spans only {zones}"


def test_alb_drops_invalid_headers(elbv2: Any, alb: dict[str, Any]) -> None:
    """Cheap protection against request-smuggling shapes."""
    attributes = {
        a["Key"]: a["Value"]
        for a in elbv2.describe_load_balancer_attributes(LoadBalancerArn=alb["LoadBalancerArn"])[
            "Attributes"
        ]
    }
    assert attributes.get("routing.http.drop_invalid_header_fields.enabled") == "true"


def test_idle_timeout_tolerates_slow_llm_requests(elbv2: Any, alb: dict[str, Any]) -> None:
    """The 60s default returns 504 while the app is still working.

    On an LLM-backed request that reads as an application bug rather than a load
    balancer timeout, which is a genuinely expensive thing to debug.
    """
    attributes = {
        a["Key"]: a["Value"]
        for a in elbv2.describe_load_balancer_attributes(LoadBalancerArn=alb["LoadBalancerArn"])[
            "Attributes"
        ]
    }
    assert int(attributes["idle_timeout.timeout_seconds"]) == EXPECTED_IDLE_TIMEOUT


def test_deletion_protection_is_off(elbv2: Any, alb: dict[str, Any]) -> None:
    """Protection would defeat the ingress switch.

    With it on, ingress_mode = "ssm" cannot destroy the ALB and the toggle
    silently stops working — the plan fails rather than the charge stopping.
    """
    attributes = {
        a["Key"]: a["Value"]
        for a in elbv2.describe_load_balancer_attributes(LoadBalancerArn=alb["LoadBalancerArn"])[
            "Attributes"
        ]
    }
    assert attributes.get("deletion_protection.enabled") == "false", (
        "deletion protection is ON, so ingress_mode='ssm' cannot destroy this "
        "ALB and the cost switch no longer works"
    )


def test_alb_carries_mandatory_tags(elbv2: Any, alb: dict[str, Any]) -> None:
    tags = {
        t["Key"]: t["Value"]
        for t in elbv2.describe_tags(ResourceArns=[alb["LoadBalancerArn"]])["TagDescriptions"][0][
            "Tags"
        ]
    }
    for required in ("Project", "Environment", "ManagedBy", "Tier"):
        assert required in tags, f"missing tag {required!r}. Present: {sorted(tags)}"


# --- Listener ----------------------------------------------------------------


@pytest.fixture(scope="module")
def listeners(elbv2: Any, alb: dict[str, Any]) -> list[dict[str, Any]]:
    return list(elbv2.describe_listeners(LoadBalancerArn=alb["LoadBalancerArn"])["Listeners"])


def test_listener_matches_certificate_availability(listeners: list[dict[str, Any]]) -> None:
    """HTTP today because there is no domain and so no ACM certificate.

    This asserts the CURRENT, deliberately relaxed state. When a domain is
    registered this test must be updated to expect HTTPS on 443 with a
    certificate — and its failure at that point is the reminder to do so.
    """
    assert len(listeners) == 1, f"expected one listener, found {len(listeners)}"

    listener = listeners[0]
    assert listener["Port"] == EXPECTED_LISTENER_PORT
    assert listener["Protocol"] == "HTTP", (
        "listener is HTTPS — if a certificate now exists, update "
        "EXPECTED_LISTENER_PORT to 443 and assert the TLS policy"
    )
    assert not listener.get("Certificates"), "HTTP listener should carry no certificate"


def test_listener_forwards_to_a_target_group(listeners: list[dict[str, Any]]) -> None:
    actions = listeners[0]["DefaultActions"]
    assert actions, "listener has no default action"
    assert actions[0]["Type"] == "forward", (
        f"default action is {actions[0]['Type']}; expected a forward to the default application"
    )


# --- Target group ------------------------------------------------------------


@pytest.fixture(scope="module")
def target_group(elbv2: Any, load_balancer: dict[str, Any] | None) -> dict[str, Any]:
    # Target groups are destroyed along with the load balancer, so depend on the
    # same signal rather than letting DescribeTargetGroups raise. An unhandled
    # TargetGroupNotFound reads as a broken test suite when it actually means
    # "ingress is off", which is a legitimate state.
    if load_balancer is None:
        pytest.skip(
            f"ingress_mode is '{EXPECTED_MODE}' — target groups are destroyed "
            "with the load balancer. Nothing to verify."
        )

    try:
        groups = elbv2.describe_target_groups(Names=[MACRORAG_TG])["TargetGroups"]
    except elbv2.exceptions.TargetGroupNotFoundException:
        pytest.fail(
            f"load balancer exists but target group {MACRORAG_TG} does not — "
            "the ALB has no backend at all"
        )
    return dict(groups[0])


def test_target_group_health_check_is_sane(target_group: dict[str, Any]) -> None:
    assert target_group["HealthCheckEnabled"] is True
    assert target_group["HealthCheckProtocol"] == "HTTP"
    assert target_group["UnhealthyThresholdCount"] == 3, (
        "two failures is twitchy on a host whose container may be restarting; "
        "five delays noticing a dead application"
    )


def test_macrorag_instance_is_registered(elbv2: Any, target_group: dict[str, Any]) -> None:
    """Registration, not health.

    The instance is deliberately stopped and no application is deployed, so the
    target WILL be unhealthy. What matters is that it is registered — an empty
    target group means the ALB has nowhere to send traffic at all.
    """
    health = elbv2.describe_target_health(TargetGroupArn=target_group["TargetGroupArn"])[
        "TargetHealthDescriptions"
    ]
    assert health, (
        "target group is empty — the ALB has no backend. Expected the MacroRAG "
        "instance to be registered even while stopped."
    )
    assert all(t["Target"]["Id"].startswith("i-") for t in health)


def test_targets_are_expected_to_be_unhealthy_for_now(
    elbv2: Any, target_group: dict[str, Any]
) -> None:
    """Documents the current state rather than asserting a wrong thing.

    Nothing is deployed and the instance is stopped, so 'healthy' would actually
    be surprising. This test exists so the state is recorded and reviewed rather
    than silently assumed — flip the assertion once the app is running.
    """
    health = elbv2.describe_target_health(TargetGroupArn=target_group["TargetGroupArn"])[
        "TargetHealthDescriptions"
    ]
    states = {t["TargetHealth"]["State"] for t in health}

    assert states, "no target health reported"
    if states == {"healthy"}:
        pytest.skip(
            "Targets are HEALTHY — an application is evidently running. Update "
            "this test to assert health rather than tolerate its absence."
        )
