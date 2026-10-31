"""Cross-cutting drift check: every EC2 schedule targets the instance that exists.

The estate has two scheduling patterns live at once:

  * FOLDED IN — the schedule is created by the instance's own module, so its
    target is a reference (`aws_instance.*.id`) and a replacement rewrites it in
    the same apply. Faultline and the XbrlRag database work this way.
  * SEPARATE `*-schedule` COMPONENT — the schedule holds a COPY of the instance
    id, read once through a Terragrunt dependency. Reprovisioning the host
    without also re-applying that component leaves the schedule driving a
    terminated instance.

The second pattern fails SILENTLY: EventBridge Scheduler invokes, the EC2 call
errors in the background, and the schedule still reports itself ENABLED with a
healthy last-invocation time. Nothing surfaces until someone notices a host that
did not come up, or a bill for one that never went down.

This test is the mechanical check for that. It is deliberately estate-wide
rather than per-subsystem, because the failure is a property of the pattern, not
of any one workload.

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

# schedule workload -> EC2 Name tag of the instance it must drive.
#
# Not always identical: the NAT's schedules kept the module's default workload
# ("instance") from before it took a name, so they are genai-dev-instance-*
# while the host is tagged genai-dev-nat.
WORKLOAD_TO_INSTANCE_TAG = {
    "instance": f"{NAME_PREFIX}-nat",
    "qdrant": f"{NAME_PREFIX}-qdrant",
    "macrorag": f"{NAME_PREFIX}-macrorag",
    "arag": f"{NAME_PREFIX}-arag",
    "qlp": f"{NAME_PREFIX}-qlp",
}

# Schedules whose target is not an EC2 instance (the XbrlRag database is an RDS
# start/stop pair) and so is out of scope for this check.
NON_EC2_WORKLOADS = {"arag-db"}


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
def live_instance_ids(session: Any) -> dict[str, str]:
    """Current instance id for each Name tag we schedule."""
    ec2 = session.client("ec2")
    found: dict[str, str] = {}
    for tag in set(WORKLOAD_TO_INSTANCE_TAG.values()):
        reservations = ec2.describe_instances(
            Filters=[
                {"Name": "tag:Name", "Values": [tag]},
                {
                    "Name": "instance-state-name",
                    "Values": ["pending", "running", "stopping", "stopped"],
                },
            ]
        )["Reservations"]
        ids = [i["InstanceId"] for r in reservations for i in r["Instances"]]
        assert len(ids) <= 1, f"more than one live instance tagged {tag}: {ids}"
        if ids:
            found[tag] = ids[0]
    return found


@pytest.fixture(scope="module")
def ec2_schedules(session: Any) -> dict[str, dict[str, Any]]:
    """Every <prefix>-<workload>-{start,stop} schedule that drives an EC2 host."""
    client = session.client("scheduler")
    names = [
        s["Name"]
        for page in client.get_paginator("list_schedules").paginate()
        for s in page["Schedules"]
        if s["Name"].startswith(f"{NAME_PREFIX}-")
    ]

    out: dict[str, dict[str, Any]] = {}
    for name in names:
        workload = name[len(NAME_PREFIX) + 1 :].rsplit("-", 1)[0]
        if workload in NON_EC2_WORKLOADS:
            continue
        out[name] = dict(client.get_schedule(Name=name))
    return out


def test_every_ec2_schedule_is_mapped(ec2_schedules: dict[str, dict[str, Any]]) -> None:
    """A new scheduled workload must be added here, not silently skipped.

    Without this, adding a tier and forgetting the mapping would leave its
    schedule unchecked while the suite still went green.
    """
    unmapped = {
        name[len(NAME_PREFIX) + 1 :].rsplit("-", 1)[0]
        for name in ec2_schedules
        if name[len(NAME_PREFIX) + 1 :].rsplit("-", 1)[0] not in WORKLOAD_TO_INSTANCE_TAG
    }
    assert not unmapped, (
        f"scheduled workloads with no instance mapping: {sorted(unmapped)}. "
        "Add them to WORKLOAD_TO_INSTANCE_TAG or NON_EC2_WORKLOADS."
    )


def test_no_schedule_targets_a_dead_instance(
    ec2_schedules: dict[str, dict[str, Any]], live_instance_ids: dict[str, str]
) -> None:
    """THE check: a schedule pointing at a replaced host does nothing, quietly."""
    stale: list[str] = []
    for name, sched in ec2_schedules.items():
        workload = name[len(NAME_PREFIX) + 1 :].rsplit("-", 1)[0]
        tag = WORKLOAD_TO_INSTANCE_TAG.get(workload)
        if tag is None or tag not in live_instance_ids:
            continue

        targeted = json.loads(sched["Target"]["Input"])["InstanceIds"]
        expected = live_instance_ids[tag]
        if targeted != [expected]:
            stale.append(f"{name}: targets {targeted}, live {tag} is {expected}")

    assert not stale, (
        "schedules pointing at instances that no longer exist — they will fire, "
        "fail in the background, and still report ENABLED:\n  " + "\n  ".join(stale)
    )
