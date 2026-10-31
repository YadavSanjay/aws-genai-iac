"""Post-apply verification for `global/cost-guardrails` against the LIVE AWS API.

Per the provisioning principles in the root CLAUDE.md, a successful `terraform
apply` is not evidence that a resource is configured correctly. These tests query
what AWS actually holds and assert on it.

Deliberately NOT using `moto`. A mocked Budgets API would happily return whatever
we told it to and prove nothing about the account. `moto` stays available for
engine unit tests; it has no place in post-apply verification.

Identity: runs under `genai-tf` (the exec role), which already holds `budgets:*`,
`ce:*` and `sns:*`. `readonlyagent` is not used here because its grants are
condition-gated on `aws:CalledViaAWSMCP` and so are unavailable to boto3.

Run:
    AWS_PROFILE=genai-tf conda run -n py312 pytest tests/integration -m integration

Skips loudly (never silently passes) when credentials are absent.
"""

from __future__ import annotations

import json
import os
from typing import Any

import boto3
import pytest
from botocore.exceptions import BotoCoreError, ClientError

pytestmark = pytest.mark.integration

NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX", "genai")
REGION = os.environ.get("AWS_REGION", "us-east-1")

BUDGET_NAME = f"{NAME_PREFIX}-monthly-cost"
TOPIC_NAME = f"{NAME_PREFIX}-cost-alerts"

# Not <prefix>-service-anomalies: AWS caps dimensional (SERVICE) spend monitors at
# one per account, and this account already carried the auto-created default. It
# is adopted into Terraform state by name rather than replaced, which would have
# discarded the trained baseline. See infra/modules/cost/budgets/variables.tf.
MONITOR_NAME = os.environ.get("IAC_ANOMALY_MONITOR_NAME", "Default-Services-Monitor")

EXPECTED_BUDGET_USD = 150.0
EXPECTED_ACTUAL_THRESHOLDS = {50.0, 80.0, 100.0}
EXPECTED_ANOMALY_IMPACT_USD = 10.0
EXPECTED_PUBLISHERS = {"budgets.amazonaws.com", "costalerts.amazonaws.com"}


@pytest.fixture(scope="module")
def session() -> boto3.Session:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. These are live post-apply checks, not "
            "mocks — run with AWS_PROFILE=genai-tf. Treat this skip as "
            "'unverified', not 'passing'."
        )
    return sess


@pytest.fixture(scope="module")
def account_id(session: boto3.Session) -> str:
    return str(session.client("sts").get_caller_identity()["Account"])


@pytest.fixture(scope="module")
def budget(session: boto3.Session, account_id: str) -> dict[str, Any]:
    try:
        resp = session.client("budgets").describe_budget(
            AccountId=account_id, BudgetName=BUDGET_NAME
        )
    except (ClientError, BotoCoreError) as exc:
        pytest.fail(f"Budget {BUDGET_NAME!r} not readable — is the component applied? {exc}")
    return dict(resp["Budget"])


@pytest.fixture(scope="module")
def topic_arn(session: boto3.Session, account_id: str) -> str:
    return f"arn:aws:sns:{REGION}:{account_id}:{TOPIC_NAME}"


@pytest.fixture(scope="module")
def topic_attributes(session: boto3.Session, topic_arn: str) -> dict[str, str]:
    try:
        resp = session.client("sns").get_topic_attributes(TopicArn=topic_arn)
    except (ClientError, BotoCoreError) as exc:
        pytest.fail(f"SNS topic {topic_arn!r} not readable — is the component applied? {exc}")
    return dict(resp["Attributes"])


# --- Budget ------------------------------------------------------------------


def test_budget_limit_matches_declared_ceiling(budget: dict[str, Any]) -> None:
    limit = budget["BudgetLimit"]
    assert limit["Unit"] == "USD"
    assert float(limit["Amount"]) == pytest.approx(EXPECTED_BUDGET_USD)
    assert budget["TimeUnit"] == "MONTHLY"
    assert budget["BudgetType"] == "COST"


def test_budget_excludes_credits_and_refunds(budget: dict[str, Any]) -> None:
    """Credits masking real spend is the classic way a budget silently under-reports."""
    cost_types = budget["CostTypes"]
    assert cost_types["IncludeCredit"] is False
    assert cost_types["IncludeRefund"] is False
    assert cost_types["IncludeTax"] is True
    assert cost_types["IncludeSupport"] is True


def test_budget_has_tiered_actual_and_forecast_alerts(
    session: boto3.Session, account_id: str, topic_arn: str
) -> None:
    pairs = session.client("budgets").describe_notifications_for_budget(
        AccountId=account_id, BudgetName=BUDGET_NAME
    )["Notifications"]

    actual = {n["Threshold"] for n in pairs if n["NotificationType"] == "ACTUAL"}
    forecast = {n["Threshold"] for n in pairs if n["NotificationType"] == "FORECASTED"}

    assert actual == EXPECTED_ACTUAL_THRESHOLDS, f"unexpected ACTUAL thresholds: {actual}"
    assert 100.0 in forecast, "no FORECASTED alert — nothing warns before the cap is hit"

    # Every notification must actually route somewhere.
    budgets = session.client("budgets")
    for notif in pairs:
        subs = budgets.describe_subscribers_for_notification(
            AccountId=account_id, BudgetName=BUDGET_NAME, Notification=notif
        )["Subscribers"]
        addresses = {s["Address"] for s in subs}
        assert topic_arn in addresses, f"notification {notif} does not publish to {topic_arn}"


