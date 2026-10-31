#!/usr/bin/env python
"""Render AWS-style architecture diagrams of an environment, from multiple views.

All three views are AUTO-DERIVED from the Terragrunt HCL (offline; no AWS) via
src/iac/diagrams/derive.py, so they cannot silently drift from the infra. Each is
its own file so a reader is not overwhelmed by every edge at once:

    overall    every component (icon per module) + the dependency edges between
               them, transitively reduced so only direct dependencies are drawn.
    security   encryption at rest (KMS dep -> "encrypts"), in transit (https
               call -> "TLS"), secret access (secrets dep), and no public ingress
               (env `ingress_mode = "ssm"`).
    dataflow   runtime service calls (from inputs URLs, e.g. MACRORAG_QDRANT_URL)
               + object-store access (data/s3 deps), plus the SSM ingress.

Uses the `diagrams` library (mingrammer) + Graphviz to draw with the official AWS
icon set and the right-angle (ortho) AWS reference-architecture look.

Requires Graphviz (`dot`) on PATH. Install into py312:
    conda install -n py312 -c conda-forge graphviz && pip install diagrams python-hcl2

Run (writes docs/diagrams/<subdir>/<env>-<view>.{png,svg}; contacts no AWS):
    conda run -n py312 python scripts/gen_diagrams.py --env dev --view all
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import diagrams
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.general import User
from diagrams.aws.management import SystemsManager

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "docs" / "diagrams"

# The pure derivation logic lives in the importable iac package (src/ is on the
# pytest path but not the script path, so add it here).
sys.path.insert(0, str(REPO_ROOT / "src"))
from iac.diagrams.derive import (  # noqa: E402
    Component,
    DerivedEdge,
    dataflow_edges,
    derive_model,
    read_ingress_mode,
    security_edges,
    transitive_reduction,
)
from iac.diagrams.icons import TIER_LABEL, icon_for  # noqa: E402

# Shrink every icon a little (default 1.9 -> 1.7). It is a class attribute the AWS
# nodes inherit, so this is the one global lever for icon size. Going much smaller
# makes the label collide with the icon inside the fixed-size node box.
diagrams.Node._height = 1.7

VIEWS = ("overall", "security", "dataflow")

# EC2-hosted components an operator reaches over an SSM session (Fargate uses ECS
# Exec, not a host session), used to derive the "no public ingress" edges.
_SSM_HOSTS = {"compute/ec2-app", "compute/ingest-runner", "data/qdrant"}

# Right-angle (ortho) AWS look. Clutter is cut structurally, not by softening
# lines: transitive reduction (overall), `concentrate` to merge shared edge runs,
# LR layering (foundation -> apps), and wide rank separation. dpi 72 = 75% size.
GRAPH_ATTR = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.75",
    "nodesep": "0.7",
    "ranksep": "1.8",
    "dpi": "72",
    "splines": "ortho",
    "concentrate": "true",
}
NODE_ATTR = {"fontsize": "13"}

DEPENDS = Edge(color="gray65", penwidth="1.1", arrowsize="0.7")  # dependency (overall)

# Semantic edge styles for the security / data-flow views, keyed by DerivedEdge.kind.
_EDGE_STYLE = {
    "encrypt": {"color": "gray50", "style": "dashed"},
    "secret": {"color": "black"},
    "tls": {"color": "darkgreen", "style": "bold"},
    "call": {"color": "darkgreen", "style": "bold"},
    "s3": {"color": "black"},
}

# every view is generated; the folder makes that explicit next to any future
# hand-authored diagrams under curated/.
_SUBDIR = {"overall": "auto-derived", "security": "auto-derived", "dataflow": "auto-derived"}
_FILE = {"overall": "architecture", "security": "security", "dataflow": "dataflow"}
_TITLE = {
    "overall": "architecture (overall)",
    "security": "security view",
    "dataflow": "data-flow view",
}


def _render_png(diagram: Diagram, out_base: str) -> None:
    """Render the PNG via the gd device.

    conda-forge Graphviz on Windows routes -Tpng through cairo, which segfaults /
    writes 0 bytes here. Of the working devices only `gd` embeds the node icon
    images (gdiplus drops them, leaving text-only nodes) — and diagrams never lets
    us pass a renderer, so we drive the PNG ourselves. `outfile` pins the name,
    else graphviz injects the renderer into it (dev-architecture.gd.png).
    """
    diagram.dot.render(outfile=f"{out_base}.png", renderer="gd", cleanup=True, quiet=True)


def _diagram(env: str, view: str, subtitle: str) -> tuple[Diagram, str]:
    prefix = f"genai-{env}"
    out_dir = OUT_DIR / _SUBDIR[view]
    out_dir.mkdir(parents=True, exist_ok=True)
    out_base = str(out_dir / f"{env}-{_FILE[view]}")
    diagram = Diagram(
        f"aws-genai-iac - {env} {_TITLE[view]} ({prefix})  |  {subtitle}",
        filename=out_base,
        outformat="svg",
        show=False,
        direction="LR",  # foundation -> apps; crosses less than top-down here
        graph_attr=GRAPH_ATTR,
        node_attr=NODE_ATTR,
    )
    return diagram, out_base


def _clustered_nodes(keys: set[str], comp: dict[str, Component]) -> dict[str, object]:
    """Create a node per key, grouped into a cluster per tier (numeric order)."""
    by_tier: dict[str, list[str]] = {}
    for key in keys:
        by_tier.setdefault(comp[key].tier, []).append(key)
    nodes: dict[str, object] = {}
    for tier in sorted(by_tier):
        with Cluster(TIER_LABEL.get(tier, tier)):
            for key in sorted(by_tier[tier]):
                nodes[key] = icon_for(comp[key].module)(comp[key].name)
    return nodes


def _add_ingress(
    env: str, view: str, env_dir: Path, nodes: dict[str, object], comp: dict[str, Component]
) -> None:
    """Derived ingress: with `ingress_mode = ssm`, reach EC2 hosts over an SSM tunnel."""
    if read_ingress_mode(env_dir) != "ssm":
        return
    hosts = [k for k in nodes if comp[k].module in _SSM_HOSTS]
    if not hosts:
        return
    operator = User(f"Operator\n(laptop, {env})")
    ssm = SystemsManager("SSM Session Manager")
    label = "SSM only\n(no public ingress)" if view == "security" else "SSM tunnel"
    operator >> Edge(color="darkgreen", style="dashed", label=label) >> ssm
    for key in hosts:
        ssm >> Edge(color="darkgreen", style="dashed") >> nodes[key]


def _build_overall(env: str) -> None:
    model = derive_model(REPO_ROOT / "infra" / "environments" / env, env)
    reduced = transitive_reduction(model)  # drop transitively-implied edges
    comp = {c.key: c for c in model.components}
    diagram, out_base = _diagram(
        env, "overall", "auto-derived from the Terragrunt dependency graph (transitively reduced)"
    )
    with diagram:
        nodes = _clustered_nodes(set(comp), comp)
        # Dependency edges (reduced): dep -> dependent (foundation flows to apps).
        for c in model.components:
            for dep in reduced[c.key]:
                if dep in nodes:
                    nodes[dep] >> DEPENDS >> nodes[c.key]
    _render_png(diagram, out_base)


def _build_semantic(env: str, view: str) -> None:
    env_dir = REPO_ROOT / "infra" / "environments" / env
    model = derive_model(env_dir, env)
    comp = {c.key: c for c in model.components}
    edges: list[DerivedEdge] = (
        security_edges(model) if view == "security" else dataflow_edges(model)
    )
    node_keys = {e.src for e in edges} | {e.dst for e in edges}

    diagram, out_base = _diagram(env, view, "auto-derived from the Terragrunt HCL")
    with diagram:
        nodes = _clustered_nodes(node_keys, comp)
        _add_ingress(env, view, env_dir, nodes, comp)
        for e in edges:
            if e.src in nodes and e.dst in nodes:
                nodes[e.src] >> Edge(label=e.label, **_EDGE_STYLE.get(e.kind, {})) >> nodes[e.dst]
    _render_png(diagram, out_base)


def build(env: str, view: str) -> None:
    if view == "overall":
        _build_overall(env)
    else:
        _build_semantic(env, view)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", default="dev", help="Environment to render (default: dev).")
    parser.add_argument(
        "--view",
        default="all",
        choices=[*VIEWS, "all"],
        help="Which perspective to render, or 'all' (default).",
    )
    args = parser.parse_args(argv)

    views = VIEWS if args.view == "all" else (args.view,)
    for view in views:
        build(args.env, view)
        print(f"Wrote {OUT_DIR / _SUBDIR[view] / f'{args.env}-{_FILE[view]}'}.png / .svg")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
