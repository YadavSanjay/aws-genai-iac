"""Post-apply verification for dev/42-arag/db against the LIVE AWS API.

Asserts the security and cost posture of the XbrlRag PostgreSQL instance: CMK
encryption, TLS enforced IN THE ENGINE (not just the SG), private-only access,
the AWS-managed master password, backups/PITR, the dev single-AZ posture, and
the retention-bounded encrypted log export. Never reads a row or a credential.

Run:
    AWS_PROFILE=genai-tf task verify
"""

from __future__ import annotations

import os
from typing import Any

import boto3
import pytest
from botocore.exceptions import ClientError

pytestmark = pytest.mark.integration

REGION = os.environ.get("AWS_REGION", "us-east-1")
NAME_PREFIX = os.environ.get("IAC_NAME_PREFIX_ENV", "genai-dev")

INSTANCE_ID = os.environ.get("IAC_ARAG_DB_ID", f"{NAME_PREFIX}-arag")
EXPECTED_DB_NAME = "xbrl_db"
EXPECTED_BACKUP_DAYS = 7


@pytest.fixture(scope="module")
def rds_client() -> Any:
    sess = boto3.Session(region_name=REGION)
    if sess.get_credentials() is None:
        pytest.skip(
            "No AWS credentials resolved. Run with AWS_PROFILE=genai-tf. "
            "Treat this skip as 'unverified', not 'passing'."
        )
    return sess.client("rds")


@pytest.fixture(scope="module")
def instance(rds_client: Any) -> dict[str, Any]:
    try:
        resp = rds_client.describe_db_instances(DBInstanceIdentifier=INSTANCE_ID)
    except ClientError as exc:
        pytest.fail(f"instance {INSTANCE_ID!r} not readable — is the component applied? {exc}")
    return dict(resp["DBInstances"][0])


@pytest.fixture(scope="module")
def project_cmk_arn() -> str:
    kms = boto3.Session(region_name=REGION).client("kms")
    return str(kms.describe_key(KeyId=f"alias/{NAME_PREFIX}-primary")["KeyMetadata"]["Arn"])


# --- Engine ------------------------------------------------------------------


def test_engine_is_postgres_16(instance: dict[str, Any]) -> None:
    assert instance["Engine"] == "postgres", f"engine is {instance['Engine']}, not postgres"
    assert instance["EngineVersion"].split(".")[0] == "16", (
        f"engine version is {instance['EngineVersion']}, expected major 16"
    )


def test_initial_database_is_xbrl_db(instance: dict[str, Any]) -> None:
    assert instance.get("DBName") == EXPECTED_DB_NAME, (
        f"initial database is {instance.get('DBName')!r}, expected {EXPECTED_DB_NAME!r}"
    )


# --- Encryption --------------------------------------------------------------


def test_storage_is_encrypted_with_the_project_cmk(
    instance: dict[str, Any], project_cmk_arn: str
) -> None:
    assert instance["StorageEncrypted"] is True, "storage is not encrypted"
    assert instance.get("KmsKeyId") == project_cmk_arn, (
        f"storage encrypts with {instance.get('KmsKeyId')!r}, not the project CMK"
    )


def test_master_password_is_aws_managed_under_the_cmk(
    instance: dict[str, Any], project_cmk_arn: str
) -> None:
    """The credential lives in a managed, CMK-encrypted secret — never in state."""
    secret = instance.get("MasterUserSecret")
    assert secret, "no managed master-user secret — the password may be in Terraform state"
    assert secret.get("KmsKeyId") == project_cmk_arn, (
        f"master-user secret encrypts with {secret.get('KmsKeyId')!r}, not the project CMK"
    )
    assert secret.get("SecretArn"), "managed master-user secret has no ARN"


# --- Transport ---------------------------------------------------------------