# --- SNS channel -------------------------------------------------------------


def test_topic_is_encrypted_at_rest(topic_attributes: dict[str, str]) -> None:
    assert topic_attributes.get("KmsMasterKeyId"), "cost-alert topic is unencrypted"


def test_topic_policy_grants_publish_only_to_expected_services(
    topic_attributes: dict[str, str], account_id: str
) -> None:
    policy = json.loads(topic_attributes["Policy"])
    allows = [s for s in policy["Statement"] if s["Effect"] == "Allow"]

    granted: set[str] = set()
    for stmt in allows:
        principal = stmt.get("Principal", {})
        assert principal != "*", f"wildcard principal holds {stmt.get('Action')}"
        services = principal.get("Service", [])
        granted.update([services] if isinstance(services, str) else services)

        # Confused-deputy gate: each service grant is pinned to this account.
        conditions = stmt.get("Condition", {}).get("StringEquals", {})
        assert conditions.get("aws:SourceAccount") == account_id, (
            f"statement {stmt.get('Sid')!r} lacks an aws:SourceAccount condition"
        )

    assert granted == EXPECTED_PUBLISHERS, f"unexpected publishers: {granted}"


def test_topic_policy_denies_plaintext_transport(topic_attributes: dict[str, str]) -> None:
    """Negative control: the thing that should be denied is actually denied."""
    policy = json.loads(topic_attributes["Policy"])
    denies = [s for s in policy["Statement"] if s["Effect"] == "Deny"]

    assert any(
        s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") in ("false", False)
        for s in denies
    ), "no aws:SecureTransport deny — cost alerts may traverse plaintext HTTP"


def test_alert_emails_are_confirmed_not_merely_created(
    session: boto3.Session, topic_arn: str
) -> None:
    """The failure this whole module exists to prevent.

    Terraform reports an email subscription as created while it sits in
    "PendingConfirmation" — delivering nothing. An apply-only check would call
    that success and the budget would never reach a human.
    """
    attrs = session.client("sns").get_topic_attributes(TopicArn=topic_arn)["Attributes"]
    confirmed = int(attrs.get("SubscriptionsConfirmed", 0))
    pending = int(attrs.get("SubscriptionsPending", 0))

    assert confirmed >= 1, (
        f"{confirmed} confirmed / {pending} pending subscriptions. Every alert "
        "address must click its AWS confirmation email; until then the budget "
        "notifies nobody."
    )


# --- Cost Anomaly Detection --------------------------------------------------


def test_anomaly_monitor_watches_per_service_spend(session: boto3.Session) -> None:
    monitors = session.client("ce").get_anomaly_monitors()["AnomalyMonitors"]
    mine = [m for m in monitors if m["MonitorName"] == MONITOR_NAME]

    assert mine, f"no anomaly monitor named {MONITOR_NAME!r}"
    assert mine[0]["MonitorType"] == "DIMENSIONAL"
    assert mine[0]["MonitorDimension"] == "SERVICE"

    # AWS permits exactly one. A second would mean we created a duplicate rather
    # than adopting the existing monitor — i.e. the import went wrong.
    dimensional = [m for m in monitors if m["MonitorType"] == "DIMENSIONAL"]
    assert len(dimensional) == 1, (
        f"expected exactly one dimensional monitor, found {len(dimensional)}"
    )


def test_anomaly_monitor_is_managed_by_terraform(session: boto3.Session) -> None:
    """The adopted monitor must be under IaC control, not console drift.

    Tags are the observable proof the import landed: AWS's auto-created monitor
    has none until Terraform manages it.
    """
    monitors = session.client("ce").get_anomaly_monitors()["AnomalyMonitors"]
    arn = next(m["MonitorArn"] for m in monitors if m["MonitorName"] == MONITOR_NAME)

    tags = {
        t["Key"]: t["Value"]
        for t in session.client("ce").list_tags_for_resource(ResourceArn=arn)["ResourceTags"]
    }
    assert tags.get("ManagedBy") == "terragrunt", f"monitor not under IaC management: {tags}"
    assert tags.get("Project") == "aws-genai-iac"


def test_anomaly_subscription_routes_to_topic_above_threshold(
    session: boto3.Session, topic_arn: str
) -> None:
    subs = session.client("ce").get_anomaly_subscriptions()["AnomalySubscriptions"]
    mine = [s for s in subs if s["SubscriptionName"] == f"{NAME_PREFIX}-anomaly-alerts"]
    assert mine, "no anomaly subscription — anomalies would be detected but not delivered"

    sub = mine[0]
    addresses = {s["Address"] for s in sub["Subscribers"]}
    assert topic_arn in addresses

    expr = sub.get("ThresholdExpression", {})
    values = expr.get("Dimensions", {}).get("Values", [])
    assert values, "anomaly subscription has no threshold expression"
    assert float(values[0]) == pytest.approx(EXPECTED_ANOMALY_IMPACT_USD)
