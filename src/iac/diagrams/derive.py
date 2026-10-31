"""Derive an architecture model from the Terragrunt HCL (offline; no AWS).

Parses ``infra/environments/<env>/**/terragrunt.hcl`` into a :class:`Model` of the
components (nodes), the module each instantiates (-> diagram icon), the dependency
edges between them, and the runtime service calls declared in each component's
``inputs``. From those it produces the edge sets for three views — see
:func:`transitive_reduction` (overall), :func:`security_edges`, and
:func:`dataflow_edges` — so every diagram is generated from the infra and cannot
silently drift from it.

A connection is written two ways in this estate, and both are parsed, because
reading only one made the views silently omit whole subsystems:

* one URL — ``MACRORAG_QDRANT_URL = "https://qdrant.<ns>.internal:6333"``;
* a ``<PREFIX>_HOST``/``_PORT``/``_HTTPS``/``_SSLMODE`` group — XbrlRag's idiom for
  both Qdrant and its database, where the host is often not a literal at all but
  ``dependency.db.outputs.address``. Such a reference is resolved through the
  dependency block's ``mock_outputs``, the one place the HCL states the value
  offline, and it names its target component directly.

Pure parsing: depends only on ``hcl2`` + the stdlib (no ``diagrams``/Graphviz), so
it is cheap to unit-test against the real ``dev`` tree.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from hcl2.api import load as load_hcl

# Module path as written in `terraform { source = ".../infra/modules/<cat>/<name>" }`.
#
# `/+` tolerates Terragrunt's `//` subdir marker (".../infra/modules//compute/
# ec2-app"), which components using a module that calls a SIBLING module must
# use so Terragrunt copies the whole `modules` tree. Anchoring the capture to an
# alphanumeric stops the second slash being captured as a leading "/" and
# yielding "/compute/ec2-app", which then matches no icon and no dataflow rule.
_MODULE_RE = re.compile(r"modules/+([a-z0-9][a-z0-9/_-]*)")
# A service URL in an input value: scheme + host label (must start with a letter,
# so `http://127.0.0.1` healthchecks are skipped). Port picked up separately, since
# a `${...}` interpolation usually sits between the host and the `:port`.
_URL_RE = re.compile(r"(https?)://([a-z][a-z0-9-]*)")
_PORT_RE = re.compile(r":(\d+)")
# A reference to another component's output, e.g. `dependency.db.outputs.address`.
_DEP_OUTPUT_RE = re.compile(r"dependency\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_]+)")
_CACHE_DIR = ".terragrunt-cache"

# The second connection idiom: not one URL but a `<PREFIX>_HOST` / `_PORT` /
# `_HTTPS` / `_SSLMODE` group of env vars (XbrlRag configures both Qdrant and its
# database this way, MacroRAG uses a URL). Parsed so a connection is drawn
# whichever idiom the app happens to use.
_HOST_SUFFIX = "_HOST"
# libpq sslmode values that actually encrypt. `prefer` does not: it silently
# falls back to plaintext, so it is NOT treated as TLS.
_TLS_SSLMODES = {"require", "verify-ca", "verify-full"}

# A module input that grants a workload access to a bucket. The name says at what
# level: one with `read` in it is read-only (`bundle_read_bucket_arn` pulls only a
# deploy bundle, `task_read_bucket_arns` only model weights); anything else is r/w.
_BUCKET_ARN_RE = re.compile(r"bucket_arns?$")
_S3_READ = "data read-only"
_S3_RW = "data r/w"

# module -> semantic meaning of a dependency on it, for the security/data-flow views.
_KMS = "security/kms"
_SECRETS = "security/secrets"
_S3 = "data/s3"

_RDS = "data/rds"
# Workloads that run and move data (sources of runtime data-flow / stateful, so
# their volumes are the meaningful encryption-at-rest targets).
_WORKLOAD_MODULES = {
    "compute/ec2-app",
    "compute/ecs-service",
    "compute/ingest-runner",
    "data/qdrant",
}
# What "encrypts" edges point at: data stores + stateful workloads. Excludes
# schedulers and NAT (they touch KMS only for a scheduler role / EBS), which would
# turn the security view into a KMS-encrypts-everything fan with no added insight.
_ENCRYPTABLE = {_S3, _SECRETS, _RDS, "registry/ecr"} | _WORKLOAD_MODULES


@dataclass(frozen=True)
class Call:
    """A runtime service call declared in a component's inputs.

    Either from a URL (``RAGINFER_URL = "http://raginference...:8799"``) or from a
    ``<PREFIX>_HOST``/``_PORT``/``_HTTPS``/``_SSLMODE`` env-var group.
    """

    target: str | None  # component key the host resolves to, or None if external
    host: str  # first DNS label of the host, e.g. "qdrant"
    scheme: str  # "http" | "https" | "postgres" | "tcp"
    port: int | None
    tls: bool  # encrypted in transit (https, or an sslmode that really encrypts)


@dataclass(frozen=True)
class Component:
    """One environment component (a folder holding a ``terragrunt.hcl``)."""

    key: str  # env-relative POSIX path, e.g. "10-security/kms"
    tier: str  # first path segment, e.g. "10-security"
    name: str  # leaf dir, e.g. "kms" (or "app" under 41-macrorag)
    module: str | None  # e.g. "security/kms"; None if no module source found
    deps: tuple[str, ...]  # component keys this depends on (from dependency blocks)
    calls: tuple[Call, ...]  # runtime service calls (from inputs URLs)
    s3_access: tuple[tuple[str, str], ...]  # (bucket component key, access label)


@dataclass(frozen=True)
class Model:
    env: str
    components: tuple[Component, ...]


@dataclass(frozen=True)
class DerivedEdge:
    """A semantic edge for the security / data-flow views."""

    src: str  # component key
    dst: str  # component key
    label: str
    kind: str  # "encrypt" | "secret" | "tls" | "call" | "s3"


def _unquote(value: str) -> str:
    """python-hcl2 preserves the source quotes; strip a single surrounding pair."""
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def _module_of(data: dict[str, Any]) -> str | None:
    for block in data.get("terraform", []):
        source = block.get("source")
        if source:
            match = _MODULE_RE.search(_unquote(source))
            if match:
                return match.group(1)
    return None


def _dep_refs(
    comp_dir: Path, env_dir: Path, data: dict[str, Any]
) -> dict[str, tuple[str, dict[str, Any]]]:
    """`dependency` label -> (component key it points at, its `mock_outputs`).

    The mocks are kept because they are the only place the HCL states, offline,
    what an output *is* — so a `${dependency.db.outputs.port}` in an input can be
    resolved to 5432 without touching AWS or Terraform state.
    """
    env_root = env_dir.resolve()
    refs: dict[str, tuple[str, dict[str, Any]]] = {}
    for item in data.get("dependency", []):
        for label, body in item.items():
            if label.startswith("__") or not isinstance(body, dict):
                continue  # skip hcl2 metadata keys (__is_block__, __comments__)
            cfg = body.get("config_path")
            if not cfg:
                continue
            target = (comp_dir / _unquote(cfg)).resolve()
            try:
                key = target.relative_to(env_root).as_posix()
            except ValueError:
                # Dependency outside this env tree: keep the leaf name so the edge
                # is recorded rather than silently dropped.
                key = target.name
            mocks = body.get("mock_outputs")
            # hcl2 keeps the source quotes on the block label, but an input refers
            # to it bare (`dependency.db.outputs.address`) — strip them so the two
            # sides match.
            refs.setdefault(_unquote(label), (key, mocks if isinstance(mocks, dict) else {}))
    return refs


def _deps_of(refs: dict[str, tuple[str, dict[str, Any]]]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(key for key, _ in refs.values()))  # dedupe, keep order


def _walk_strings(obj: Any) -> list[str]:
    """All string leaves in a parsed inputs structure (dicts/lists/scalars)."""
    out: list[str] = []
    if isinstance(obj, str):
        out.append(obj)
    elif isinstance(obj, dict):
        for k, v in obj.items():
            if not (isinstance(k, str) and k.startswith("__")):
                out.extend(_walk_strings(v))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(_walk_strings(v))
    return out


def _walk_dicts(obj: Any) -> list[dict[str, Any]]:
    """Every mapping in a parsed inputs structure, outermost first."""
    out: list[dict[str, Any]] = []
    if isinstance(obj, dict):
        out.append(obj)
        for k, v in obj.items():
            if not (isinstance(k, str) and k.startswith("__")):
                out.extend(_walk_dicts(v))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(_walk_dicts(v))
    return out


def _resolve(value: Any, refs: dict[str, tuple[str, dict[str, Any]]]) -> tuple[Any, str | None]:
    """An input value as (literal, component key it was read from).

    A plain literal resolves to itself with no component. A
    ``${dependency.<label>.outputs.<attr>}`` reference resolves to the value that
    dependency block declares for ``<attr>`` in its ``mock_outputs``, plus the key
    of the component the reference points at.
    """
    if not isinstance(value, str):
        return value, None
    match = _DEP_OUTPUT_RE.search(value)
    if not match:
        return _unquote(value), None
    key, mocks = refs.get(match.group(1), (None, {}))
    resolved = mocks.get(match.group(2))
    return (_unquote(resolved) if isinstance(resolved, str) else resolved), key


def _as_port(value: Any) -> int | None:
    text = str(value).strip('"') if value is not None else ""
    return int(text) if text.isdigit() else None


def _url_calls(data: dict[str, Any], name_to_key: dict[str, str]) -> list[Call]:
    """Connections written as one URL, e.g. `RAGINFER_URL = "http://...:8799"`."""
    calls: list[Call] = []
    for value in _walk_strings(data.get("inputs", {})):
        match = _URL_RE.search(value)
        if not match:
            continue
        scheme, host = match.group(1), match.group(2)
        if host == "localhost":
            continue
        ports = _PORT_RE.findall(value)
        port = int(ports[-1]) if ports else None
        calls.append(
            Call(
                target=name_to_key.get(host),
                host=host,
                scheme=scheme,
                port=port,
                tls=scheme == "https",
            )
        )
    return calls


def _host_group_calls(
    data: dict[str, Any],
    name_to_key: dict[str, str],
    refs: dict[str, tuple[str, dict[str, Any]]],
) -> list[Call]:
    """Connections written as a `<PREFIX>_HOST` / `_PORT` / `_HTTPS` / `_SSLMODE` group.

    The host is either a literal DNS name (``QDRANT_HOST = "qdrant.<ns>.internal"``)
    or another component's output (``XBRL_DB_HOST = dependency.db.outputs.address``);
    the latter names its target directly, no DNS-label lookup needed.
    """
    calls: list[Call] = []
    for mapping in _walk_dicts(data.get("inputs", {})):
        for key in mapping:
            if not (isinstance(key, str) and key.endswith(_HOST_SUFFIX)):
                continue
            prefix = key[: -len(_HOST_SUFFIX)]
            value, dep_key = _resolve(mapping[key], refs)
            if not isinstance(value, str) or not value:
                continue
            host = value.split(".")[0]
            # Same rule as the URL form: a real DNS label, not an IP or loopback.
            if not host or not host[0].isalpha() or host == "localhost":
                continue
            port = _as_port(_resolve(mapping.get(f"{prefix}_PORT"), refs)[0])
            sslmode = _resolve(mapping.get(f"{prefix}_SSLMODE"), refs)[0]
            https = str(_resolve(mapping.get(f"{prefix}_HTTPS"), refs)[0]).lower() == "true"
            if sslmode is not None:
                # `sslmode` is libpq's: this is a Postgres connection.
                scheme, tls = "postgres", str(sslmode).lower() in _TLS_SSLMODES
            elif f"{prefix}_HTTPS" in mapping:
                scheme, tls = ("https", True) if https else ("http", False)
            else:
                # Nothing in the HCL says what rides this connection — do not guess.
                scheme, tls = "tcp", False
            calls.append(
                Call(
                    target=dep_key or name_to_key.get(host),
                    host=host,
                    scheme=scheme,
                    port=port,
                    tls=tls,
                )
            )
    return calls


def _calls_of(
    data: dict[str, Any],
    name_to_key: dict[str, str],
    refs: dict[str, tuple[str, dict[str, Any]]],
) -> tuple[Call, ...]:
    calls = _url_calls(data, name_to_key) + _host_group_calls(data, name_to_key, refs)
    return tuple(dict.fromkeys(calls))


def _s3_access_of(data: dict[str, Any], refs: _DepRefs) -> tuple[tuple[str, str], ...]:
    """Bucket component -> the access level this component is granted on it.

    Read-only is drawn as such so the views do not overstate a workload's reach:
    the XbrlRag app only *pulls its deploy bundle* from the filings bucket (the query
    path is filesystem-free), while the ingest runner really does write to it.
    """
    inputs = data.get("inputs", {})
    if not isinstance(inputs, dict):
        return ()
    access: dict[str, str] = {}
    for key, value in inputs.items():
        if not (isinstance(key, str) and _BUCKET_ARN_RE.search(key)):
            continue
        level = _S3_READ if "read" in key.lower() else _S3_RW
        for text in _walk_strings(value):
            _, dep_key = _resolve(text, refs)
            # r/w wins if the same bucket is reached through two grants.
            if dep_key and access.get(dep_key) != _S3_RW:
                access[dep_key] = level
    return tuple(sorted(access.items()))


def read_ingress_mode(env_dir: Path | str) -> str | None:
    """The env's `ingress_mode` local ("alb"|"ssm"), or None if not set."""
    env_hcl = Path(env_dir) / "env.hcl"
    if not env_hcl.exists():
        return None
    with env_hcl.open(encoding="utf-8") as fp:
        data = load_hcl(fp)
    for block in data.get("locals", []):
        if isinstance(block, dict) and "ingress_mode" in block:
            return _unquote(block["ingress_mode"])
    return None


