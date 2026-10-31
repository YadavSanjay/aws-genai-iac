"""Post-apply verification for dev/00-networking/nat-schedule.

The failure mode this guards against is silent: a schedule with a capped role
fires on time, reports success, changes nothing, and only shows up on the bill.

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

STOP_SCHEDULE = f"{NAME_PREFIX}-instance-stop"
START_SCHEDULE = f"{NAME_PREFIX}-instance-start"
NAT_NAME = f"{NAME_PREFIX}-nat"

EXPECTED_TIMEZONE = "America/New_York"
EXPECTED_START_CRON = "cron(0 10 * * ? *)"
EXPECTED_STOP_CRON = "cron(0 22 * * ? *)"


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
def stop_schedule(scheduler_client: Any) -> dict[str, Any]:
    return _schedule(scheduler_client, STOP_SCHEDULE)


@pytest.fixture(scope="module")
def start_schedule(scheduler_client: Any) -> dict[str, Any]:
    return _schedule(scheduler_client, START_SCHEDULE)


# --- Window ------------------------------------------------------------------


def test_schedules_match_the_declared_park_state(
    stop_schedule: dict[str, Any],
    start_schedule: dict[str, Any],
    expected_schedule_state: str,
) -> None:
    """Both rules follow dev/env.hcl's park switch, in both directions.

    Parked, an ENABLED start would bring the NAT back and bill for it. Unparked,
    a DISABLED pair means the instance silently never follows its window.
    """
    for schedule in (stop_schedule, start_schedule):
        assert schedule["State"] == expected_schedule_state, (
            f"{schedule['Name']} is {schedule['State']} but dev/env.hcl expects "
            f"{expected_schedule_state} — config and AWS have drifted apart"
        )


def test_window_matches_the_agreed_hours(
    stop_schedule: dict[str, Any], start_schedule: dict[str, Any]
) -> None:
    assert start_schedule["ScheduleExpression"] == EXPECTED_START_CRON
    assert stop_schedule["ScheduleExpression"] == EXPECTED_STOP_CRON


def test_timezone_is_a_named_zone_not_an_offset(
    stop_schedule: dict[str, Any], start_schedule: dict[str, Any]
) -> None:
    """A fixed offset drifts an hour at each DST boundary.

    The symptom would be "the environment goes down early in November", which is
    a miserable thing to trace back to a schedule.
    """
    for schedule in (stop_schedule, start_schedule):
        tz = schedule.get("ScheduleExpressionTimezone")
        assert tz == EXPECTED_TIMEZONE, f"{schedule['Name']} uses timezone {tz!r}"
        assert "/" in tz, f"{tz!r} is not an IANA zone name; a fixed offset does not track DST"


def test_stop_does_not_drift(stop_schedule: dict[str, Any]) -> None:
    """A flexible window blurs the boundary being billed against."""
    assert stop_schedule["FlexibleTimeWindow"]["Mode"] == "OFF"


def test_start_retries_harder_than_stop(
    stop_schedule: dict[str, Any], start_schedule: dict[str, Any]
) -> None:
    """Asymmetric on purpose.

    A missed stop costs a few hours of compute and the next day catches it. A
    missed start means no egress for the whole working day.
    """
    stop_retry = stop_schedule["Target"]["RetryPolicy"]
    start_retry = start_schedule["Target"]["RetryPolicy"]

    assert start_retry["MaximumRetryAttempts"] > stop_retry["MaximumRetryAttempts"], (
        "start should retry harder than stop — a missed start costs a working day"
    )
    assert start_retry["MaximumEventAgeInSeconds"] > stop_retry["MaximumEventAgeInSeconds"]


# --- Targeting ---------------------------------------------------------------


def test_schedules_target_the_nat_instance(
    stop_schedule: dict[str, Any], start_schedule: dict[str, Any]
) -> None:
    ec2 = boto3.Session(region_name=REGION).client("ec2")
    reservations = ec2.describe_instances(Filters=[{"Name": "tag:Name", "Values": [NAT_NAME]}])[
        "Reservations"
    ]
    instance_ids = {i["InstanceId"] for r in reservations for i in r["Instances"]}
    assert instance_ids, f"no instance tagged Name={NAT_NAME}"

    for schedule in (stop_schedule, start_schedule):
        payload = json.loads(schedule["Target"]["Input"])
        targeted = set(payload["InstanceIds"])
        assert targeted <= instance_ids, (
            f"{schedule['Name']} targets {targeted}, which is not the NAT instance"
        )


def test_schedules_use_the_direct_ec2_api_not_a_lambda(
    stop_schedule: dict[str, Any], start_schedule: dict[str, Any]
) -> None:
    """Universal target means no function to write, patch or pay for."""
    assert stop_schedule["Target"]["Arn"].endswith(":ec2:stopInstances")
    assert start_schedule["Target"]["Arn"].endswith(":ec2:startInstances")


# --- The role: where the silent failure lives --------------------------------


def test_scheduler_role_can_actually_stop_the_instance(
    stop_schedule: dict[str, Any],
) -> None:
    """The check that catches a boundary-capped role.

    A schedule whose role is capped fires on time, reports success and changes
    nothing. Simulating the action against the real role and the real boundary
    is the only way to know it will work without waiting for 22:00.
    """
    role_arn = stop_schedule["Target"]["RoleArn"]
    ec2 = boto3.Session(region_name=REGION).client("ec2")
    reservations = ec2.describe_instances(Filters=[{"Name": "tag:Name", "Values": [NAT_NAME]}])[
        "Reservations"
    ]
    instance = [i for r in reservations for i in r["Instances"]][0]

    account = boto3.Session(region_name=REGION).client("sts").get_caller_identity()["Account"]
    instance_arn = f"arn:aws:ec2:{REGION}:{account}:instance/{instance['InstanceId']}"

    iam = boto3.Session(region_name=REGION).client("iam")
    try:
        results = iam.simulate_principal_policy(
            PolicySourceArn=role_arn,
            ActionNames=["ec2:StopInstances", "ec2:StartInstances"],
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
            f"(decision: {result['EvalDecision']}). The schedule will fire, "
            "report success and change nothing — check the app permissions "
            "boundary, which caps every role Terraform creates."
        )


def test_scheduler_role_cannot_terminate_instances(
    stop_schedule: dict[str, Any],
) -> None:
    """Negative control: stopping is recoverable, terminating is not."""
    role_arn = stop_schedule["Target"]["RoleArn"]
    iam = boto3.Session(region_name=REGION).client("iam")

    try:
        results = iam.simulate_principal_policy(
            PolicySourceArn=role_arn,
            ActionNames=["ec2:TerminateInstances", "ec2:RebootInstances"],
        )["EvaluationResults"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise

    for result in results:
        assert result["EvalDecision"] != "allowed", (
            f"scheduler role may {result['EvalActionName']} — it should only start and stop"
        )


# --- Encrypted-EBS start: the KMS half of the silent failure -----------------
#
# The instance's root/data volumes are a CMK. On start, EC2 must use that key IN
# THE SCHEDULER ROLE'S CONTEXT, capped by the app permissions boundary. Missing
# any of these, the instance launches then AWS stops it with
# `Client.InvalidKMSKey` — the schedule "fires" and nothing stays up. simulate
# evaluates inline policy AND the boundary, so this catches either half regressing.

# ReEncrypt*/GenerateDataKey* expand to the concrete verbs EC2 actually calls.
KMS_VOLUME_CRYPTO_ACTIONS = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
]


def _cmk_arn(schedule: dict[str, Any]) -> str:
    arn = schedule.get("KmsKeyArn")
    if not arn:
        pytest.fail(
            "schedule has no KmsKeyArn — the target input is unencrypted, or the "
            "component is not applied"
        )
    return str(arn)


def test_scheduler_role_can_decrypt_encrypted_volumes_on_start(
    start_schedule: dict[str, Any],
) -> None:
    """The crypto verbs EC2 needs to bring up a CMK-encrypted instance."""
    role_arn = start_schedule["Target"]["RoleArn"]
    cmk_arn = _cmk_arn(start_schedule)
    iam = boto3.Session(region_name=REGION).client("iam")

    try:
        results = iam.simulate_principal_policy(
            PolicySourceArn=role_arn,
            ActionNames=KMS_VOLUME_CRYPTO_ACTIONS,
            ResourceArns=[cmk_arn],
        )["EvaluationResults"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise

    for result in results:
        assert result["EvalDecision"] == "allowed", (
            f"scheduler role cannot {result['EvalActionName']} on the CMK "
            f"(decision: {result['EvalDecision']}). A scheduled start will launch "
            "the instance and AWS will stop it with Client.InvalidKMSKey. Check the "
            "app permissions boundary AND the scheduler role's inline KMS policy."
        )


def test_scheduler_role_can_create_the_ebs_volume_grant(
    start_schedule: dict[str, Any],
) -> None:
    """CreateGrant is how EC2 registers the per-volume grant at start.

    Gated on kms:GrantIsForAWSResource so it cannot delegate the key to an
    arbitrary principal — assert it is allowed WITH the AWS-resource context.
    """
    role_arn = start_schedule["Target"]["RoleArn"]
    cmk_arn = _cmk_arn(start_schedule)
    iam = boto3.Session(region_name=REGION).client("iam")

    try:
        results = iam.simulate_principal_policy(
            PolicySourceArn=role_arn,
            ActionNames=["kms:CreateGrant"],
            ResourceArns=[cmk_arn],
            ContextEntries=[
                {
                    "ContextKeyName": "kms:GrantIsForAWSResource",
                    "ContextKeyValues": ["true"],
                    "ContextKeyType": "boolean",
                }
            ],
        )["EvaluationResults"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise

    for result in results:
        assert result["EvalDecision"] == "allowed", (
            "scheduler role cannot kms:CreateGrant on the CMK for an AWS resource "
            f"(decision: {result['EvalDecision']}). Encrypted-EBS starts will fail "
            "with Client.InvalidKMSKey."
        )
