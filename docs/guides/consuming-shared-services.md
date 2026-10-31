# Consuming the shared services (RagInference + Qdrant)

How a downstream subsystem (MacroRAG, XbrlRag, and future apps) connects to the two
shared backends in `30-shared-svc`. Read this before provisioning a new consumer
or wiring an app's runtime config.

Both services are **east-west (service-to-service) over Cloud Map private DNS**,
inside the VPC — **not** through the ALB. The ALB `ingress_mode` toggle (§2b) is
user-facing ingress only and does **not** affect these calls; they keep working
when ingress flips to `ssm`.

## Endpoints

| Service | Endpoint | Protocol | Auth | Purpose |
|---|---|---|---|---|
| RagInference | `raginference.genai-dev.internal:8799` | **HTTP** (no TLS) | none | embeddings (BGE-M3) + rerank (Jina) |
| Qdrant (REST) | `qdrant.genai-dev.internal:6333` | **HTTPS** (self-signed) | none *(phase 1)* → API key *(phase 2)* | vector store |
| Qdrant (gRPC) | `qdrant.genai-dev.internal:6334` | HTTPS (self-signed) | same as REST | vector store (gRPC clients) |

Discovery resolves via the VPC resolver against the `genai-dev.internal` Cloud
Map namespace; any correctly-SG'd in-VPC host can resolve and reach them. Address
services by **DNS name, never IP** (task/instance IPs churn).

- **RagInference** registration is **health-gated**: the name only resolves to a
  task once `/readyz` returns 200 (both models loaded), so you never hit a warming
  task.
- **Qdrant** is a single EC2 host; the A record tracks its private IP (stable
  across stop/start, updated on replacement).

## Network wiring (the part that bites)

Reachability is two-sided and by **security-group reference**, never CIDR:

1. the **consumer's** SG must have an **egress** rule to the service SG on the
   service port, and
2. the **service's** SG must have an **ingress** rule admitting the consumer SG.

Rules live in `infra/modules/networking/security-groups`. Today:

| Consumer | Egress rules present | Notes |
|---|---|---|
| `app` tier SG (`genai-dev-app`) | → raginfer `:8799`, → qdrant `:6333` + `:6334`, → ALB, → 443, → DNS | **MacroRAG uses this SG, so it works out of the box** |

Service SGs admit only the `app` SG so far:
- `genai-dev-raginference` ingress: `app` SG on `8799`.
- `genai-dev-qdrant` ingress: `app` SG on `6333` and `6334`; egress `443` (AWS) + DNS only.

### Adding a new consumer (e.g. XbrlRag)

App tiers are **per-subsystem, SG-isolated** (consolidation §3). So XbrlRag should get
its **own** SG rather than reuse `app`. When it lands, add (in the
`security-groups` module, mirroring the existing `app_to_*` / `*_from_app` rules):