def _exists_under(data: dict[str, Any], ingress_mode: str | None) -> bool:
    """False for a component whose `enabled` input turns it off in this ingress mode.

    The folder stays when a mode is switched off, so the folder alone would draw
    resources that do not exist (the ALB under `ingress_mode = "ssm"`).
    """
    inputs = data.get("inputs", {})
    enabled = inputs.get("enabled") if isinstance(inputs, dict) else None
    if not isinstance(enabled, str) or "ingress_mode" not in enabled:
        return True
    return f'"{ingress_mode}"' in enabled.replace('\\"', '"')


# One parsed component, before it becomes a Component: key, tier, name, module,
# dependency refs (label -> key + mocks), and the raw parsed HCL.
_DepRefs = dict[str, tuple[str, dict[str, Any]]]
_RawEntry = tuple[str, str, str, str | None, _DepRefs, dict[str, Any]]


def _discovery_names(raw: list[_RawEntry]) -> dict[str, str]:
    """DNS label a caller uses -> component key.

    A caller reaches a service by its Cloud Map name, and the modules derive that
    name from `app_name` (`discovery_name = discovery_service_name != "" ?
    discovery_service_name : app_name`) — so `arag.genai-dev.internal` resolves to
    `42-arag/app`, which the folder name ("app", and not unique) never could.
    Folder names stay as the fallback for components that register no service.
    """
    names = {entry[2]: entry[0] for entry in raw}  # leaf dir name -> key
    for entry in raw:
        inputs = entry[5].get("inputs", {})
        if not isinstance(inputs, dict):
            continue
        for field in ("discovery_service_name", "app_name"):
            value = inputs.get(field)
            if isinstance(value, str) and (name := _unquote(value)):
                names[name] = entry[0]
                break
    return names


