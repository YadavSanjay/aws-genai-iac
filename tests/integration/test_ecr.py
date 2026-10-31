"""Post-apply verification for dev/20-data/ecr against the LIVE AWS API.

The lifecycle assertions are the ones that matter most: a repository without
them grows forever at $0.10/GB-month and nothing ever fails to signal it.

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

EXPECTED_REPOSITORIES = [
    f"{NAME_PREFIX}/macrorag",
    f"{NAME_PREFIX}/macrorag-ui",
    # RagInference's slim ARM64 inference image (R1).
    f"{NAME_PREFIX}/raginference",
    # Upstream images mirrored from Docker Hub (§ ecr component): the shared Qdrant
    # and MacroRAG's two compose sidecars. Empty until pushed, but the immutability
    # / lifecycle / CMK / scan posture applies at creation and is verified here.
    f"{NAME_PREFIX}/qdrant",
    f"{NAME_PREFIX}/redis",
    f"{NAME_PREFIX}/otel-collector",
    # XbrlRag subsystem (A1). Serving image, UI, and full ingest image. Same posture
    # asserted at creation, empty until built.
    f"{NAME_PREFIX}/arag",
    f"{NAME_PREFIX}/arag-ui",
    f"{NAME_PREFIX}/arag-ingest",
    # Faultline subsystem (Q1). Backend (QuantLib, every entrypoint), the
    # QuantLib-free BFF, and the nginx SPA. Empty until built.
    f"{NAME_PREFIX}/qlp-backend",
    f"{NAME_PREFIX}/qlp-bff",
    f"{NAME_PREFIX}/qlp-ui",
]
EXPECTED_KEEP_TAGGED = 5
EXPECTED_UNTAGGED_DAYS = 3


@pytest.fixture(scope="module")
def ecr_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("ecr")


@pytest.fixture(scope="module")
def repositories(ecr_client: Any) -> dict[str, dict[str, Any]]:
    try:
        found = ecr_client.describe_repositories(repositoryNames=EXPECTED_REPOSITORIES)
    except ClientError as exc:
        pytest.fail(f"repositories not readable — is the component applied? {exc}")
    return {r["repositoryName"]: dict(r) for r in found["repositories"]}


@pytest.fixture(scope="module")
def kms_key_arn() -> str:
    sess = boto3.Session(region_name=REGION)
    return str(
        sess.client("kms").describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"]["Arn"]
    )


# --- Repository configuration ------------------------------------------------


def test_all_expected_repositories_exist(repositories: dict[str, dict[str, Any]]) -> None:
    assert set(repositories) == set(EXPECTED_REPOSITORIES)


def test_no_unmanaged_repositories_exist(ecr_client: Any) -> None:
    """Nothing under the env prefix that the component does not declare.

    The fixture above asks for repositories BY NAME, so it can only ever prove
    the declared ones exist — a repository created by hand stays invisible to
    it. This lists the account instead: anything present in AWS and absent from
    code is drift, and drift is the thing that quietly survives a refactor.
    """
    live = {
        name
        for page in ecr_client.get_paginator("describe_repositories").paginate()
        for repo in page["repositories"]
        if (name := repo["repositoryName"]).startswith(f"{NAME_PREFIX}/")
    }
    assert live == set(EXPECTED_REPOSITORIES), (
        f"undeclared repositories: {sorted(live - set(EXPECTED_REPOSITORIES))}"
    )


def test_repositories_encrypt_with_the_project_cmk(
    repositories: dict[str, dict[str, Any]], kms_key_arn: str
) -> None:
    """KMS, not the AES256 default — image layers share the estate's key policy."""
    for name, repo in repositories.items():
        config = repo.get("encryptionConfiguration", {})
        assert config.get("encryptionType") == "KMS", (
            f"{name} uses {config.get('encryptionType')} rather than the project CMK"
        )
        assert config.get("kmsKey") == kms_key_arn, (
            f"{name} encrypts with {config.get('kmsKey')}, not {kms_key_arn}"
        )


