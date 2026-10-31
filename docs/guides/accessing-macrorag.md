# Accessing MacroRAG (UI + admin API)

MacroRAG has **no public ingress** — the shared ALB was retired and the
environment runs `ingress_mode = "ssm"` (see `dev/env.hcl`). The app host is a
private-subnet EC2 instance reached only through **Session Manager**, so the UI
and API are reached with an **SSM port-forward**, not a URL.

This is deliberate: a single-user dev tool needs no always-on load balancer
(~$16/mo, unpausable), and SSM exposes nothing — the agent dials outbound and
needs no inbound rule. See `docs/design/aws-service-consolidation.md` §2b.

## Ports on the host

| Service | Port | Protocol | Purpose |
|---|---|---|---|
| `ui` (nginx) | 8080 | HTTP | SPA + `/api` reverse proxy — **the front door** |
| `app` (uvicorn) | 8000 | HTTP | API directly (`/query`, `/healthz`, `/admin/*`) |

The API is also reachable *through* the UI on 8080 (`/api` is proxied same-origin),
so tunnelling 8080 alone is enough for normal use.

## The UI, from your laptop

Find the instance (its id changes on every reprovision, so address it by tag):

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=genai-dev-macrorag" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text --region us-east-1
```

Open a port-forward with an SSM-capable profile and leave it running:

```powershell
aws ssm start-session --target <instance-id> `
  --document-name AWS-StartPortForwardingSession `
  --parameters "portNumber=8080,localPortNumber=18080" `
  --region us-east-1 --profile <your-ssm-profile>
```

Then browse **`http://localhost:18080`** (plain **http**, not https — only Qdrant
serves TLS). Use a local port other than `8080` if you run a local MacroRAG, or
the tunnel collides with it.

## The admin API (index / jobs), on the host

Over an interactive SSM shell (`aws ssm start-session --target <id>`), or by
forwarding `8000` the same way:

```bash
curl -s http://localhost:8000/healthz                                   # built? qdrant collection, chunk count
curl -sS -X POST http://localhost:8000/admin/index -d '{"append": true}'  # incremental re-index
curl -s http://localhost:8000/admin/jobs                                 # job status (auth is off in dev)
curl -s -X POST http://localhost:8000/query -H 'content-type: application/json' -d '{"question":"..."}'
```

The query field is **`question`** (not `query`). `/admin/*` auth is off in dev.

## Availability windows (nothing is 24×7)

- **NAT** up 10:00–22:00 ET — a private host is only SSM-reachable while the NAT
  forwards, so the tunnel fails outside this window even if the host is up.
- **MacroRAG host** up 11:00–21:00 ET (`41-macrorag/app` — `start_cron`/`stop_cron`).
- **Qdrant + RagInference** up 11:00–21:00 ET — the UI loads outside this window
  but **queries fail** (no vector store / embedder). First query after the 11:00
  scale-up pays RagInference's ~5–6 min cold start.

So: the fully-working window is **11:00–21:00 ET**. Outside it, the stack is down
to save cost; the indexed corpus persists on Qdrant's and the app host's EBS
volumes.

## References
- Shared services (Qdrant/RagInference) wiring: [`consuming-shared-services.md`](consuming-shared-services.md)
- Ingress toggle + cost rationale: [`../design/aws-service-consolidation.md`](../design/aws-service-consolidation.md)
