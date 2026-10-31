"""Post-apply verification for the XbrlRag database schedule (dev/42-arag/db).

The RDS instance was the last always-on line item in the dev estate. Its
schedule lives INSIDE 42-arag/db rather than in a sibling component, so the
target is a reference and cannot go stale — but three failure modes remain, and
all three are silent (the schedule fires, reports success, and the database
keeps running or stays down):

  * a boundary-capped role — every role Terraform creates carries the app
    permissions boundary, and the boundary allowed only ec2:Start/StopInstances
    until this change. A capped role's StopDBInstance is denied AFTER the
    schedule has reported success;
  * a target input the RDS API does not accept (the universal target takes
    ``DbInstanceIdentifier``, not the EC2 target's ``InstanceIds``);
  * a window that collides with the app tier's — the database must be available
    BEFORE the XbrlRag host boots and must outlive it on the way down, or the first
    queries of the day hit a database that is still starting.

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

DB_ID = os.environ.get("IAC_ARAG_DB_ID", f"{NAME_PREFIX}-arag")

DB_START_SCHEDULE = f"{NAME_PREFIX}-arag-db-start"
DB_STOP_SCHEDULE = f"{NAME_PREFIX}-arag-db-stop"

# The app tier's own schedule (42-arag/app-schedule), read live rather than
# hard-coded: the point of the bracketing test is that the two agree in AWS, not
# that they agree in this file.
APP_START_SCHEDULE = f"{NAME_PREFIX}-arag-start"
APP_STOP_SCHEDULE = f"{NAME_PREFIX}-arag-stop"

EXPECTED_TIMEZONE = "America/New_York"

# How far the database window must extend past the app window on each side. RDS
# takes several minutes to reach `available` from stopped.
MIN_LEAD_MINUTES = 5


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
def scheduler_client(session: Any) -> Any:
    return session.client("scheduler")


def _schedule(client: Any, name: str) -> dict[str, Any]:
    try:
        return dict(client.get_schedule(Name=name, GroupName="default"))
    except ClientError as exc:
        pytest.fail(f"schedule {name!r} not readable — is the component applied? {exc}")


def _schedule_or_none(client: Any, name: str) -> dict[str, Any] | None:
    try:
        return dict(client.get_schedule(Name=name, GroupName="default"))
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ResourceNotFoundException":
            return None
        raise


@pytest.fixture(scope="module")
def start_schedule(scheduler_client: Any, parked: bool) -> dict[str, Any]:
    if parked:
        pytest.skip(
            "environment parked: the start schedule is deliberately absent. Its "
            "absence is asserted positively by "
            "test_park_state_keeps_the_stop_and_drops_the_start."
        )
    return _schedule(scheduler_client, DB_START_SCHEDULE)


@pytest.fixture(scope="module")
def stop_schedule(scheduler_client: Any) -> dict[str, Any]:
    return _schedule(scheduler_client, DB_STOP_SCHEDULE)


@pytest.fixture(scope="module")
def db_schedules(scheduler_client: Any, parked: bool) -> list[dict[str, Any]]:
    """Every schedule this component should have in the declared mode.

    Parked that is the stop alone; live it is both. Properties that must hold of
    any schedule here — timezone, target shape, encryption — iterate this rather
    than naming the start, so they keep asserting in park mode instead of
    skipping wholesale.
    """
    names = [DB_STOP_SCHEDULE] if parked else [DB_START_SCHEDULE, DB_STOP_SCHEDULE]
    return [_schedule(scheduler_client, name) for name in names]


@pytest.fixture(scope="module")
def db_arn(session: Any) -> str:
    """ARN of the live instance. Deliberately not constructed from the name — a
    schedule targeting an identifier that no longer exists is a failure mode."""
    rds = session.client("rds")
    try:
        resp = rds.describe_db_instances(DBInstanceIdentifier=DB_ID)
    except ClientError as exc:
        pytest.fail(f"database {DB_ID!r} not readable — is 42-arag/db applied? {exc}")
    return str(resp["DBInstances"][0]["DBInstanceArn"])


def _minutes_of_day(schedule: dict[str, Any]) -> int:
    """cron(50 10 * * ? *) -> 650. Scheduler crons are 6-field, minute first."""
    fields = schedule["ScheduleExpression"].removeprefix("cron(").removesuffix(")").split()
    return int(fields[1]) * 60 + int(fields[0])


def _simulate(session: Any, role_arn: str, actions: list[str], resource_arn: str) -> list[dict]:
    iam = session.client("iam")
    try:
        return list(
            iam.simulate_principal_policy(
                PolicySourceArn=role_arn,
                ActionNames=actions,
                ResourceArns=[resource_arn],
            )["EvaluationResults"]
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"):
            pytest.skip("iam:SimulatePrincipalPolicy not available. UNVERIFIED, not passing.")
        raise


# --- The window --------------------------------------------------------------


def test_park_state_keeps_the_stop_and_drops_the_start(
    scheduler_client: Any, stop_schedule: dict[str, Any], parked: bool
) -> None:
    """RDS parks differently from every EC2 tier, and getting it wrong is silent.

    An EC2 instance that is stopped stays stopped, so parking it means DISABLING
    both rules. RDS does not: AWS force-starts a stopped instance after seven
    days. So the parked shape here is the opposite one — the STOP stays ENABLED
    and the START is removed entirely. Disable both and the database returns on
    day 8 and bills 24x7 with no rule left to put it down.

    This asserts the shape in both directions, so neither parking the database
    the EC2 way nor waking it without restoring the start goes unnoticed.
    """
    assert stop_schedule["State"] == "ENABLED", (
        f"{stop_schedule['Name']} is {stop_schedule['State']}. The stop rule must "
        "stay enabled in BOTH modes: parked it is the only thing undoing RDS's "
        "seven-day force-start, and unparked it is the nightly shutdown."
    )

    start = _schedule_or_none(scheduler_client, DB_START_SCHEDULE)
    if parked:
        assert start is None, (
            f"{DB_START_SCHEDULE} still exists while dev/env.hcl declares the "
            "environment parked — the database will be started every morning."
        )
    else:
        assert start is not None, (
            f"{DB_START_SCHEDULE} is missing while dev/env.hcl declares the "
            "environment live — the app tier would boot against a stopped database."
        )
        assert start["State"] == "ENABLED", f"{DB_START_SCHEDULE} is {start['State']}"


def test_timezone_is_a_named_zone_not_an_offset(
    db_schedules: list[dict[str, Any]],
) -> None:
    """A fixed offset drifts an hour at each DST boundary."""
    for schedule in db_schedules:
        tz = schedule.get("ScheduleExpressionTimezone")
        assert tz == EXPECTED_TIMEZONE, f"{schedule['Name']} uses timezone {tz!r}"
        assert "/" in tz, f"{tz!r} is not an IANA zone name; a fixed offset does not track DST"


def test_database_window_brackets_the_app_window(
    scheduler_client: Any, start_schedule: dict[str, Any], stop_schedule: dict[str, Any]
) -> None:
    """The database must be available before the app host boots and must not go
    down while it is still up. Both schedules are read live, so this fails if
    EITHER window is moved without the other."""
    app_start = _schedule(scheduler_client, APP_START_SCHEDULE)
    app_stop = _schedule(scheduler_client, APP_STOP_SCHEDULE)

    db_start_m, db_stop_m = _minutes_of_day(start_schedule), _minutes_of_day(stop_schedule)
    app_start_m, app_stop_m = _minutes_of_day(app_start), _minutes_of_day(app_stop)

    assert db_start_m <= app_start_m - MIN_LEAD_MINUTES, (
        f"database starts at minute {db_start_m}, only {app_start_m - db_start_m} min "
        f"before the app host — RDS needs several minutes to reach `available`, so the "
        "app tier's first queries would hit a starting database."
    )
    assert db_stop_m >= app_stop_m + MIN_LEAD_MINUTES, (
        f"database stops at minute {db_stop_m}, {app_stop_m - db_stop_m} min relative to "
        "the app host's stop — the database must outlive the tier that queries it."
    )


def test_schedules_use_the_direct_rds_api_not_a_lambda(
    scheduler_client: Any, stop_schedule: dict[str, Any], parked: bool
) -> None:
    assert stop_schedule["Target"]["Arn"].endswith(":rds:stopDBInstance")
    if not parked:
        start = _schedule(scheduler_client, DB_START_SCHEDULE)
        assert start["Target"]["Arn"].endswith(":rds:startDBInstance")


def test_target_input_names_the_live_database(
    db_schedules: list[dict[str, Any]],
) -> None:
    """The universal target takes DbInstanceIdentifier — the EC2 schedules'
    InstanceIds shape would be accepted by Scheduler and rejected by RDS at
    invocation, which shows up as a database that simply never stops."""
    for schedule in db_schedules:
        payload = json.loads(schedule["Target"]["Input"])
        assert set(payload) == {"DbInstanceIdentifier"}, (
            f"{schedule['Name']} input keys are {sorted(payload)}; the RDS universal "
            "target accepts DbInstanceIdentifier only"
        )
        assert payload["DbInstanceIdentifier"] == DB_ID


def test_target_input_is_encrypted_with_the_project_cmk(
    session: Any, db_schedules: list[dict[str, Any]]
) -> None:
    cmk = session.client("kms").describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")
    expected = cmk["KeyMetadata"]["Arn"]
    for schedule in db_schedules:
        assert schedule.get("KmsKeyArn") == expected, (
            f"{schedule['Name']} target input is not encrypted with the project CMK"
        )


# --- The role: where the silent failure lives --------------------------------


def test_scheduler_role_can_actually_start_and_stop_the_database(
    session: Any, start_schedule: dict[str, Any], db_arn: str
) -> None:
    """Simulating against the real role AND the real boundary is the only way to
    know the schedule works without waiting for 21:10. The boundary allowed only
    ec2:Start/StopInstances before this change, which would cap this role to
    nothing while every other assertion here still passed."""
    role_arn = start_schedule["Target"]["RoleArn"]
    results = _simulate(session, role_arn, ["rds:StartDBInstance", "rds:StopDBInstance"], db_arn)

    for result in results:
        assert result["EvalDecision"] == "allowed", (
            f"scheduler role cannot {result['EvalActionName']} "
            f"(decision: {result['EvalDecision']}). The schedule will fire, report "
            "success and change nothing — check RuntimeDatabaseScheduling in the app "
            "permissions boundary, which caps every role Terraform creates."
        )


def test_scheduler_role_cannot_destroy_or_reconfigure_the_database(
    session: Any, start_schedule: dict[str, Any], db_arn: str
) -> None:
    """Negative control. Stopping is recoverable; deleting is not, and modifying
    could relax the encryption/public-access/backup posture the module sets."""
    role_arn = start_schedule["Target"]["RoleArn"]
    results = _simulate(
        session,
        role_arn,
        ["rds:DeleteDBInstance", "rds:ModifyDBInstance", "rds:RebootDBInstance"],
        db_arn,
    )

    for result in results:
        assert result["EvalDecision"] != "allowed", (
            f"scheduler role can {result['EvalActionName']} on {DB_ID} — it should "
            "only start and stop"
        )


def test_scheduler_role_cannot_touch_databases_outside_this_component(
    session: Any, start_schedule: dict[str, Any]
) -> None:
    """Negative control on scoping: the role's policy names ONE instance ARN, so a
    second database in the account (or another project's) is out of reach even
    though the boundary permits the action for the whole name prefix."""
    role_arn = start_schedule["Target"]["RoleArn"]
    account = session.client("sts").get_caller_identity()["Account"]
    foreign_arn = f"arn:aws:rds:{REGION}:{account}:db:someone-elses-database"

    results = _simulate(session, role_arn, ["rds:StopDBInstance"], foreign_arn)

    for result in results:
        assert result["EvalDecision"] != "allowed", (
            "scheduler role can stop a database it does not own — its policy should "
            f"be scoped to {DB_ID} alone"
        )


def test_scheduler_role_carries_the_permissions_boundary(
    session: Any, start_schedule: dict[str, Any]
) -> None:
    """Without the boundary the role is outside the escalation-containment model
    the exec role enforces at CreateRole time."""
    role_name = start_schedule["Target"]["RoleArn"].split("/")[-1]
    role = session.client("iam").get_role(RoleName=role_name)["Role"]

    boundary = role.get("PermissionsBoundary", {}).get("PermissionsBoundaryArn", "")
    assert boundary.endswith(":policy/genai-app-boundary"), (
        f"{role_name} carries boundary {boundary!r}, expected genai-app-boundary"
    )
