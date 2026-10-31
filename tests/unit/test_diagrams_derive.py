"""Tests for the architecture-model derivation (src/iac/diagrams/derive.py).

These parse the REAL infra/environments/dev tree — no mocks, no AWS — and assert
on the derived graph, so a change to the infra that the diagram cannot represent
(a new module with no icon, a broken dependency path) fails here.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from iac.diagrams.derive import (
    Model,
    dataflow_edges,
    derive_model,
    read_ingress_mode,
    security_edges,
    transitive_reduction,
)
from iac.diagrams.icons import MODULE_ICON, TIER_LABEL

REPO_ROOT = Path(__file__).resolve().parents[2]
DEV_DIR = REPO_ROOT / "infra" / "environments" / "dev"


@pytest.fixture(scope="module")
def model() -> Model:
    return derive_model(DEV_DIR, "dev")


def test_discovers_the_built_components(model: Model) -> None:
    keys = {c.key for c in model.components}
    for expected in (
        "00-networking/vpc",
        "10-security/kms",
        "20-data/macrorag-corpus",
        "30-shared-svc/raginference",
        "41-macrorag/app",
    ):
        assert expected in keys


def test_ignores_terragrunt_cache(model: Model) -> None:
    assert not any(".terragrunt-cache" in c.key for c in model.components)


def test_module_source_is_detected(model: Model) -> None:
    by_key = {c.key: c for c in model.components}
    assert by_key["41-macrorag/app"].module == "compute/ec2-app"
    assert by_key["10-security/kms"].module == "security/kms"
    assert by_key["20-data/macrorag-corpus"].module == "data/s3"
    assert by_key["30-shared-svc/raginference"].module == "compute/ecs-service"


def test_dependency_edges_resolve_to_component_keys(model: Model) -> None:
    app = next(c for c in model.components if c.key == "41-macrorag/app")
    # The app instance depends on its foundation, by resolved component key.
    for dep in ("00-networking/subnets", "10-security/kms", "20-data/macrorag-corpus"):
        assert dep in app.deps
    # A dependency the app does NOT declare must not appear (it reaches qdrant at
    # runtime via Cloud Map, not through a Terragrunt dependency).
    assert "30-shared-svc/qdrant" not in app.deps


def test_tier_and_name_are_split(model: Model) -> None:
    app = next(c for c in model.components if c.key == "41-macrorag/app")
    assert app.tier == "41-macrorag"
    assert app.name == "app"


def test_every_used_module_has_an_icon(model: Model) -> None:
    """A new module type must be added to the icon registry, not silently fall back."""
    used = {c.module for c in model.components if c.module}
    unmapped = used - set(MODULE_ICON)
    assert not unmapped, f"modules with no icon in icons.MODULE_ICON: {sorted(unmapped)}"


def test_every_component_has_a_module(model: Model) -> None:
    """Every dev component instantiates a module; a None means the parse missed it."""
    missing = [c.key for c in model.components if c.module is None]
    assert not missing, f"components with no detected module source: {missing}"


def test_transitive_reduction_drops_implied_edges(model: Model) -> None:
    reduced = transitive_reduction(model)
    app = reduced["41-macrorag/app"]
    # app depends on secrets/ecr/corpus, which each depend on kms, so the direct
    # app -> kms edge is implied and must be removed.
    assert "10-security/kms" not in app
    # ...but its direct, non-implied dependencies stay.
    assert "10-security/secrets" in app
    assert "20-data/macrorag-corpus" in app


def test_transitive_reduction_preserves_reachability(model: Model) -> None:
    """The reduction removes edges but not who-depends-on-what transitively."""
    reduced = transitive_reduction(model)

    def reachable(edges: dict[str, tuple[str, ...]], start: str) -> set[str]:
        seen: set[str] = set()
        stack = list(edges.get(start, ()))
        while stack:
            node = stack.pop()
            if node not in seen:
                seen.add(node)
                stack.extend(edges.get(node, ()))
        return seen

    full = {c.key: c.deps for c in model.components}
    for c in model.components:
        assert reachable(reduced, c.key) == reachable(full, c.key)


def test_runtime_calls_parsed_from_inputs(model: Model) -> None:
    app = next(c for c in model.components if c.key == "41-macrorag/app")
    calls = {(c.host, c.scheme, c.port, c.target) for c in app.calls}
    assert ("qdrant", "https", 6333, "30-shared-svc/qdrant") in calls
    assert ("raginference", "http", 8799, "30-shared-svc/raginference") in calls
    # The raginference container health-check hits http://127.0.0.1 — not a call.
    rag = next(c for c in model.components if c.key == "30-shared-svc/raginference")
    assert all(c.host != "127" for c in rag.calls)


def test_host_port_env_group_is_a_call(model: Model) -> None:
    """XbrlRag configures Qdrant as QDRANT_HOST/_PORT/_HTTPS, not as one URL.

    Reading only the URL idiom made both XbrlRag tiers look like they never touched
    Qdrant at all, so the connection must be derived from the env-var group too.
    """
    for key in ("42-arag/app", "42-arag/ingest"):
        comp = next(c for c in model.components if c.key == key)
        call = next(c for c in comp.calls if c.target == "30-shared-svc/qdrant")
        assert (call.scheme, call.port, call.tls) == ("https", 6333, True)


def test_db_call_resolved_through_a_dependency_output(model: Model) -> None:
    """XBRL_DB_HOST is `dependency.db.outputs.address` — no literal host to parse.

    The target comes from the dependency block itself and the port from its
    declared mock_outputs, so XbrlRag's database link is drawn without touching AWS.
    """
    app = next(c for c in model.components if c.key == "42-arag/app")
    call = next(c for c in app.calls if c.target == "42-arag/db")
    assert (call.scheme, call.port, call.tls) == ("postgres", 5432, True)


def test_discovery_name_resolves_a_caller_to_the_component(model: Model) -> None:
    """A caller uses the Cloud Map name (`app_name`), never the folder name."""
    qlp = next(c for c in model.components if c.key == "40-quantlibpricer/app")
    targets = {c.host: c.target for c in qlp.calls}
    assert targets["arag"] == "42-arag/app"
    assert targets["macrorag"] == "41-macrorag/app"


def test_s3_access_level_distinguishes_read_only(model: Model) -> None:
    """A read-only grant must not be drawn as read/write.

    The XbrlRag app's query path is filesystem-free; its only S3 need is pulling the
    deploy bundle (`bundle_read_bucket_arn`). The ingest runner really does write.
    """
    app = next(c for c in model.components if c.key == "42-arag/app")
    ingest = next(c for c in model.components if c.key == "42-arag/ingest")
    assert dict(app.s3_access)["20-data/arag-filings"] == "data read-only"
    assert dict(ingest.s3_access)["20-data/arag-filings"] == "data r/w"


def test_security_edges(model: Model) -> None:
    edges = {(e.src, e.dst, e.kind) for e in security_edges(model)}
    # KMS encrypts the secrets store and the corpus bucket (at rest).
    assert ("10-security/kms", "10-security/secrets", "encrypt") in edges
    assert ("10-security/kms", "20-data/macrorag-corpus", "encrypt") in edges
    # ...and the XbrlRag database, which is a data store like any other.
    assert ("10-security/kms", "42-arag/db", "encrypt") in edges
    # The app reads its secret, and talks to qdrant over TLS (in transit).
    assert ("41-macrorag/app", "10-security/secrets", "secret") in edges
    assert ("41-macrorag/app", "30-shared-svc/qdrant", "tls") in edges
    # XbrlRag's two TLS legs: the shared vector store and its own database.
    assert ("42-arag/app", "30-shared-svc/qdrant", "tls") in edges
    assert ("42-arag/app", "42-arag/db", "tls") in edges
    # KMS "encrypts" is limited to data stores + workloads; schedulers and NAT
    # (which touch KMS only for a scheduler role / EBS) are not drawn.
    assert ("10-security/kms", "00-networking/nat", "encrypt") not in edges
    assert ("10-security/kms", "30-shared-svc/qdrant-schedule", "encrypt") not in edges


def test_dataflow_edges(model: Model) -> None:
    edges = {(e.src, e.dst, e.kind) for e in dataflow_edges(model)}
    assert ("41-macrorag/app", "30-shared-svc/qdrant", "call") in edges
    assert ("41-macrorag/app", "30-shared-svc/raginference", "call") in edges
    assert ("41-macrorag/app", "20-data/macrorag-corpus", "s3") in edges
    assert ("30-shared-svc/raginference", "20-data/raginference-weights", "s3") in edges
    # XbrlRag's own two legs: facts in RDS, vectors in the shared Qdrant.
    assert ("42-arag/app", "42-arag/db", "call") in edges
    assert ("42-arag/ingest", "30-shared-svc/qdrant", "call") in edges
    # Only workloads move data to buckets; the VPC's flow-log delivery to the
    # logs bucket is infra plumbing, not app data-flow, so it is not drawn.
    assert ("00-networking/vpc", "20-data/logs-bucket", "s3") not in edges


def test_ingress_mode_read_from_env() -> None:
    assert read_ingress_mode(DEV_DIR) == "ssm"


def test_switched_off_alb_is_not_in_the_model(model: Model) -> None:
    keys = {c.key for c in model.components}
    assert (DEV_DIR / "30-shared-svc" / "alb" / "terragrunt.hcl").exists()
    assert "30-shared-svc/alb" not in keys
    assert not any("30-shared-svc/alb" in c.deps for c in model.components)


@pytest.mark.parametrize(("mode", "drawn"), [("alb", True), ("ssm", False)])
def test_ingress_switch_decides_whether_the_component_exists(
    tmp_path: Path, mode: str, drawn: bool
) -> None:
    (tmp_path / "env.hcl").write_text(f'locals {{\n  ingress_mode = "{mode}"\n}}\n')
    component = tmp_path / "30-shared-svc" / "alb"
    component.mkdir(parents=True)
    source = (DEV_DIR / "30-shared-svc" / "alb" / "terragrunt.hcl").read_text(encoding="utf-8")
    (component / "terragrunt.hcl").write_text(source, encoding="utf-8")

    keys = {c.key for c in derive_model(tmp_path, "dev").components}

    assert ("30-shared-svc/alb" in keys) is drawn


def test_tier_labels_use_current_app_names() -> None:
    assert TIER_LABEL["40-quantlibpricer"] == "Faultline"
    assert TIER_LABEL["42-arag"] == "XbrlRag"
