"""Post-apply verification for the Faultline start/stop window (Q6), LIVE AWS.

The schedule is created by `compute/ec2-app` itself, in the same state as the
instance, so the target is a reference rather than a copied id. The drift test
below is what proves that held: it compares the schedule's target against the
instance actually tagged genai-dev-qlp today.

Two defects in this estate's scheduling history are guarded here on purpose:

  * scheduled STARTS used to die with Client.InvalidKMSKey because the scheduler
    role could not create a grant on the CMK backing the EBS volumes. This host
    has TWO CMK-encrypted volumes, so it is the most exposed of any tier.
  * a scheduled STOP has been observed silently no-opping on another workload.
    Nothing here can prove a future invocation fires, so the checks below assert
    the preconditions and the state; the morning-after instance state is the
    real proof and stays a human check.

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

WORKLOAD = f"{NAME_PREFIX}-qlp"
INSTANCE_NAME = WORKLOAD
SCHEDULER_ROLE = f"{WORKLOAD}-scheduler"

EXPECTED_START_CRON = "cron(0 11 * * ? *)"
EXPECTED_STOP_CRON = "cron(0 21 * * ? *)"
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
def schedules(session: Any) -> dict[str, dict[str, Any]]:
    client = session.client("scheduler")
    out = {}
    for kind in ("start", "stop"):
        name = f"{WORKLOAD}-{kind}"
        try:
            out[kind] = dict(client.get_schedule(Name=name))
        except client.exceptions.ResourceNotFoundException:
            pytest.fail(f"schedule {name!r} does not exist — is the component applied?")
    return out


@pytest.fixture(scope="module")
def live_instance_id(session: Any) -> str:
    reservations = session.client("ec2").describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [INSTANCE_NAME]},
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running", "stopping", "stopped"],
            },
        ]
    )["Reservations"]
    ids = [i["InstanceId"] for r in reservations for i in r["Instances"]]
    assert len(ids) == 1, f"expected exactly one instance tagged {INSTANCE_NAME}, found {ids}"
    return str(ids[0])


def test_both_schedules_match_the_declared_park_state(
    schedules: dict[str, dict[str, Any]], expected_schedule_state: str
) -> None:
    """Both rules follow dev/env.hcl's park switch, in both directions.

    The switch kills the START as well as the STOP, so a host paused this way
    never comes back on its own — the intent when parked, a defect when not.
    """
    for kind, sched in schedules.items():
        assert sched["State"] == expected_schedule_state, (
            f"{WORKLOAD}-{kind} is {sched['State']} but dev/env.hcl expects "
            f"{expected_schedule_state}"
        )


def test_window_and_timezone(schedules: dict[str, dict[str, Any]]) -> None:
    """The timezone is load-bearing, not cosmetic.

    An IANA name keeps 11:00-21:00 local across daylight saving; a fixed UTC
    offset would silently drift by an hour twice a year and stop the host during
    working time.
    """
    assert schedules["start"]["ScheduleExpression"] == EXPECTED_START_CRON
    assert schedules["stop"]["ScheduleExpression"] == EXPECTED_STOP_CRON
    for kind, sched in schedules.items():
        assert sched["ScheduleExpressionTimezone"] == EXPECTED_TIMEZONE, (
            f"{WORKLOAD}-{kind} runs in {sched['ScheduleExpressionTimezone']}, "
            f"not {EXPECTED_TIMEZONE}"
        )


def test_schedules_target_the_live_instance(
    schedules: dict[str, dict[str, Any]], live_instance_id: str
) -> None:
    """THE drift check, and the reason the schedule lives in the app component.

    A separate `*-schedule` component stores a COPY of the instance id, so
    reprovisioning the host without re-applying it leaves the schedule driving a
    terminated instance — silently, because a scheduler invocation against a dead
    id simply fails in the background. Here the target is a reference, so this
    should hold by construction; the test is what proves it did.
    """
    for kind, sched in schedules.items():
        payload = json.loads(sched["Target"]["Input"])
        targeted = payload["InstanceIds"]
        assert targeted == [live_instance_id], (
            f"{WORKLOAD}-{kind} targets {targeted}, but the live instance is "
            f"{live_instance_id}. The schedule is STALE."
        )


def test_scheduler_role_can_grant_on_the_cmk(session: Any) -> None:
    """Guards the regression that broke scheduled starts across this estate.

    Starting an instance with CMK-encrypted EBS makes EC2 call KMS *as the
    scheduler role*: it must Decrypt/GenerateDataKey and register a per-volume
    grant. Without kms:CreateGrant the instance launches and immediately dies
    with Client.InvalidKMSKey — and because that happens asynchronously, the
    schedule looks like it fired correctly. This host has TWO CMK volumes.
    """
    doc = session.client("iam").get_role_policy(RoleName=SCHEDULER_ROLE, PolicyName="start-stop")[
        "PolicyDocument"
    ]

    actions: set[str] = set()
    for stmt in doc["Statement"]:
        act = stmt["Action"]
        actions.update([act] if isinstance(act, str) else act)

    assert "kms:CreateGrant" in actions, (
        "scheduler role cannot create a KMS grant — scheduled STARTS will fail "
        "asynchronously with Client.InvalidKMSKey while appearing to fire"
    )
    assert {"kms:Decrypt", "kms:GenerateDataKey*"} <= actions, (
        f"scheduler role is missing KMS decrypt/data-key actions: {sorted(actions)}"
    )


def test_scheduler_role_cannot_touch_other_instances(session: Any) -> None:
    """Negative control: start/stop is ARN-scoped, not account-wide.

    A `*` resource here would let this workload's schedule stop any instance in
    the account, including the shared Qdrant the other subsystems depend on.
    """
    doc = session.client("iam").get_role_policy(RoleName=SCHEDULER_ROLE, PolicyName="start-stop")[
        "PolicyDocument"
    ]

    for stmt in doc["Statement"]:
        acts = stmt["Action"]
        acts = [acts] if isinstance(acts, str) else acts
        if not any(a.startswith("ec2:") for a in acts):
            continue
        resources = stmt["Resource"]
        resources = [resources] if isinstance(resources, str) else resources
        assert "*" not in resources, f"ec2 start/stop granted on * : {stmt}"
