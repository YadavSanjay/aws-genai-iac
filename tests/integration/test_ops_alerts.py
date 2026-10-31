"""Post-apply verification for dev/90-observability/alerts against the LIVE API.

This topic is the estate's detection channel, so the tests are written against the
way a notification channel actually fails: quietly. It is encrypted, only
CloudWatch may publish, plaintext transport is refused, and — the one an
apply-only check would miss — the email subscriptions are CONFIRMED rather than
merely created.

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

TOPIC_NAME = f"{NAME_PREFIX}-ops-alerts"
EXPECTED_PUBLISHERS = {"cloudwatch.amazonaws.com"}


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
def topic_arn(session: boto3.Session) -> str:
    account = session.client("sts").get_caller_identity()["Account"]
    arn = f"arn:aws:sns:{REGION}:{account}:{TOPIC_NAME}"
    try:
        session.client("sns").get_topic_attributes(TopicArn=arn)
    except ClientError as exc:
        pytest.fail(f"topic {TOPIC_NAME!r} not readable — is the component applied? {exc}")
    return arn


@pytest.fixture(scope="module")
def topic_attributes(session: boto3.Session, topic_arn: str) -> dict[str, str]:
    return dict(session.client("sns").get_topic_attributes(TopicArn=topic_arn)["Attributes"])


def test_topic_is_encrypted_at_rest(topic_attributes: dict[str, str]) -> None:
    assert topic_attributes.get("KmsMasterKeyId"), "topic is not encrypted at rest"


def test_only_cloudwatch_may_publish(topic_attributes: dict[str, str]) -> None:
    """Set equality, not membership: a membership check still passes when some
    other service has been granted publish alongside CloudWatch."""
    policy = json.loads(topic_attributes["Policy"])
    granted = {
        principal
        for stmt in policy["Statement"]
        if stmt["Effect"] == "Allow"
        for principal in _as_list(stmt.get("Principal", {}).get("Service", []))
    }
    assert granted == EXPECTED_PUBLISHERS, (
        f"publish granted to {sorted(granted)}, expected exactly {sorted(EXPECTED_PUBLISHERS)}"
    )


def test_publish_is_confused_deputy_gated(topic_attributes: dict[str, str]) -> None:
    """Without a SourceAccount condition, any account's CloudWatch alarm could
    publish into this topic — alert injection, and a plausible way to bury a real
    alarm under noise."""
    policy = json.loads(topic_attributes["Policy"])
    account = topic_attributes["TopicArn"].split(":")[4]

    for stmt in policy["Statement"]:
        if stmt["Effect"] != "Allow":
            continue
        condition = stmt.get("Condition", {}).get("StringEquals", {})
        values = _as_list(condition.get("aws:SourceAccount", []))
        assert values == [account], (
            f"statement {stmt.get('Sid')!r} is not gated on aws:SourceAccount={account}"
        )


def test_plaintext_transport_is_denied(topic_attributes: dict[str, str]) -> None:
    policy = json.loads(topic_attributes["Policy"])
    denies = [
        stmt
        for stmt in policy["Statement"]
        if stmt["Effect"] == "Deny"
        and stmt.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport")
        in ("false", ["false"])
    ]
    assert denies, "no aws:SecureTransport deny — the topic accepts plaintext publishes"


def test_no_iam_principal_is_granted_publish(topic_attributes: dict[str, str]) -> None:
    """Negative control. Alarms publish as a service principal; nothing in the
    estate needs a role or user publishing here, and a wildcard AWS principal on
    an Allow would let any caller in the account inject alerts."""
    policy = json.loads(topic_attributes["Policy"])
    for stmt in policy["Statement"]:
        if stmt["Effect"] != "Allow":
            continue
        aws_principals = _as_list(stmt.get("Principal", {}).get("AWS", []))
        assert not aws_principals, (
            f"statement {stmt.get('Sid')!r} grants publish to AWS principals {aws_principals}"
        )


def test_alert_emails_are_confirmed_not_merely_created(
    session: boto3.Session, topic_arn: str
) -> None:
    """The failure this whole component exists to prevent, in miniature: Terraform
    reports an email subscription created while it sits in PendingConfirmation,
    delivering nothing. An apply-only check would call this channel healthy.

    Read from the subscription LIST, not the SubscriptionsConfirmed attribute on
    the topic: that counter is an aggregate SNS updates lazily, and it still read 0
    several minutes after a subscription was genuinely confirmed. The list carries
    the real state immediately — an unconfirmed entry has the literal string
    "PendingConfirmation" (or "Deleted") where its ARN belongs — and it names WHICH
    endpoint is at fault.
    """
    subs = session.client("sns").list_subscriptions_by_topic(TopicArn=topic_arn)["Subscriptions"]
    assert subs, "topic has no subscriptions at all"

    unconfirmed = {
        s["Endpoint"]: s["SubscriptionArn"]
        for s in subs
        if not s["SubscriptionArn"].startswith("arn:aws:sns:")
    }
    assert not unconfirmed, (
        f"subscriptions not confirmed: {unconfirmed}. The alarms will fire into a "
        "topic that delivers to nobody — click 'Confirm subscription' in the AWS email."
    )


def _as_list(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    return list(value)
