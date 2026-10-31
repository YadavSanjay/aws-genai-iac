"""Post-apply verification for dev/90-observability/scheduler-alarms.

These alarms exist because a scheduled stop failed on 2026-07-27 and nothing
reported it, so the tests assert the properties that decide whether a NOTIFICATION
actually reaches a human — not merely that two alarms exist:

  * they publish to the ops topic (an alarm with no action is a dashboard widget);
  * they watch the right namespace/metric/dimension, since a typo in any of the
    three yields an alarm that can never fire;
  * missing data is treated as NOT breaching, or the alarm sits in
    INSUFFICIENT_DATA and no transition is ever raised.

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

TOPIC_NAME = f"{NAME_PREFIX}-ops-alerts"
EXPECTED_ALARMS = {
    f"{NAME_PREFIX}-schedules-target-errors": "TargetErrorCount",
    f"{NAME_PREFIX}-schedules-invocations-dropped": "InvocationDroppedCount",
}
EXPECTED_NAMESPACE = "AWS/Scheduler"
EXPECTED_GROUP = "default"


@pytest.fixture(scope="module")
def session() -> boto3.Session:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess


@pytest.fixture(scope="module")
def alarms(session: boto3.Session) -> dict[str, dict[str, Any]]:
    resp = session.client("cloudwatch").describe_alarms(
        AlarmNames=sorted(EXPECTED_ALARMS), AlarmTypes=["MetricAlarm"]
    )
    found = {a["AlarmName"]: a for a in resp["MetricAlarms"]}
    missing = set(EXPECTED_ALARMS) - set(found)
    assert not missing, f"alarms not found — is the component applied? {sorted(missing)}"
    return found


@pytest.fixture(scope="module")
def topic_arn(session: boto3.Session) -> str:
    account = session.client("sts").get_caller_identity()["Account"]
    return f"arn:aws:sns:{REGION}:{account}:{TOPIC_NAME}"


def test_alarms_watch_the_scheduler_metrics(alarms: dict[str, dict[str, Any]]) -> None:
    """A typo in namespace, metric or dimension produces an alarm that looks
    healthy forever because the metric it names never reports."""
    for name, metric in EXPECTED_ALARMS.items():
        alarm = alarms[name]
        assert alarm["Namespace"] == EXPECTED_NAMESPACE, f"{name} watches {alarm['Namespace']}"
        assert alarm["MetricName"] == metric, f"{name} watches {alarm['MetricName']}"

        dims = {d["Name"]: d["Value"] for d in alarm["Dimensions"]}
        assert dims == {"ScheduleGroup": EXPECTED_GROUP}, f"{name} dimensions are {dims}"


def test_alarms_fire_on_any_occurrence(alarms: dict[str, dict[str, Any]]) -> None:
    """One refused invocation is one host billing all night — the threshold is any
    occurrence, not an average or a rate."""
    for name in EXPECTED_ALARMS:
        alarm = alarms[name]
        assert alarm["Statistic"] == "Sum", f"{name} uses {alarm['Statistic']}, not Sum"
        assert alarm["Threshold"] == 0.0, f"{name} threshold is {alarm['Threshold']}"
        assert alarm["ComparisonOperator"] == "GreaterThanThreshold"
        assert alarm["EvaluationPeriods"] == 1


def test_missing_data_is_not_breaching(alarms: dict[str, dict[str, Any]]) -> None:
    """Schedules are idle for all but a few minutes a day. Any other setting either
    pages continuously or parks the alarm in INSUFFICIENT_DATA, where it never
    raises a transition."""
    for name in EXPECTED_ALARMS:
        treat = alarms[name].get("TreatMissingData")
        assert treat == "notBreaching", f"{name} treats missing data as {treat!r}"


def test_alarms_notify_the_ops_topic(alarms: dict[str, dict[str, Any]], topic_arn: str) -> None:
    """An alarm with no action is a dashboard widget, not detection."""
    for name in EXPECTED_ALARMS:
        alarm = alarms[name]
        assert alarm["AlarmActions"] == [topic_arn], (
            f"{name} alarm actions are {alarm['AlarmActions']}, expected [{topic_arn}]"
        )
        assert alarm["OKActions"] == [topic_arn], (
            f"{name} sends no OK notification — a recovery nobody hears about looks "
            "identical to an alarm nobody fixed"
        )


def test_alarms_are_enabled(alarms: dict[str, dict[str, Any]]) -> None:
    for name in EXPECTED_ALARMS:
        assert alarms[name]["ActionsEnabled"] is True, f"{name} has actions disabled"


def test_the_notification_channel_can_actually_deliver(
    session: boto3.Session, topic_arn: str
) -> None:
    """The failure one level up: alarms correctly wired to a topic that delivers to
    nobody. An email subscription sits in PendingConfirmation until a human clicks,
    and Terraform reports it created either way.

    Reads the subscription list rather than the topic's SubscriptionsConfirmed
    counter — that aggregate lags reality by minutes, so it would fail a healthy
    channel (and, worse, could pass a broken one)."""
    subs = session.client("sns").list_subscriptions_by_topic(TopicArn=topic_arn)["Subscriptions"]
    confirmed = [s for s in subs if s["SubscriptionArn"].startswith("arn:aws:sns:")]

    assert confirmed, (
        f"the ops topic has no confirmed subscriber ({[s['SubscriptionArn'] for s in subs]}), "
        "so these alarms will fire into the void — click 'Confirm subscription' in the AWS email"
    )