def test_image_tags_are_immutable(repositories: dict[str, dict[str, Any]]) -> None:
    """A pushed tag must never be repointable at different content.

    Without this, an audited tag can be quietly replaced and a deployed tag
    stops being a reliable record of what is running.
    """
    for name, repo in repositories.items():
        assert repo["imageTagMutability"] == "IMMUTABLE", (
            f"{name} allows tag overwrites ({repo['imageTagMutability']})"
        )


def test_images_are_scanned_on_push(repositories: dict[str, dict[str, Any]]) -> None:
    for name, repo in repositories.items():
        config = repo.get("imageScanningConfiguration", {})
        assert config.get("scanOnPush") is True, f"{name} does not scan on push"


def test_repositories_carry_mandatory_tags(
    ecr_client: Any, repositories: dict[str, dict[str, Any]]
) -> None:
    for name, repo in repositories.items():
        tags = {
            t["Key"]: t["Value"]
            for t in ecr_client.list_tags_for_resource(resourceArn=repo["repositoryArn"])["tags"]
        }
        for required in ("Project", "Environment", "ManagedBy"):
            assert required in tags, (
                f"{name} missing mandatory tag {required!r}. Present: {sorted(tags)}"
            )


# --- Lifecycle: the silent cost leak -----------------------------------------


@pytest.fixture(scope="module")
def lifecycle_rules(
    ecr_client: Any, repositories: dict[str, dict[str, Any]]
) -> dict[str, list[dict[str, Any]]]:
    rules: dict[str, list[dict[str, Any]]] = {}
    for name in repositories:
        try:
            policy = ecr_client.get_lifecycle_policy(repositoryName=name)
        except ClientError as exc:
            pytest.fail(
                f"{name} has NO lifecycle policy ({exc}). It will grow without "
                "bound at $0.10/GB-month, and nothing will fail to signal it."
            )
        rules[name] = list(json.loads(policy["lifecyclePolicyText"])["rules"])
    return rules


def test_untagged_images_expire(lifecycle_rules: dict[str, list[dict[str, Any]]]) -> None:
    """Untagged images are residue of overwritten or failed pushes.

    Nothing references them, so without a rule they accumulate invisibly.
    """
    for name, rules in lifecycle_rules.items():
        untagged = [r for r in rules if r["selection"]["tagStatus"] == "untagged"]
        assert untagged, f"{name} never expires untagged images"

        selection = untagged[0]["selection"]
        assert selection["countType"] == "sinceImagePushed"
        assert selection["countNumber"] == EXPECTED_UNTAGGED_DAYS
        assert untagged[0]["action"]["type"] == "expire"


def test_tagged_history_is_bounded(lifecycle_rules: dict[str, list[dict[str, Any]]]) -> None:
    for name, rules in lifecycle_rules.items():
        bounded = [r for r in rules if r["selection"]["countType"] == "imageCountMoreThan"]
        assert bounded, f"{name} retains unlimited tagged images"

        selection = bounded[0]["selection"]
        assert selection["countNumber"] == EXPECTED_KEEP_TAGGED, (
            f"{name} retains {selection['countNumber']} images, expected {EXPECTED_KEEP_TAGGED}"
        )
        assert bounded[0]["action"]["type"] == "expire"


def test_untagged_rule_runs_before_the_retention_rule(
    lifecycle_rules: dict[str, list[dict[str, Any]]],
) -> None:
    """Priority ordering is load-bearing, not cosmetic.

    ECR evaluates rules in priority order and an image is acted on by the first
    matching rule. If the count-based rule ran first it would match untagged
    images too, letting them consume retention slots that should hold real
    builds.
    """
    for name, rules in lifecycle_rules.items():
        by_priority = sorted(rules, key=lambda r: r["rulePriority"])
        assert by_priority[0]["selection"]["tagStatus"] == "untagged", (
            f"{name}: the untagged-expiry rule does not run first "
            f"(order: {[r['selection']['tagStatus'] for r in by_priority]})"
        )