def derive_model(env_dir: Path | str, env: str) -> Model:
    """Parse every component under ``env_dir`` into a :class:`Model`."""
    env_dir = Path(env_dir)
    ingress_mode = read_ingress_mode(env_dir)
    raw: list[_RawEntry] = []
    for tg in sorted(env_dir.rglob("terragrunt.hcl")):
        if _CACHE_DIR in tg.parts:
            continue  # ignore the generated .terragrunt-cache copies
        comp_dir = tg.parent
        key = comp_dir.relative_to(env_dir).as_posix()
        with tg.open(encoding="utf-8") as fp:
            data = load_hcl(fp)
        if not _exists_under(data, ingress_mode):
            continue
        raw.append(
            (
                key,
                key.split("/")[0],
                key.split("/")[-1],
                _module_of(data),
                _dep_refs(comp_dir, env_dir, data),
                data,
            )
        )

    name_to_key = _discovery_names(raw)
    components = tuple(
        Component(
            key=key,
            tier=tier,
            name=name,
            module=module,
            deps=_deps_of(refs),
            calls=_calls_of(data, name_to_key, refs),
            s3_access=_s3_access_of(data, refs),
        )
        for key, tier, name, module, refs, data in raw
    )
    return Model(env=env, components=components)


def transitive_reduction(model: Model) -> dict[str, tuple[str, ...]]:
    """Each component's deps with transitively-implied edges removed.

    An edge ``u -> v`` is dropped when ``v`` is already reachable from ``u`` via
    another of ``u``'s dependencies (``u -> w -> ... -> v``). This keeps only the
    direct, non-redundant edges so the overall diagram is readable — e.g. an app
    that depends on both ``secrets`` and ``kms`` loses its direct ``kms`` edge,
    because ``secrets`` already pulls ``kms`` in. The DAG's reachability (what
    depends on what, transitively) is unchanged.
    """
    edges = {c.key: set(c.deps) for c in model.components}

    def reachable(start: str) -> set[str]:
        seen: set[str] = set()
        stack = list(edges.get(start, ()))
        while stack:
            node = stack.pop()
            if node in seen:
                continue
            seen.add(node)
            stack.extend(edges.get(node, ()))
        return seen

    reduced: dict[str, tuple[str, ...]] = {}
    for u, vs in edges.items():
        keep = [v for v in vs if not any(w != v and v in reachable(w) for w in vs)]
        reduced[u] = tuple(sorted(keep))
    return reduced


