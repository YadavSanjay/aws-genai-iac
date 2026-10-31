# Park mode — holding the estate at near-zero cost between demos

**Status:** applied to `dev` on 2026-07-31.
**Switch:** `parked` in [`../../infra/environments/dev/env.hcl`](../../infra/environments/dev/env.hcl).
**Operator steps:** [runbook §11](../runbooks/day2-operations.md#11-park-the-environment-and-wake-it-up).

---

## 1. The requirement

This estate exists to **demo**, from a laptop that holds no local data, what these
subsystems do. It is not a production service and has no users between demos, and
demo dates are not known in advance.

So the requirement is not "run cheaply". It is to run **nothing** until the next
demo, last one to two months on a fixed budget, and come back **without
re-provisioning anything**.

That last clause is the binding constraint. Tearing the estate down and rebuilding it
would be cheaper still, but it would mean re-ingesting the XbrlRag corpus, rebuilding the
MacroRAG index, re-seeding the Faultline EBS tree, and re-verifying the whole
stack — days of work to save tens of dollars, and a real chance the rebuild does not
come back identical.

## 2. Measuring first — and the trap in the measurement

The estate was already scheduled to ~10 h/day. The question was whether that was
enough to last two months, and the answer needed real numbers rather than list-price
arithmetic.

**Cost Explorer reported $0.** Not "small" — exactly zero, across three months, for
every service. That is because the account runs on promotional credits, and Cost
Explorer's default `UnblendedCost` nets the `Credit` records against the `Usage`
records. The bill is invisible unless you filter to usage:

```powershell
aws ce get-cost-and-usage --time-period Start=2026-07-01,End=2026-08-01 `
  --granularity DAILY --metrics UnblendedCost `
  --group-by Type=DIMENSION,Key=SERVICE `
  --filter '{\"Dimensions\":{\"Key\":\"RECORD_TYPE\",\"Values\":[\"Usage\"]}}' `
  --region us-east-1
```

**This is worth internalising: a $0 Cost Explorer reading on a credited account is not
evidence of no spend.** Believing it would have meant parking nothing and discovering
the credits gone weeks later.

With the filter applied, July was **$33.62**, and the recent daily run-rate was **~$4/day**:

| Service | $/day | Share | Survives parking? |
|---|---|---|---|
| **ECS Fargate** (RagInference) | 2.40–3.20 | **~66%** | no |
| EBS volumes (208 GB) | 0.54 | ~14% | **yes** |
| EC2 compute (6 × t4g) | 0.36–0.57 | ~11% | no |
| RDS | 0.24–0.46 | ~8% | compute no, storage yes |
| Secrets / KMS / ECR / S3 / Cloud Map / R53 | ~0.14 | ~4% | **yes** |

At ~$4/day the budget would last weeks, not the one to two months required. Parking
at ~$0.68/day stretches the same budget roughly six times further.

Two findings drove the whole design:

- **RagInference is two thirds of the bill by itself.** An 8 vCPU Fargate task at
  ~$0.316/hr dwarfs six Graviton instances put together. Any park that did not stop it
  first would be rearranging the small numbers.
- **EBS is now the floor and cannot be scheduled away.** 208 GB across nine volumes
  bills whether or not an instance is attached. It had been estimated at ~$8/mo in the
  docs; it is ~$16.30/mo, having roughly doubled when Faultline and the ingest
  runner landed.

## 3. The design: one switch, three mechanisms

A single version-controlled boolean in `dev/env.hcl`, in the same spirit as the
existing `ingress_mode` toggle — an environment's run state should be visible in git
and auditable, not a console action somebody took once.

```hcl
parked = true
```

Seven components read it. What makes this more than a loop over `enabled = false` is
that **the three tiers have genuinely different off-switches**, and the intuitive
choice is wrong for one of them.

### EC2 — disable both crons

`nat`, `qdrant`, `macrorag`, `arag`, `qlp`. A stopped EC2 instance never restarts
itself, so removing the daily start is sufficient and the stop can go with it.

### ECS — remove the scale-up action, bound the target to 0

Three different things can set `DesiredCount` on this service — the service's own
`desired_count` (which Terraform ignores after creation), the Application Auto Scaling
target's min/max, and the scheduled actions. The **bound** is what actually holds the
task down: Auto Scaling enforces it continuously, so a task already running is scaled
in rather than surviving until 21:00.

The scale-**down** action is deliberately **kept** in both modes. It costs nothing and
re-asserts zero if anyone sets `DesiredCount` by hand. Removing it as "unused while
parked" would drop the backstop precisely when nobody is watching.

### RDS — keep the stop, drop the start

**This is the one that bites, and it is the opposite shape from the other two.**

> **AWS force-starts a stopped RDS instance after seven days.**

Park the database the way the EC2 hosts are parked — `schedule_enabled = false` — and
it comes back on day 8 with **no rule left to put it down**, then bills 24×7 for the
remainder of the park. Nothing surfaces this: no alarm fires, no test was watching,
and the only symptom is the credit balance draining at roughly triple the expected
rate. Over a two-month park that is the difference between ~$0.40 and ~$11.70/month on
a tier that is supposed to be off.

So RDS parks with a **stop-only schedule**: the 21:10 stop stays `ENABLED`, the 10:45
start is destroyed. The recurring stop re-parks the database within hours of each
force-start, bounding the worst case at a few hours of `db.t4g.micro` once a week.

`infra/modules/data/rds` previously **rejected** this configuration:

```
start_cron and stop_cron must be set together: a stop with no start leaves the
database down until someone notices.
```

That guard was inverted, because the two crons are not symmetric:

| Configuration | Result | Rationale |
|---|---|---|
| start + stop | normal daily window | — |
| **stop only** | **parked** | fail-safe — costs nothing |
| start only | **rejected at plan time** | bills 24×7 forever |

The original guard protected against an *inconvenience* (a database left down) at the
cost of forbidding the *correct* parked state. The replacement protects against the
expensive asymmetry instead: a start with no stop still fails the plan.

## 4. What parking cannot remove

**~$0.68/day (~$21/mo) survives**, and it is dominated by one line:

| Item | ~$/mo | Removable only by |
|---|---|---|
| EBS volumes (208 GB gp3) | 16.30 | destroying volumes — **79% of the parked cost** |
| Secrets Manager (5) | 2.00 | deleting secrets |
| KMS CMKs (3) | 1.00 | scheduling key deletion |
| ECR images (~7 GB) | 0.73 | lifecycle expiry |
| S3 + Cloud Map | 0.60 | deleting data |
| Route 53 private zone | 0.50 | deleting the zone |

Snapshotting and deleting the volumes would roughly halve the largest line. It was
**deliberately not done**: it converts a wake-up from "flip a flag and apply" into a
restore-and-reprovision, which is exactly the cost the requirement rules out. At
~$21/mo the budget comfortably outlasts the one-to-two month horizon, so the trade is
not worth taking.

Worth noting for later: `genai-dev-arag-ingest` carries a 40 GB root volume (~$3.20/mo)
for a batch tier that has already run. It is the best candidate if the floor ever needs
lowering.

## 5. Enforcement

Park state is **declared in `env.hcl` and asserted against live AWS**, in both
directions — a parked declaration with a live start schedule fails, and so does a live
declaration with a disabled one. Tests that simply mirrored AWS's current state back at
themselves would assert nothing.

`tests/integration/conftest.py` reads the switch from the committed HCL; the schedule
tests assert against that rather than a hardcoded `ENABLED`.

| Check | File |
|---|---|
| EC2 schedules match the declared mode | `test_nat_schedule.py`, `test_arag_schedule.py`, `test_qlp_schedule.py` |
| RDS keeps its stop, drops its start | `test_arag_db_schedule.py::test_park_state_keeps_the_stop_and_drops_the_start` |
| ECS bounds, up-action absence, and **no running task** | `test_raginference_scaling.py` |
| Stop-without-start allowed, start-without-stop rejected | `infra/modules/data/rds/main.tf` precondition |

Two related defects were found and fixed while making this work:

- **`test_alb.py` read `ingress_mode` from an unset environment variable defaulting to
  `"alb"`**, so the ingress toggle's headline assertion — that flipping to `ssm` truly
  destroys the load balancer rather than leaving it billing $16.43/mo — failed on every
  ordinary run and was being ignored. It now reads `env.hcl`.
- **`test_arag_app.py` filtered its instance to `running` only**, so every security
  assertion on that host (IMDSv2, CMK encryption, no public IP, tags) *errored* rather
  than ran whenever the schedule had it stopped — which is most of the time. Those are
  properties of the provisioned instance, not of its power state.

Both had the same root cause as the thing being built here: **a check that silently
stops checking when the estate is off is worse than no check**, because the suite still
looks green.

## 6. Procedures

Full commands are in [runbook §11](../runbooks/day2-operations.md#11-park-the-environment-and-wake-it-up).
In outline:

**To park** — set `parked = true`, `task plan ENV=dev`, `task apply ENV=dev`, then stop
whatever is still running (parking stops things *coming back*; it does not stop what is
already up), and `task verify`.

**To wake for a demo** — set `parked = false` and apply; the 11:00–21:00 windows
return. To come up immediately rather than waiting for the morning crons, start the
tiers **in dependency order**: NAT first (private subnets have no egress without it),
then Qdrant and RDS, then the app hosts, then RagInference. Budget ~8 min for RDS to
reach `available` and ~5–6 min of cold start on RagInference's first request.

**To re-park afterwards** — set `parked = true`, apply, stop what is running, verify.
The window values are left in the components rather than deleted, so parking and waking
are non-destructive to the schedule definitions themselves.

**When the demo timings are known**, edit the crons in the owning components — each
window lives beside the resource it drives, never in a sibling `*-schedule` component
(see [scheduling walkthrough §2](../guides/infra-walkthrough-scheduling-observability.md#2-where-a-schedule-must-live)).
