# Qdrant: Cloud vs. Self-Hosted on EC2

Status: **approved — self-host on EC2** (platform decision 2026-07-21); **instance
type & placement now decided 2026-07-23** — dedicated `t4g.small` in `30-shared-svc`,
us-east-1a (§6a). Scope: where the shared vector store runs.
Formalizes and reinforces the "Shared Qdrant on one EC2" line already assumed in
[`aws-service-consolidation.md`](aws-service-consolidation.md) §2 — that row was an
assertion; this doc is the analysis behind it.

## 1. Headline finding

**Decision: self-host Qdrant on EC2. Do not use Qdrant Cloud managed SaaS.** At our
scale the two cheapest options are *both* near-free (Qdrant Cloud's perpetual free
tier is $0; a co-located self-hosted container is ~$2/mo marginal), so **dollars do
not decide it** — data-residency and network topology do, and both favor self-host.
Managed SaaS only starts earning its ~$30–60/mo at ~15–20× the current corpus.

**Now decided (§6a):** a **dedicated `t4g.small`** in the `30-shared-svc` layer,
us-east-1a — *not* co-located inside an app host, because Qdrant is shared by
MacroRAG **and** XbrlRag and must not inherit one consumer's restart domain.

## 2. Measured workload (the fact that reshapes the decision)