def security_edges(model: Model) -> list[DerivedEdge]:
    """Security-relevant edges: encryption at rest / in transit + secret access."""
    module = {c.key: c.module for c in model.components}
    edges: list[DerivedEdge] = []
    for c in model.components:
        for dep in c.deps:
            if module.get(dep) == _KMS and c.module in _ENCRYPTABLE:
                edges.append(DerivedEdge(dep, c.key, "encrypts", "encrypt"))  # kms -> c
            elif module.get(dep) == _SECRETS:
                edges.append(DerivedEdge(c.key, dep, "reads secret", "secret"))
        for call in c.calls:
            if call.target and call.tls:
                label = f"TLS :{call.port}" if call.port else "TLS"
                edges.append(DerivedEdge(c.key, call.target, label, "tls"))
    return edges


def dataflow_edges(model: Model) -> list[DerivedEdge]:
    """Runtime data movement: service-to-service calls + object-store access."""
    module = {c.key: c.module for c in model.components}
    edges: list[DerivedEdge] = []
    for c in model.components:
        for call in c.calls:
            if call.target:
                label = f"{call.scheme} :{call.port}" if call.port else call.scheme
                edges.append(DerivedEdge(c.key, call.target, label, "call"))
        access = dict(c.s3_access)
        for dep in c.deps:
            if module.get(dep) == _S3 and c.module in _WORKLOAD_MODULES:
                edges.append(DerivedEdge(c.key, dep, access.get(dep, _S3_RW), "s3"))
    return edges