def test_tls_is_enforced_in_the_engine(rds_client: Any, instance: dict[str, Any]) -> None:
    """rds.force_ssl=1 makes the server reject plaintext — belt to the SG's braces.

    A private subnet and SG-to-SG ingress bound WHO can connect; this bounds HOW,
    so a misconfigured DSN cannot silently speak plaintext to the database.
    """
    pg_name = instance["DBParameterGroups"][0]["DBParameterGroupName"]
    paginator = rds_client.get_paginator("describe_db_parameters")
    force_ssl = None
    for page in paginator.paginate(DBParameterGroupName=pg_name):
        for param in page["Parameters"]:
            if param["ParameterName"] == "rds.force_ssl":
                force_ssl = param.get("ParameterValue")
    assert force_ssl == "1", f"rds.force_ssl is {force_ssl!r}, not '1' — plaintext is not rejected"


def test_not_publicly_accessible(instance: dict[str, Any]) -> None:
    """Negative control: the database must never resolve to a public address."""
    assert instance["PubliclyAccessible"] is False, "instance is publicly accessible"


def test_reachable_only_through_its_security_group(instance: dict[str, Any]) -> None:
    sgs = [s["VpcSecurityGroupId"] for s in instance.get("VpcSecurityGroups", [])]
    assert sgs, "instance has no VPC security group"
    ec2 = boto3.Session(region_name=REGION).client("ec2")
    names = {g["GroupName"] for g in ec2.describe_security_groups(GroupIds=sgs)["SecurityGroups"]}
    assert f"{NAME_PREFIX}-rds" in names, (
        f"instance is not attached to the {NAME_PREFIX}-rds group (has {names})"
    )


# --- Durability + dev posture ------------------------------------------------


def test_backups_and_pitr_are_enabled(instance: dict[str, Any]) -> None:
    """Retention > 0 also turns on point-in-time recovery."""
    assert instance["BackupRetentionPeriod"] == EXPECTED_BACKUP_DAYS, (
        f"backup retention is {instance['BackupRetentionPeriod']}, expected {EXPECTED_BACKUP_DAYS}"
    )


def test_dev_posture_is_single_az_without_deletion_protection(instance: dict[str, Any]) -> None:
    """The deliberate dev relaxations — asserted so a silent flip is visible.

    prod raises multi_az and deletion_protection via the module inputs; if these
    are ever true in dev it is drift, not an upgrade.
    """
    assert instance["MultiAZ"] is False, "Multi-AZ is on in dev — unexpected cost"
    assert instance["DeletionProtection"] is False, "deletion protection is on in dev"


def test_storage_is_gp3_and_autoscaling(instance: dict[str, Any]) -> None:
    assert instance["StorageType"] == "gp3", f"storage type is {instance['StorageType']}, not gp3"
    assert instance.get("MaxAllocatedStorage", 0) > instance["AllocatedStorage"], (
        "storage autoscaling is off — a growing corpus could hit ENOSPC"
    )


# --- Observability -----------------------------------------------------------


def test_postgresql_log_is_exported(instance: dict[str, Any]) -> None:
    exports = instance.get("EnabledCloudwatchLogsExports", [])
    assert "postgresql" in exports, f"postgresql log export is off (exports: {exports})"


def test_log_group_has_bounded_retention_and_cmk(project_cmk_arn: str) -> None:
    """The exported log must not land in a never-expiring, AWS-key group."""
    logs = boto3.Session(region_name=REGION).client("logs")
    group_name = f"/aws/rds/instance/{INSTANCE_ID}/postgresql"
    groups = logs.describe_log_groups(logGroupNamePrefix=group_name)["logGroups"]
    match = next((g for g in groups if g["logGroupName"] == group_name), None)
    assert match, f"log group {group_name} does not exist"
    assert match.get("retentionInDays"), f"{group_name} never expires — retention is unset"
    assert match.get("kmsKeyId") == project_cmk_arn, (
        f"{group_name} encrypts with {match.get('kmsKeyId')!r}, not the project CMK"
    )


# --- Tags --------------------------------------------------------------------


def test_instance_carries_mandatory_tags(instance: dict[str, Any]) -> None:
    tags = {t["Key"]: t["Value"] for t in instance.get("TagList", [])}
    for required in ("Project", "Environment", "ManagedBy"):
        assert required in tags, f"missing mandatory tag {required!r}. Present: {sorted(tags)}"
    assert tags["ManagedBy"] == "terragrunt"