Read live from the existing dev Qdrant (v1.18.2, 3 collections, all **1024-dim
dense, Cosine**) — an already-running instance used here as the sizing source; the
project's own `data/qdrant` module is not yet built (it is a stub, see
[`design-decisions.md` §6](design-decisions.md#6-data-stores)):

| Collection | Points | Vectors | Payload |
|---|--:|---|---|
| `macro_chunks` (MacroRAG) | 3,287 | dense (on-disk) + sparse | 10 indexed fields |
| `xbrl_sec10k_metadata` | 23,347 | dense (in-RAM), HNSW on-disk | 13 fields |
| `xbrl_sec10k_text` | 23,347 | dense + sparse, HNSW on-disk | 13 fields |
| **Total** | **~50k** | ~53k dense | on-disk |

**The decisive number:** the running process reports `resident_bytes ≈ 204 MB` —
that is the *entire* working set (vectors + HNSW graph + overhead). Raw math
agrees: 50k × 1024 × 4 B (float32) ≈ **200 MB**. On-disk footprint is well under
1 GB. This is a **tiny** vector workload — nowhere near the scale where managed-DB
economics, sharding, or HA complexity begin to pay off.

## 3. Cost comparison

**Qdrant Cloud** (managed SaaS, runs 24/7 on Qdrant's own AWS account):

| Tier | Resources | Capacity @1024-dim | Cost |
|---|---|---|---|
| **Free (perpetual)** | 0.5 vCPU / 1 GB / 4 GB disk | ~375k uncompressed vectors | **$0/mo** |
| Standard ~2 GB | dedicated | ~750k | ~$30–60/mo ¹ |
| Standard ~4 GB | dedicated | ~1.5M | ~$60–120/mo ¹ |

¹ Directional. Qdrant meters vCPU + RAM + disk + backup separately and publishes
no flat rate; the [cloud.qdrant.io](https://cloud.qdrant.io) calculator is
authoritative. Blended anchor ≈ $0.078/GB-hr (~$57/GB-RAM-month) for a balanced
config. **Our 50k vectors sit at ~13% of the *free* tier** — we stay free until
roughly 7× current data, or far beyond with quantization.

**Self-host on EC2** (Graviton/arm64, per the Graviton-preferred rule):

| Option | Spec | On-demand | 1-yr Savings Plan (~40%) |
|---|---|--:|--:|
| t4g.micro | 2 vCPU / 1 GB — fits today | $6.13/mo | ~$3.7/mo |
| **t4g.small** | 2 vCPU / 2 GB — recommended | **$12.26/mo** | **~$7.4/mo** |
| t4g.medium | 2 vCPU / 4 GB — growth | $24.53/mo | ~$14.7/mo |
| + EBS gp3 20 GB | data + snapshot room | +$1.60/mo | +$1.60/mo |
| + EBS snapshots→S3 | a few GB | ~$0.30/mo | ~$0.30/mo |

**But the real self-host cost for us is lower still.** The shared Qdrant is
co-located on the already-provisioned shared-services EC2 (consolidation doc §3,
`30-shared-svc`), which is on the **same ~10h/day dev schedule** as the app tier
(§2a NAT / §2b ALB scheduling):

- **Co-located container** on a box we already pay for → marginal cost ≈ **EBS only
  (~$2/mo)**; the 200 MB working set fits with room to spare.
- Even a *dedicated* t4g.small on the same overnight schedule bills ~10/24 of the
  hourly rate → **~$5/mo on-demand**.

A managed Cloud cluster, by contrast, **bills 24/7** — it cannot ride our schedule
the way an EC2 host does. This is the same "unpausable always-on line item" trap
that redirected us from NAT Gateway → NAT instance (§2a) and gated the ALB (§2b).

## 4. Data loading — genuinely different, and it matters

The client code is identical either way (`qdrant-client`, only the URL + API key
change), so migration is cheap in *either* direction. The difference is the
**network path**, not the code:

| | Self-host (in-VPC) | Qdrant Cloud |
|---|---|---|
| Ingest path | → private IP `:6333`, same VPC | → **public TLS endpoint over the internet** |
| Egress / NAT | none — private subnet | every upsert traverses the **NAT instance** (§2a) → data-processing + egress. 200 MB one-time = pennies; large re-indexes accrue |
| Overnight | DB + box scheduled together, self-contained | NAT is **stopped overnight** → Cloud unreachable from the private subnet unless NAT is up |
| Query hot-path | in-VPC, sub-ms network | internet round-trip per query, unless PrivateLink (Premium tier) |
| Re-index | free, fast, unlimited | slower (over internet), metered |

The one-time load of 50k vectors is trivial in both cases (seconds–minutes;
embeddings, not the DB, are the bottleneck). The real cost is on the **serving hot
path**: Cloud puts every RAG query behind an internet + NAT dependency that we have
deliberately scheduled off overnight.

## 5. Architecture complexity

| Dimension | Self-host on EC2 | Qdrant Cloud |
|---|---|---|
| Provisioning | reuses `compute/ec2-app` + `data/qdrant` module + scheduler | new SaaS cluster, **outside Terraform state** |
| Ops (upgrade, patch, backup, monitor) | **we own it** — systemd unit, snapshot→S3, CW alarms | fully managed |
| Security setup | manual: Qdrant ships **auth-off by default** → must set API key + TLS, SG private-only | TLS + API key auto-provisioned |
| **Data residency** | stays **in our account** ✓ | data leaves to Qdrant's AWS. In-account managed = Hybrid Cloud = "on request" enterprise pricing (not for cost-sensitive dev) |
| Networking | least-privilege, SG-to-SG, no internet | requires egress to a public endpoint (or paid PrivateLink) |
| HA | single node (fine for dev; prod clustering is a real jump) | managed HA available (paid) |

## 6. Decision & rationale

**Decided: Qdrant runs self-hosted on EC2, not on Qdrant Cloud.** In our own
principles' terms:

- **Cost:** ~$2/mo marginal vs. $0 Cloud-free — a rounding error, so cost is a wash
  and does not drive the choice.
- **Data-in-account + least-privilege networking** (the tie-breaker): nothing leaves
  our account, no internet/NAT dependency on the RAG hot path, SG-private only.
- **One service, reuses infra:** slots into the module + scheduler + private subnets
  already built; no new billing surface outside Terraform state.
- **Rides the schedule:** up exactly when the apps are; a managed cluster bills 24/7.

**Accepted costs (self-host):** we own patching, backups (EBS snapshot + Qdrant
snapshot→S3), and it is a single node — no HA. All acceptable in dev, consistent
with the §2a NAT-instance and §2b ALB trade-offs. The auth-off default **must** be
closed at provisioning time (API key + TLS + private-only SG) — tracked as a
security requirement on the `data/qdrant` module, not left to convention.

**Choose Qdrant Cloud (free tier) only if** we want zero ops and accept data leaving
the account plus an internet path to the vector DB — reasonable for a throwaway
prototype, but it fights the NAT-off-overnight design and the keep-it-in-account
posture.

### 6a. Decided: dedicated `t4g.small` in `30-shared-svc`, us-east-1a (2026-07-23)

**Decision.** The shared Qdrant runs on its **own dedicated `t4g.small`** (2 vCPU /
2 GB, arm64) in the **`30-shared-svc`** layer — **not co-located inside any
application host** — pinned to **us-east-1a**, with a dedicated CMK-encrypted **gp3
EBS** data volume, on the **shared 11:00–21:00 dev schedule**.

| Placement / size | Effective cost | Verdict |
|---|---|---|
| Co-located container in an app host (`41-macrorag`) | ~$2/mo (EBS only) | **rejected** — couples the *other* consumer (XbrlRag) to that host's lifecycle |
| Dedicated **t4g.micro** (1 GB) | ~$6/mo on-demand (~$3 scheduled) | rejected — 1 GB leaves no index-build / optimization headroom |
| **Dedicated t4g.small (2 GB)** | ~$12/mo on-demand (**~$5 scheduled**, +~$2 EBS) | **chosen** — isolated + ~2× working-set headroom |
| Dedicated t4g.medium (4 GB) | ~$25/mo on-demand | deferred — only if the corpus grows several× (§7) |

**Why dedicated, not co-located — the XbrlRag factor.** Qdrant is a *shared* store:
MacroRAG (`macro_chunks`) and XbrlRag (`xbrl_sec10k_*`) both depend on it, and XbrlRag holds
~47k of the ~50k vectors — it is the dominant user. Placing a shared store inside one
consumer's app host (e.g. `41-macrorag`) would couple the *other* consumer to that
host's lifecycle: XbrlRag would lose its vector store every time the MacroRAG box is
stopped or redeployed. Isolation in the shared layer is worth the ~$5/mo over pure
co-location. **Faultline is not a factor** — it uses RDS + SQS + a VaR job-runner
and never touches Qdrant. There is also **no existing EC2 in `30-shared-svc` to
co-locate onto**: RagInference is Fargate + scale-to-zero, where a stateful DB would
need EFS and would die on scale-down.

**Why t4g.small (2 GB).** The measured 204 MB working set (§2) fits `t4g.micro` (1 GB)
today, but 1 GB leaves no headroom for HNSW index builds, int8 optimization passes, and
the OS. `t4g.small` gives ~2× working-set headroom for ~$5/mo scheduled; `t4g.medium`
is deferred to the §7 growth trigger.

**Ingestion stays decoupled — clients dial Qdrant over the VPC, they do not run on it.**
XbrlRag ingest is the scale-to-zero Spot job-runner (consolidation §3); MacroRAG's is
inline with its app host. At ~50k vectors / ~200 MB with everything in us-east-1a,
same-AZ transfer is **$0**, so on-host locality buys nothing and the write path is not
the bottleneck (§4) — embeddings are. The HNSW/quantization index-build CPU lands
*inside* Qdrant regardless of where the orchestrator runs, so the lever for a large
re-index is the **Qdrant host size (temporarily) or throttled optimizers**, not moving
the ingest job onto the box.

**§6a decision inputs, resolved:**
- (a) *Failure/restart domain* — **isolated.** Serves two subsystems; must not share an app tier's restart domain.
- (b) *Corpus growth* — **~50k now → 2 GB.** Revisit at ~500k–1M vectors (§7).
- (c) *Schedule* — **rides the shared 11:00–21:00 window.** Both consumers are on it.

**Security (build-time, per §6).** The auth-off default is closed at provisioning:
API key + TLS + private-only SG-to-SG ingress on 6333/6334 from the MacroRAG SG, the
XbrlRag SG, and the ingest job-runner SG only.

**Cost:** ~$5/mo scheduled compute + ~$2/mo EBS ≈ **~$7/mo**.

## 7. Revisit triggers

Re-run this comparison when **any** holds:

- Corpus approaches **~500k–1M vectors** (managed backups/scaling start to earn the
  ~$30–60/mo), or the 200 MB working set outgrows a t4g.small's headroom.
- A **prod** deployment needs real HA — Qdrant clustering is a genuine complexity
  jump that managed SaaS absorbs for you; weigh it there separately from dev.
- Quantization strategy changes materially (int8/binary shifts the RAM math and the
  free-tier headroom).

---

*Numbers: workload is measured off the live dev Qdrant; EC2/EBS figures are AWS list
price (us-east-1, Jul 2026); Cloud Standard-tier dollar figures are directional —
the vendor calculator is authoritative. Sources captured in the analysis thread.*
