"""Post-apply verification for dev/42-arag/app-schedule (A8).

Mirrors test_nat_schedule.py. Both failure modes it guards for are SILENT — the
schedule fires on time, reports success, and the host stays down:

  * a stale target — the XbrlRag app tier is REPLACED by any user-data change, and a
    schedule left pointing at the terminated instance never starts anything;
  * a boundary-capped role — every role Terraform creates carries the app
    permissions boundary, and a capped role's StartInstances call is denied after
    the schedule has already reported success.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import json
import os
from typing import Any

import boto3
import pytest
from botocore.exceptions import ClientError

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")

START_SCHEDULE = f"{NAME_PREFIX}-arag-start"
STOP_SCHEDULE = f"{NAME_PREFIX}-arag-stop"
ARAG_NAME = f"{NAME_PREFIX}-arag"

EXPECTED_TIMEZONE = "America/New_York"
EXPECTED_START_CRON = "cron(0 11 * * ? *)"
EXPECTED_STOP_CRON = "cron(0 21 * * ? *)"

# The NAT window (10:00-22:00) must bracket this one, or a scheduled start has no
# egress for its boot (secret fetch + ECR auth) and a scheduled stop happens after
# the NAT is already gone.
NAT_START_HOUR, NAT_STOP_HOUR = 10, 22


@pytest.fixture(scope="module")
def scheduler_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("scheduler")


def _schedule(client: Any, name: str) -> dict[str, Any]:
    try:
        return dict(client.get_schedule(Name=name, GroupName="default"))
    except ClientError as exc:
        pytest.fail(f"schedule {name!r} not readable — is the component applied? {exc}")


@pytest.fixture(scope="module")
def start_schedule(scheduler_client: Any) -> dict[str, Any]:
    return _schedule(scheduler_client, START_SCHEDULE)


@pytest.fixture(scope="module")
def stop_schedule(scheduler_client: Any) -> dict[str, Any]:
    return _schedule(scheduler_client, STOP_SCHEDULE)


@pytest.fixture(scope="module")
def arag_instance_ids() -> set[str]:
    """Non-terminated XbrlRag hosts. Terminated ones are excluded deliberately: a
    schedule still targeting a replaced instance is the bug under test."""
    ec2 = boto3.Session(region_name=REGION).client("ec2")
    reservations = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [ARAG_NAME]},
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running", "stopping", "stopped"],
            },
        ]
    )["Reservations"]
    ids = {i["InstanceId"] for r in reservations for i in r["Instances"]}
    assert ids, f"no live instance tagged Name={ARAG_NAME} — is 42-arag/app applied?"
    return ids


# --- Window ------------------------------------------------------------------


def test_schedules_match_the_declared_park_state(
    start_schedule: dict[str, Any],
    stop_schedule: dict[str, Any],
    expected_schedule_state: str,
) -> None:
    """Both rules follow dev/env.hcl's park switch, in both directions.

    Note the switch disables BOTH rules, so a one-off shutdown left in place also
    cancels every future start — which is the intent when parked, and a defect
    when not.
    """
    for schedule in (start_schedule, stop_schedule):
        assert schedule["State"] == expected_schedule_state, (
            f"{schedule['Name']} is {schedule['State']} but dev/env.hcl expects "
            f"{expected_schedule_state} — config and AWS have drifted apart"
        )


def test_window_matches_the_shared_service_hours(
    start_schedule: dict[str, Any], stop_schedule: dict[str, Any]
) -> None:
    """XbrlRag is useless outside the Qdrant + RagInference window (11:00-21:00): it
    reads narrative vectors from one and offloads embed/rerank to the other."""
    assert start_schedule["ScheduleExpression"] == EXPECTED_START_CRON
    assert stop_schedule["ScheduleExpression"] == EXPECTED_STOP_CRON


def test_window_sits_inside_the_nat_window(
    start_schedule: dict[str, Any], stop_schedule: dict[str, Any]
) -> None:
    """A start outside the NAT window boots a host with no egress: the secret
    fetch and ECR login in app-deploy.sh fail and the containers never come up."""
    start_hour = int(start_schedule["ScheduleExpression"].split()[1])
    stop_hour = int(stop_schedule["ScheduleExpression"].split()[1])

    assert start_hour >= NAT_START_HOUR, (
        f"start {start_hour}:00 precedes the NAT start {NAT_START_HOUR}:00 — no egress at boot"
    )
    assert stop_hour <= NAT_STOP_HOUR, (
        f"stop {stop_hour}:00 is after the NAT stop {NAT_STOP_HOUR}:00"
    )


def test_timezone_is_a_named_zone_not_an_offset(
    start_schedule: dict[str, Any], stop_schedule: dict[str, Any]
) -> None:
    """A fixed offset drifts an hour at each DST boundary."""
    for schedule in (start_schedule, stop_schedule):
        tz = schedule.get("ScheduleExpressionTimezone")
        assert tz == EXPECTED_TIMEZONE, f"{schedule['Name']} uses timezone {tz!r}"
        assert "/" in tz, f"{tz!r} is not an IANA zone name; a fixed offset does not track DST"


# --- Targeting: the silent-orphan failure ------------------------------------


def test_schedules_target_the_current_arag_instance(
    start_schedule: dict[str, Any],
    stop_schedule: dict[str, Any],
    arag_instance_ids: set[str],
) -> None:
    """The app tier is replaced by any user-data change. If this component is not
    re-applied afterwards the schedule keeps a terminated instance id, fires on
    time, reports success, and the host never starts."""
    for schedule in (start_schedule, stop_schedule):
        payload = json.loads(schedule["Target"]["Input"])
        targeted = set(payload["InstanceIds"])
        assert targeted <= arag_instance_ids, (
            f"{schedule['Name']} targets {targeted}, which is not a live XbrlRag "
            f"instance ({arag_instance_ids}). Re-apply 42-arag/app-schedule."
        )


def test_schedules_use_the_direct_ec2_api_not_a_lambda(
    start_schedule: dict[str, Any], stop_schedule: dict[str, Any]
) -> None:
    assert start_schedule["Target"]["Arn"].endswith(":ec2:startInstances")
    assert stop_schedule["Target"]["Arn"].endswith(":ec2:stopInstances")


# --- The role: where the other silent failure lives --------------------------


def test_scheduler_role_can_actually_start_and_stop_the_instance(
    start_schedule: dict[str, Any], arag_instance_ids: set[str]
) -> None:
    """Simulating against the real role and the real boundary is the only way to
    know the schedule will work without waiting for 11:00."""
    role_arn = start_schedule["Target"]["RoleArn"]
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    instance_arn = f"arn:aws:ec2:{REGION}:{account}:instance/{sorted(arag_instance_ids)[0]}"

    iam = boto3.Session(region_name=REGION).client("iam")
    try:
        results = iam.simulate_principal_policy(
            PolicySourceArn=role_arn,
            ActionNames=["ec2:StartInstances", "ec2:StopInstances"],
            ResourceArns=[instance_arn],
            ContextEntries=[
                {
                    "ContextKeyName": "aws:ResourceTag/Project",
                    "ContextKeyValues": ["aws-genai-iac"],
                    "ContextKeyType": "string",
                }
            ],
        )["EvaluationResults"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise

    for result in results:
        assert result["EvalDecision"] == "allowed", (
            f"scheduler role cannot {result['EvalActionName']} "
            f"(decision: {result['EvalDecision']}). The schedule will fire, report "
            "success and change nothing — check the app permissions boundary, "
            "which caps every role Terraform creates."
        )


def test_scheduler_role_cannot_terminate_instances(
    start_schedule: dict[str, Any], arag_instance_ids: set[str]
) -> None:
    """Negative control: stopping is recoverable, terminating is not — and this
    tier's root volume is its only copy of the rendered secrets."""
    role_arn = start_schedule["Target"]["RoleArn"]
    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    instance_arn = f"arn:aws:ec2:{REGION}:{account}:instance/{sorted(arag_instance_ids)[0]}"

    iam = boto3.Session(region_name=REGION).client("iam")
    try:
        results = iam.simulate_principal_policy(
            PolicySourceArn=role_arn,
            ActionNames=["ec2:TerminateInstances"],
            ResourceArns=[instance_arn],
        )["EvaluationResults"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise

    for result in results:
        assert result["EvalDecision"] != "allowed", (
            "scheduler role can TERMINATE the XbrlRag host — it should only start/stop"
        )
