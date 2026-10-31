# Design docs

Start with **[`design-decisions.md`](design-decisions.md)** — the holistic record of
*what* was decided and *why* (cost, architectural simplicity, workload/data-volume
fit). It links into the deep-dive docs below for the full numbers; each is one doc per
feature area.

**Written:**

- `design-decisions.md` — the cross-cutting decision register spanning the whole
  platform (platform, identity, networking, ingress, compute, data, cost, and the
  control-plane maturity). The single home for rationale that would otherwise be
  restated across docs.
- `aws-service-consolidation.md` — the service inventory and cost decisions across
  the four sibling subsystems; the source for the module list and rollout order.
- `qdrant-cloud-vs-self-hosted.md` — the analysis behind the "Shared Qdrant on one
  EC2" decision (§2 of the consolidation doc): measured workload, Cloud-vs-self-host
  cost + complexity, and why self-host wins at this scale.
- `arag-rollout-plan.md` — the XbrlRag subsystem rollout (`42-arag`): how its application
  design reconciles with this repo's shared-services and ingress decisions, and the
  chunk-by-chunk plan (A1–A8).
- `quantlibpricer-rollout-plan.md` — the Faultline subsystem rollout
  (`40-quantlibpricer`): the same reconciliation, the app-to-app reachability piece it
  introduces, and the chunk-by-chunk plan (Q1–Q6).
- `park-mode.md` — how the estate is held at near-zero cost between demos without
  re-provisioning: how the spend was actually measured (Cost Explorer reports $0 on a
  credited account), why the three tiers park by different mechanisms, and the RDS
  seven-day force-start that makes the obvious approach wrong.

**Planned** (none of these exist yet — do not link to them until they do):

- `provisioning.md` — plan/apply orchestration, drift detection.
- `deployment.md` — release workflow, env promotion, rollback.
- `monitoring.md` — CloudWatch metrics, health model, alarms.
- `costing.md` — Infracost pre-apply estimates + Cost Explorer/CUR post-apply reporting.
- `pipeline.md` — how CLI stages emit `PipelineRun` state consumed by the UI.
