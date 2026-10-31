# Runbook — day-2 operations

The commands for running what is already provisioned: finding hosts, reaching private
services, shipping an app image, and debugging a tier that will not serve. Everything
here has been used against the live `dev` estate.

**Keep this current.** When a command changes, or a new failure signature is
diagnosed, update this file in the same change — a stale runbook is worse than none,
because it is trusted. The [failure signatures](#8-failure-signatures) table is the
highest-value section: every row cost real debugging time.

Related: [`provision-env.md`](provision-env.md) (standing an environment up),
[`terraform-execution-role.md`](terraform-execution-role.md) (identity model),
[`arag-db-bootstrap.md`](arag-db-bootstrap.md) (one-time RDS schema load),
[`../guides/consuming-shared-services.md`](../guides/consuming-shared-services.md).

---

## 1. Identity — pick the right profile first

| Profile | Identity | Use for |
|---|---|---|
| `readonlyagent` | read-only IAM user | reads **through the AWS MCP server only** — a raw-CLI read is denied by design |
| `genai-tf` | `tfuser` → `genai-terraform-exec` | all Terraform/Terragrunt, ECR pushes, deploy scripts, `task verify` |
| `<admin-profile>` | human admin (browser session) | IAM/account-level steps, reading `rds!*` managed secrets, SSM sessions |

There is **no `[default]` profile**, deliberately: an unpinned call fails with
`NoCredentials` instead of silently running as admin. Pin it every time.

```powershell
$env:AWS_PROFILE = "genai-tf"
task whoami        # must print assumed-role/genai-terraform-exec/...
```

`$env:` vars are **per shell**. A new window silently drops them — the cause of more
than one confusing failure (see [§8](#8-failure-signatures)).

## 2. Find things (never hardcode an instance id)

Instance ids change whenever a host is replaced — and any `runtime_env`/user-data
change replaces it. Always resolve by tag.

```powershell
$region = "us-east-1"

# One app host by name: genai-dev-arag | genai-dev-macrorag | genai-dev-qdrant | genai-dev-arag-ingest
aws ec2 describe-instances --filters "Name=tag:Name,Values=genai-dev-arag" "Name=instance-state-name,Values=running" `
  --query "Reservations[].Instances[].InstanceId" --output text --region $region

# Everything, with state
aws ec2 describe-instances --filters "Name=tag:Project,Values=genai" `
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,Id:InstanceId,State:State.Name,Type:InstanceType,IP:PrivateIpAddress}" `
  --output table --region $region

# Is the SSM agent actually online? (a running instance is not necessarily reachable)
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=<id>" `
  --query "InstanceInformationList[].{Ping:PingStatus,Last:LastPingDateTime}" --region $region

# RDS endpoint + managed-secret ARN
aws rds describe-db-instances --db-instance-identifier genai-dev-arag `
  --query "DBInstances[0].{Endpoint:Endpoint.Address,User:MasterUsername,Secret:MasterUserSecret.SecretArn}" --region $region
```

## 3. Start / stop compute

**EC2** is driven by per-component schedule stacks (`*-schedule`). Manual start/stop is
for exceptions; the schedule reasserts itself at the next tick.

```powershell
aws ec2 start-instances  --instance-ids <id> --region us-east-1
aws ec2 stop-instances   --instance-ids <id> --region us-east-1
```

**RDS `genai-dev-arag`** follows its own schedule (10:45–21:10 ET), which deliberately
**brackets** the app window (11:00–21:00) — the database is available before the XbrlRag
host boots and outlives it on the way down. The schedule lives *inside* `42-arag/db`,
not in a sibling component, so `terragrunt plan` there is the way to check it.

Any work outside that window — an off-hours ingest, a late DDL run through the SSM
tunnel — needs the database started by hand first. Budget **~8 minutes** from the
call to `available` (measured 2026-07-29: `starting` → `rebooting`, applying pending
parameters → `available`), and note the endpoint refuses connections until then:

```powershell
aws rds start-db-instance --db-instance-identifier genai-dev-arag `
  --region us-east-1 --profile genai-tf
aws rds stop-db-instance  --db-instance-identifier genai-dev-arag `
  --region us-east-1 --profile genai-tf

# state — "stopped", "starting", "available"; the endpoint answers only when available
aws rds describe-db-instances --db-instance-identifier genai-dev-arag `
  --query "DBInstances[0].DBInstanceStatus" --region us-east-1
```

A manual start is *not* undone by the schedule until 21:10, so a database started at
22:00 for a late run stays up all night — stop it when done.

**RagInference (ECS Fargate)** scales on an Application Auto Scaling *scheduled action*,
not a desired-count you can set directly. `update-service --desired-count 1` gets
reconciled back to the scalable target's bounds. Move the bounds instead:

```powershell
# up
aws application-autoscaling register-scalable-target --service-namespace ecs `
  --resource-id service/genai-dev-raginference/genai-dev-raginference `
  --scalable-dimension ecs:service:DesiredCount --min-capacity 1 --max-capacity 1 `
  --region us-east-1 --profile genai-tf

# down (do this when done — it is the most expensive idle resource)
aws application-autoscaling register-scalable-target --service-namespace ecs `
  --resource-id service/genai-dev-raginference/genai-dev-raginference `
  --scalable-dimension ecs:service:DesiredCount --min-capacity 0 --max-capacity 0 `
  --region us-east-1 --profile genai-tf

# state
aws ecs describe-services --cluster genai-dev-raginference --services genai-dev-raginference `
  --query "services[].{Desired:desiredCount,Running:runningCount,TaskDef:taskDefinition}" --region us-east-1
```

**Gotcha:** if the daily scale-*down* action has already fired for the day, re-registering
the target to 1 leaves it running until the *next* day's down action — roughly 24h of
spend. Scale it to zero by hand.

## 4. Reach a private service (SSM — there is no SSH)

Every workload is in a private subnet. Two documents do the work: plain
`AWS-StartPortForwardingSession` for a port **on the host**, and
`...SessionToRemoteHost` for something the host can reach (RDS).

```powershell
# Interactive shell
aws ssm start-session --target <id> --region us-east-1 --profile <ssm-profile>

# Port on the host  ->  laptop
aws ssm start-session --target <id> `
  --document-name AWS-StartPortForwardingSession `
  --parameters "portNumber=8080,localPortNumber=18080" `
  --region us-east-1 --profile <ssm-profile>

# Through the host to RDS
$rds = aws rds describe-db-instances --db-instance-identifier genai-dev-arag --query "DBInstances[0].Endpoint.Address" --output text --region us-east-1
aws ssm start-session --target <app-host-id> `
  --document-name AWS-StartPortForwardingSessionToRemoteHost `
  --parameters host="$rds",portNumber="5432",localPortNumber="15432" `
  --region us-east-1 --profile <ssm-profile>
```

| Service | Host port | Suggested local port | URL |
|---|---|---|---|
| XbrlRag / MacroRAG UI (nginx) | 8080 | 18080 | `http://localhost:18080` — plain **http** |
| XbrlRag / MacroRAG API | 8000 | 18000 | nginx already proxies `/api`, so the UI tunnel is usually enough |
| XbrlRag MCP | 8765 | 18765 | |
| Qdrant REST + dashboard | 6333 | 16333 | `https://localhost:16333/dashboard` — **https**, self-signed |
| Qdrant gRPC | 6334 | 16334 | |
| RDS Postgres | 5432 (remote) | 15432 | |

Use a **distinct local port**. A local Qdrant on 6333 or a local app on 8080 silently
wins and you debug the wrong instance. Requires the Session Manager plugin, and the
NAT up for the host's SSM agent to be online.

## 5. Ship an app image (a deploy, never a provision)

The image tag lives in an S3 `deploy.env`, not in Terraform. Bumping it needs **no**
`terraform apply` — see provisioning principle 6 in `CLAUDE.md`.

```powershell
# 0. commit first, so the tag records exactly what runs
cd <xbrlrag-checkout>
$REGISTRY = "<acct>.dkr.ecr.us-east-1.amazonaws.com"
$TAG = "arm64-$(git rev-parse --short HEAD)"

# 1. ECR login — the token expires after 12h
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REGISTRY

# 2. build + push EVERY image the compose stack runs, all on the SAME tag
docker buildx build --platform linux/arm64 --push -f infra/docker/Dockerfile -t "$REGISTRY/genai-dev/arag:$TAG" .
docker buildx build --platform linux/arm64 --push -f ui/Dockerfile        -t "$REGISTRY/genai-dev/arag-ui:$TAG" ui/

# 3. CONFIRM both tags exist before publishing the pointer
aws ecr describe-images --repository-name genai-dev/arag    --query "imageDetails[?contains(imageTags,'$TAG')].imageTags" --region us-east-1
aws ecr describe-images --repository-name genai-dev/arag-ui --query "imageDetails[?contains(imageTags,'$TAG')].imageTags" --region us-east-1

# 4. publish the pointer
cd <this-repo>
$env:AWS_PROFILE = "genai-tf"
conda run -n py312 python scripts/deploy_arag_bundle.py --tag $TAG      # MacroRAG: deploy_macrorag_bundle.py

# 5. roll it (on the host, via SSM)
#    sudo systemctl restart app.service
```

**The `--tag` fills every image sentinel in `deploy.env`**, so all images must carry the
identical tag. Dropping the `arm64-` prefix on *either* the push or the publish breaks the
host at boot. Repos are IMMUTABLE, but adding a **new** tag to an existing image is
allowed, which is the cheap repair:

```powershell
docker buildx imagetools create --tag "$REGISTRY/genai-dev/arag-ui:arm64-<sha>" "$REGISTRY/genai-dev/arag-ui:<sha>"
```

## 6. Debug a tier that will not serve

All host commands need `sudo` — including `journalctl`, which otherwise prints nothing
useful and just hints that you lack permission.

```bash
sudo systemctl status app.service          # active (exited) = healthy for a oneshot unit
sudo journalctl -xeu app.service -n 80 --no-pager
sudo docker ps                             # expect the full compose set
sudo docker logs $(sudo docker ps -qf name=api) --tail 100
sudo docker inspect --format '{{.Config.Image}}' $(sudo docker ps -qf name=api)   # what tag is ACTUALLY running
sudo docker exec $(sudo docker ps -qf name=api) printenv | sort                   # env that reached the container

cat /opt/app/bundle/deploy.env             # the image tags this host resolved
grep -c . /opt/arag/.env                   # secrets rendered (600, never cat it into a log)
sudo /usr/local/bin/arag-render-secrets    # re-fetch secrets after a rotation
sudo systemctl restart app.service         # re-pull bundle + compose up
cat /var/log/app-bootstrap-status          # proves cloud-init finished on first boot
```

ECS-side (RagInference):

```powershell
aws logs filter-log-events --log-group-name /ecs/genai-dev-raginference --filter-pattern "rerank" --limit 10 --region us-east-1
```

`uvicorn` logs a request only on **completion**, so an in-flight slow request appears as
*silence*, not as an error. Absence of a log line is not absence of work.

## 7. Query the databases

`scripts/dbq.py` (XbrlRag repo) uses the pipeline's own connection path, so a query that
works there proves the app's path works.

```powershell
# RDS through the tunnel from §4
cd <xbrlrag-checkout>
$env:XBRL_DB_HOST='localhost'; $env:XBRL_DB_PORT='15432'; $env:XBRL_DB_NAME='xbrl_db'
$env:XBRL_DB_USER='arag_admin'; $env:XBRL_DB_PASSWORD='<from the rds! secret or /opt/arag/.env>'
$env:XBRL_DB_SSLMODE='require'

conda run -n py312 python scripts/dbq.py "SELECT count(*) FROM filing_registry"
conda run -n py312 python scripts/dbq.py -f scripts/ddl/populate/entity_master.sql --commit
```

**Always read the stderr banner — it names the target.** `arag_admin@localhost:15432
sslmode=require` is RDS; `postgres@localhost:5432 sslmode=prefer` is your laptop. A
fresh shell has no `XBRL_DB_*` and silently hits **local**.

`--commit` is required for any write; `dbq.py` rolls back by default.

## 8. Failure signatures

| Signature | Cause | Fix |
|---|---|---|
| `app.service` exit **18**, `manifest unknown` | `deploy.env` points at a tag not in ECR — usually a missing `arm64-` prefix on the push *or* the publish | verify both tags (§5), re-publish or retag, `systemctl restart app.service` |
| `403 Forbidden` on a blob HEAD during `docker push` | ECR token expired (12h) | re-run `docker login` (§5) |
| `journalctl` shows nothing + "not seeing messages from other users" | missing privileges | `sudo journalctl -xeu app.service` |
| `ModuleNotFoundError: torch` in the serving/ingest image | an import leak — the slim images install no torch | keep heavy imports function-local; `test_torch_free_contract.py` guards it |
| `httpx.ReadTimeout` after ~300s on `/rerank` | listwise rerank on CPU exceeds the client timeout | fewer candidates, more vCPU; `RAGINFER_TIMEOUT_S` < nginx `ARAG_PROXY_READ_TIMEOUT` |
| `HTTP 000` / "can't provide a secure connection" via a tunnel | local port collision with a local service | use a distinct local port (§4) |
| Query returns nothing, no error, on a fresh DB | a populator that lives only in a design doc never ran | see `scripts/ddl/populate/` in the XbrlRag repo; run all of them after an ingest |
| `can't execute an empty query` from `dbq.py` | a `;` inside a `--` comment splits into a comment-only chunk | no semicolons in SQL comments |
| PowerShell mangles a SQL `LIKE '%x%'` | `%` is eaten on the command line | use `strpos(...)` / `left(...)`, or put the SQL in a file |
| `NoCredentials` | no `[default]` profile, by design | pin `$env:AWS_PROFILE` |
| Raw-CLI read denied for `readonlyagent` | its grants are condition-gated on `aws:CalledViaAWSMCP` | read through the MCP server, not the CLI |
| A host or database did **not** start/stop on schedule, no error anywhere | the schedule fired and its target refused the call — usually the scheduler role capped by the app permissions boundary, a stale target id, or a resource mid-transition | check `AWS/Scheduler` `TargetErrorCount`/`InvocationDroppedCount` (readable by `readonlyagent`, dimension `ScheduleGroup=default`), then `simulate_principal_policy` on the role against the live ARN. The `genai-dev-schedules-*` alarms now page on this |
| `scheduler get-schedule` fails for `readonlyagent` | the target input is CMK-encrypted and it has no `kms:Decrypt` | read it with boto3 as `genai-tf`, or run a no-op `terragrunt plan` on the component |
| An RDS start errors and never retries into success | `StartDBInstance` against an instance still `stopping` is rejected, and Scheduler does not retry it back to health | wait for `stopped` before starting; budget ~8 min for a start to reach `available` |
| SNS `SubscriptionsConfirmed` reads 0 though the click worked | that topic attribute is an aggregate SNS updates lazily (minutes) | assert on `list_subscriptions_by_topic` — an unconfirmed entry has the literal string `PendingConfirmation` where its ARN belongs |

## 9. Gates

```powershell
task ci        # ruff + mypy + pytest
task policy    # checkov
task verify    # integration tests against LIVE AWS — requires AWS_PROFILE=genai-tf
```

CI (`.github/workflows/ci.yml`) runs the `task ci` gate, checkov and a full-history
gitleaks scan on a clean checkout. It holds no AWS credentials, so `task verify` stays
a manual step after each apply.

`task` only resolves from the repo root. Known-red exclusions while work is in flight
(**re-check these before trusting a green run** — they should shrink, not grow):

```powershell
$env:IAC_INGRESS_MODE = "ssm"     # test_alb defaults to "alb"; dev/env.hcl is "ssm"
conda run -n py312 pytest tests/integration -m integration -q
```

As of 2026-07-29 there are **no known-red exclusions**: the Faultline ignore
retired when Q5/Q6 applied, and the NAT deselect retired with the overnight override.
Anything red now is a real finding.

## 10. What costs money while idle

| Resource | Idle cost | Control |
|---|---|---|
| RagInference (8 vCPU / 16 GB ARM Fargate) | ~$0.32/hr | scale to zero (§3) — the big one |
| RDS `genai-dev-arag` (db.t4g.micro) | ~$0.016/hr running; ~$2.30/mo storage bills stopped too | schedule inside `42-arag/db`, 10:45–21:10 |
| NAT instance | hourly | `00-networking/nat-schedule`, 10:00–22:00 |
| EC2 app/Qdrant hosts (t4g.small) | ~$0.017/hr each running, EBS when stopped | schedule folded into each app component (`start_cron`/`stop_cron`) |
| Faultline host (t4g.large) | ~$0.067/hr running — the largest EC2 line | same, 11:00–21:00 |

**If a schedule stops working you will now hear about it.** The
`genai-dev-schedules-target-errors` and `-invocations-dropped` alarms publish to the
`genai-dev-ops-alerts` SNS topic (`90-observability`). They catch an invocation that
was *refused* or *abandoned* — not one that never fired, which the per-component
tests catch by asserting the schedule matches the declared park state (§11).

## 11. Park the environment (and wake it up)

Between demos the estate should run **nothing**. Park mode holds every compute tier
down indefinitely while keeping every resource provisioned — volumes, images, secrets,
DNS names, ingested data. **Waking up is a flag flip and an apply, never a
re-provision.**

The reasoning behind all of this — how the spend was measured, why each tier parks by a
different mechanism, and what parking cannot remove — is in
[`../design/park-mode.md`](../design/park-mode.md). This section is the commands.

The switch is one line in [`infra/environments/dev/env.hcl`](../../infra/environments/dev/env.hcl):

```hcl
parked = true    # false to bring the daily windows back
```

```powershell
$env:AWS_PROFILE = "genai-tf"
task plan  ENV=dev    # read it
task apply ENV=dev
task verify           # asserts AWS matches the declared mode, both directions
```

### Parking does not stop what is already running

It stops things *coming back*. Whatever is up when you apply stays up until you or the
evening crons put it down. After applying, check nothing is left running:

```powershell
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" `
  --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value]" --region us-east-1
aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]" --region us-east-1
aws ecs describe-services --cluster genai-dev-raginference --services genai-dev-raginference `
  --query "services[].{Desired:desiredCount,Running:runningCount}" --region us-east-1
```

Stop anything still up with the §3 commands. `task verify` fails if a Fargate task is
still running while parked, so it catches the expensive case for you.

### The three tiers park differently — and RDS is the trap

| Tier | Parked state | Why |
|---|---|---|
| EC2 (nat, qdrant, macrorag, arag, qlp) | both crons **DISABLED** | a stopped instance never restarts itself |
| ECS (raginference) | scale-**up** action removed, target bounded to 0 | the bound is what holds it down; the daily scale-down stays as a backstop |
| RDS (arag) | stop cron **kept ENABLED**, start cron **removed** | **AWS force-starts a stopped RDS instance after 7 days** |

**Do not park the database by disabling its schedules.** That cancels the stop as well,
so AWS's seven-day force-start brings it back with no rule left to put it down, and it
then bills 24×7 unnoticed. A stop-only schedule re-parks it within hours; the worst
case is a few hours of `db.t4g.micro` once a week. This asymmetry is enforced —
`infra/modules/data/rds` rejects a start with no stop at plan time, and
`tests/integration/test_arag_db_schedule.py` asserts the parked shape.

### Waking up for a demo

Set `parked = false`, apply, and the 11:00–21:00 windows return. To bring the estate up
*now* rather than waiting for the morning crons, start the tiers in dependency order —
NAT first (private subnets have no egress without it), then Qdrant and RDS, then the app
hosts, then RagInference (§3). RDS needs ~8 minutes to reach `available`; RagInference's
first request after scale-up pays a ~5–6 minute cold start.

### What parking cannot remove

About **$0.68/day** survives, and it can only be reduced by destroying things:

| Item | ~$/mo | Note |
|---|---|---|
| EBS volumes (208 GB gp3) | 16.30 | bills whether or not an instance is attached — **79% of the parked cost** |
| Secrets Manager (5 secrets) | 2.00 | |
| KMS CMKs (3) | 1.00 | |
| ECR images | 0.73 | ~7 GB; the RagInference image alone is 3.2 GB |
| Route 53 private zone | 0.50 | |
| S3 + Cloud Map | 0.60 | |

Snapshotting and deleting the volumes would cut the largest line roughly in half, but it
turns a wake-up into a restore-and-reprovision — deliberately not done.