- XbrlRag app SG **egress** → `raginfer` `:8799`, → `qdrant` `:6333` + `:6334` (plus
  `443`, DNS, and the ALB if it's a user-facing tier).
- `raginfer` SG **ingress** ← XbrlRag app SG `:8799`.
- `qdrant` SG **ingress** ← XbrlRag app SG `:6333` + `:6334`.
- **XbrlRag ingest job-runner** writes vectors, so its SG also needs egress → `qdrant`
  `:6333`/`:6334` (and → `raginfer` `:8799` if it embeds during ingest), with matching
  ingress on the service SGs.

The `qdrant`/`raginfer` groups were written referencing the `app` SG; extend them
with the new group ids — a small, additive SG change, no rebuild.

### Placement & cost

Keep consumers in **us-east-1a** (same AZ as Qdrant + the NAT). Same-AZ traffic is
**$0**; cross-AZ is $0.01/GB each way. The ingest write path (potentially large)
especially wants to stay same-AZ.

### Availability & timing

Everything runs **11:00–21:00 ET** (NAT 10:00–22:00). Off-hours the DNS names
resolve but the ports refuse — treat that as "system down."

- **RagInference** scales to zero off-hours; the **first call after the 11:00
  scale-up pays a ~5–6 min cold start** (weights sync + model warm). Build retries
  / a warm-up call into ingest and first-request paths.
- **Qdrant** restarts in ~seconds (systemd starts the cached container).

## Client configuration

### Qdrant (`qdrant-client`)

Phase 1 (today — TLS on, **auth off**): the cert is self-signed, so skip
verification in-VPC.

```python
from qdrant_client import QdrantClient
client = QdrantClient(url="https://qdrant.genai-dev.internal:6333", verify=False)
# gRPC:
client = QdrantClient(host="qdrant.genai-dev.internal", grpc_port=6334, prefer_grpc=True, https=True, verify=False)
```

Phase 2 (once the API key is set — see below): add `api_key=...`. The key comes
from Secrets Manager (`genai-dev/qdrant/app`, JSON `{api_key}`) — the consumer's
instance role needs `secretsmanager:GetSecretValue` scoped to that secret ARN
(the `data/qdrant` module's own role is the pattern to copy). `/readyz` stays open
without a key; data endpoints will 401/403 without it.

### RagInference (HTTP)

Plain HTTP; no TLS, no auth. Call `http://raginference.genai-dev.internal:8799`
per the RagInference API (embeddings / rerank). Handle the cold-start latency
window after 11:00 ET.

## Auth roadmap (phase 2, deferred)

Qdrant currently starts **auth-off** (`secret_arn = ""` in `30-shared-svc/qdrant`)
— a documented, time-bounded dev relaxation (see the `data/qdrant` module README),
compensated by the private subnet, SG-to-SG-only ingress, no public IP, and no
real data. Closing it (planned as one pass across all apps' secrets):

1. Set the `genai-dev/qdrant/app` secret **value** out of band (a strong random key).
2. Set `secret_arn` to the wired secret in `30-shared-svc/qdrant` and re-apply
   (instance replaces; the data volume persists).
3. Grant each consumer's role `secretsmanager:GetSecretValue` on that ARN, and add
   `api_key` to the clients.

## Qdrant dashboard from a laptop (private host → SSM tunnel)

Qdrant serves a web UI at `/dashboard`. The host is private, so reach it with an
SSM port-forward (the project's `ssm` access mode, §2b). Use a **local port other
than 6333** if you run a local Qdrant, or the tunnel collides with it:

```powershell
aws ssm start-session --target <qdrant-instance-id> `
  --document-name AWS-StartPortForwardingSession `
  --parameters "portNumber=6333,localPortNumber=16333" `
  --region us-east-1 --profile <your-ssm-capable-profile>
```

Then browse `https://localhost:16333/dashboard` and accept the self-signed cert
("Not secure" is expected — the SSM tunnel is already encrypted). No API key while
auth is off. Requires the Session Manager plugin and the instance running.

## Gotchas (learned the hard way)

- **Local port collision:** a local Qdrant on 6333 means a tunnel bound to local
  6333 (or curl/browser to `localhost:6333`) hits the *local* instance, not AWS —
  symptom is `HTTP 000` / "can't provide a secure connection". Use a distinct local
  port.
- **Self-signed TLS:** clients need `verify=False` (or the cert as CA); browsers
  need click-through. Not a downgrade — RagInference is plain HTTP in-VPC and the
  network is private + SG-locked either way.
- **Cold start:** RagInference's first post-11:00 request is slow; don't treat it
  as a failure.
- **Off-hours:** both are down 21:00–11:00 ET; DNS resolves, ports refuse.

## References

- Placement / sizing: [`../design/qdrant-cloud-vs-self-hosted.md`](../design/qdrant-cloud-vs-self-hosted.md)
- Service matrix / windows: [`../design/aws-service-consolidation.md`](../design/aws-service-consolidation.md)
- Modules: [`data/qdrant`](../../infra/modules/data/qdrant/README.md), `compute/ecs-service` (RagInference), `networking/security-groups`, `networking/dns`.
