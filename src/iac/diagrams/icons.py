"""Map Terragrunt module types and tier folders to AWS diagram nodes.

Kept importable (separate from the render script) so a test can assert that every
module used in the real infra tree has an icon — a new module then fails the test
instead of silently rendering as the generic fallback.
"""

from __future__ import annotations

from typing import Any

from diagrams.aws.compute import EC2, ECR, Fargate
from diagrams.aws.database import RDS
from diagrams.aws.general import General
from diagrams.aws.integration import SNS, Eventbridge
from diagrams.aws.management import Cloudwatch
from diagrams.aws.network import (
    VPC,
    CloudMap,
    ElbApplicationLoadBalancer,
    Endpoint,
    Nacl,
    NATGateway,
    PrivateSubnet,
)
from diagrams.aws.security import KMS, SecretsManager
from diagrams.aws.storage import S3

# module path (from `source = ".../modules/<cat>/<name>"`) -> diagram node class.
# Values are `diagrams` node classes; typed as Any since the library ships no stubs.
MODULE_ICON: dict[str, Any] = {
    "networking/vpc": VPC,
    "networking/subnets": PrivateSubnet,
    "networking/dns": CloudMap,
    "networking/endpoints": Endpoint,
    "networking/nat-instance": NATGateway,
    "networking/security-groups": Nacl,  # no dedicated SG icon; NACL is closest
    "security/kms": KMS,
    "security/secrets": SecretsManager,
    "registry/ecr": ECR,
    "data/s3": S3,
    "data/qdrant": EC2,  # Qdrant runs on a dedicated EC2 host
    "data/rds": RDS,
    "compute/ecs-service": Fargate,
    "compute/ec2-app": EC2,
    "compute/ingest-runner": EC2,  # on-demand ingest EC2
    "edge/alb": ElbApplicationLoadBalancer,
    "scheduler/eventbridge": Eventbridge,
    "observability/alerts": SNS,  # the alarm notification channel
    "observability/scheduler-alarms": Cloudwatch,
}

# tier folder -> human-readable cluster label.
TIER_LABEL: dict[str, str] = {
    "00-networking": "Networking",
    "10-security": "Security",
    "20-data": "Data",
    "30-shared-svc": "Shared services",
    "40-quantlibpricer": "Faultline",
    "41-macrorag": "MacroRAG",
    "42-arag": "XbrlRag",
    "90-observability": "Observability",
    "91-cost": "Cost",
}


def icon_for(module: str | None) -> Any:
    """Diagram node class for a module path, or the generic node if unmapped."""
    return MODULE_ICON.get(module, General) if module else General
