"""Post-apply verification for the RagInference service's capacity state.

This service is the largest single line item in the dev estate — an 8 vCPU
Fargate task at roughly $0.316/hr, about two thirds of the environment's whole
daily burn. It is also the tier whose "off" state is easiest to get wrong,
because three different things can set DesiredCount and the losing one fails
silently:

  * the ECS service's own ``desired_count``, which Terraform ignores after
    creation (``ignore_changes``) so Auto Scaling can own it;
  * the Application Auto Scaling target's min/max bounds;
  * the scheduled scale up/down actions.

Leave a scale-UP action in place while the environment is parked and the task
comes back every morning and bills for a full day nobody asked for. Nothing
surfaces that: the service is healthy, the schedule reports success, and the
only symptom is the credit balance.

These assertions read the park switch from infra/environments/dev/env.hcl and
check AWS against it in BOTH directions, so waking the environment without
restoring the up action fails just as loudly as parking it with one left behind.

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

SERVICE = f"{NAME_PREFIX}-raginference"
CLUSTER = f"{NAME_PREFIX}-raginference"
RESOURCE_ID = f"service/{CLUSTER}/{SERVICE}"

UP_ACTION = f"{SERVICE}-up"
DOWN_ACTION = f"{SERVICE}-down"

EXPECTED_TIMEZONE = "America/New_York"


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
def scalable_target(session: Any) -> dict[str, Any]:
    targets = session.client("application-autoscaling").describe_scalable_targets(
        ServiceNamespace="ecs",
        ResourceIds=[RESOURCE_ID],
        ScalableDimension="ecs:service:DesiredCount",
    )["ScalableTargets"]
    if not targets:
        pytest.fail(
            f"no scalable target registered for {RESOURCE_ID} — is 30-shared-svc/"
            "raginference applied with enable_autoscaling = true?"
        )
    return dict(targets[0])


@pytest.fixture(scope="module")
def scheduled_actions(session: Any) -> dict[str, dict[str, Any]]:
    actions = session.client("application-autoscaling").describe_scheduled_actions(
        ServiceNamespace="ecs",
        ResourceId=RESOURCE_ID,
    )["ScheduledActions"]
    return {a["ScheduledActionName"]: dict(a) for a in actions}


def test_scalable_target_bounds_match_the_declared_park_state(
    scalable_target: dict[str, Any], parked: bool
) -> None:
    """The target's max is what actually holds the task down.

    Auto Scaling enforces the bounds continuously, so a max of 0 scales in a task
    that is already running rather than waiting for the evening scale-down. That
    makes the bound — not the schedule — the thing to assert on.
    """
    expected_max = 0 if parked else 1
    assert scalable_target["MinCapacity"] == 0, (
        f"min capacity is {scalable_target['MinCapacity']}, not 0 — scale-to-zero "
        "is impossible and the task bills around the clock"
    )
    assert scalable_target["MaxCapacity"] == expected_max, (
        f"max capacity is {scalable_target['MaxCapacity']} but dev/env.hcl expects "
        f"{expected_max} — config and AWS have drifted apart"
    )


def test_scale_up_action_is_absent_exactly_when_parked(
    scheduled_actions: dict[str, dict[str, Any]], parked: bool
) -> None:
    up = scheduled_actions.get(UP_ACTION)
    if parked:
        assert up is None, (
            f"{UP_ACTION} still exists while dev/env.hcl declares the environment "
            "parked — the task returns tomorrow morning and bills for the day"
        )
    else:
        assert up is not None, (
            f"{UP_ACTION} is missing while dev/env.hcl declares the environment "
            "live — nothing brings the service up in the morning"
        )
        assert up["ScalableTargetAction"]["MaxCapacity"] >= 1
        assert up["Timezone"] == EXPECTED_TIMEZONE


def test_scale_down_action_survives_parking(
    scheduled_actions: dict[str, dict[str, Any]],
) -> None:
    """The down action is kept in BOTH modes, deliberately.

    Parked it costs nothing and re-asserts zero if anyone sets DesiredCount by
    hand; live it is the nightly shutdown. Removing it as "unused while parked"
    would drop the backstop precisely when nobody is watching the environment.
    """
    down = scheduled_actions.get(DOWN_ACTION)
    assert down is not None, f"{DOWN_ACTION} is missing — nothing re-asserts zero"
    assert down["ScalableTargetAction"]["MaxCapacity"] == 0, (
        f"{DOWN_ACTION} scales down to {down['ScalableTargetAction']['MaxCapacity']}, not 0"
    )
    assert down["Timezone"] == EXPECTED_TIMEZONE


def test_no_task_is_running_while_parked(session: Any, parked: bool) -> None:
    """The end state the whole park exists to produce.

    Asserted against the running count rather than the configuration, because
    every check above can pass while a task started before the park is still up —
    and a forgotten 8 vCPU task is the most expensive way for this to go wrong.
    """
    if not parked:
        pytest.skip("environment is not parked; capacity is driven by the window")

    services = session.client("ecs").describe_services(cluster=CLUSTER, services=[SERVICE])[
        "services"
    ]
    assert services, f"service {SERVICE} not found in cluster {CLUSTER}"

    svc = services[0]
    assert svc["runningCount"] == 0 and svc["desiredCount"] == 0, (
        f"{SERVICE} has desired={svc['desiredCount']} running={svc['runningCount']} "
        "while the environment is parked — an 8 vCPU Fargate task is still billing"
    )
