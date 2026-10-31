# Module: data/qdrant

Self-hosted **Qdrant** vector store on a dedicated private-subnet EC2 host with a
separate EBS data volume. The shared store for MacroRAG + XbrlRag (separate
collections), reached in-VPC over TLS + API key. Platform, placement and sizing
rationale: [`qdrant-cloud-vs-self-hosted.md`](../../../../docs/design/qdrant-cloud-vs-self-hosted.md)
(decision §6a).

## What it creates

- **EC2 host** — `t4g.small` (Graviton, 2 vCPU / 2 GB) by default, AL2023 arm64,
  private subnet, no public IP, IMDSv2 required.
- **Dedicated gp3 EBS data volume** (CMK-encrypted, default 20 GB), attached at
  `/dev/sdf`, mounted at `/var/lib/qdrant`. **Separate from root** so vector data
  survives instance replacement and has its own snapshot lifecycle.
- **Instance role** — SSM core + ARN-scoped ECR pull of *its own* image + read of
  *its own* API-key secret + KMS decrypt via those services. Carries the
  permissions boundary.
- **Cloud Map A record** — `qdrant.<namespace>` (e.g. `qdrant.genai-dev.internal`),
  so consumers configure a stable name, not a churny IP.

## Inputs (key)

| Input | Purpose |
|---|---|
| `subnet_id` | Private subnet; also fixes the AZ of the data volume. Pin to the consumers' AZ (us-east-1a in dev) so vector traffic is same-AZ ($0). |
| `security_group_ids` | The `data`-tier Qdrant SG (ingress 6333/6334 from consumer SGs only). |
| `image` | Full ECR ref of the mirrored `qdrant/qdrant` arm64 image (tag or `@sha256:` digest). |
| `secret_arn` | Secrets Manager secret holding `{api_key}`, read at boot. |
| `ecr_repository_arns`, `kms_key_arn`, `permissions_boundary_arn` | Scoping + encryption + blast-radius. |
| `service_discovery_namespace_id/name` | Existing Cloud Map private namespace. |

Outputs: `endpoint` (`https://qdrant.<ns>:6333`), `discovery_fqdn`, `instance_id`,
`private_ip`, `data_volume_id`, `role_name`.

## Security posture

- **In transit:** TLS on 6333/6334 with a **self-signed** cert generated at boot.
  Self-signed rather than ACM because the store is internal-only and has no
  domain; consumers trust the cert or skip-verify in-VPC. In-transit encryption
  is *on*, unlike the ALB's documented no-TLS relaxation.
- **Config by environment variable**, not a mounted YAML: the bootstrap writes a
  root-only (`0600`) `QDRANT__*` env-file consumed via systemd `--env-file`. Env
  vars have the highest precedence and are always read, so the security-critical
  settings (TLS, API key) cannot be silently ignored the way a `production.yaml`
  could be if `RUN_MODE` did not load it.
- **At rest:** root and data volumes CMK-encrypted; when the API key is enabled it
  is fetched at boot and written only to the `0600` env-file on the encrypted
  volume — never into Terraform, state, or the cloud-init log (tracing is disabled
  around the secret).

### Deliberate relaxation: API-key auth (dev bring-up only)

When `secret_arn = ""` the host starts **auth-off** (no API key). This is a
**time-bounded** relaxation used only to validate the host, data volume, TLS and
discovery before the org-wide secrets pass sets the key — it is *not* the intended
end state (contrast qdrant §6/§6a, which require auth closed at provisioning).

- **What is still enforced:** TLS in transit; a **private subnet** with **no public
  IP**; **SG-to-SG ingress only** from consumer groups (no CIDR admit); egress to
  AWS services only. There is no real data in dev.
- **How to close it:** set `secret_arn` to the wired `genai-dev/qdrant/app` secret
  and re-apply. The bootstrap then enforces the key and the instance role gains a
  scoped secret-read. **This MUST be closed before any real data lands, and always
  in prod.** The running host logs `/var/log/qdrant-authoff-warning` while relaxed.
- **Network:** no public IP; ingress only from consumer SGs by reference (no
  CIDR); egress 443 to AWS services + DNS. Admin via SSM only, no SSH/key pair.
- **IMDS:** v2 required, **hop limit 2** — deliberately not 1, because the
  containerized Qdrant needs the instance-role credentials for the boot-time ECR
  pull and secret read; a container adds one hop.
- **Least privilege:** ECR pull and secret read are ARN-scoped to this host's own
  image and secret.

## Cost profile

~$5/mo compute on the shared 11:00–21:00 dev schedule (`t4g.small` at ~10 h/day)
+ ~$3/mo EBS (20 GB root + 20 GB data, gp3) ≈ **~$8/mo**. arm64 for the ~20%
Graviton saving. Scheduling is applied by a separate `scheduler/eventbridge`
component (chunk E), landing after the host is verified healthy always-on.

## Operational notes

- **Stop/start safe:** the data volume mounts by filesystem **label** (resilient
  to NVMe renaming), and `qdrant.service` (systemd) restarts the container every
  boot. Nothing load-bearing lives in one-shot cloud-init beyond first-boot setup.
- **Image is mirrored, not pulled from Docker Hub** — the pull rides the free S3
  gateway endpoint (no NAT dependency, no rate limit) and is pinned in-account.
- **Backups (planned):** the `data/backup` module targets `data_volume_id`;
  Qdrant snapshots to `/var/lib/qdrant/snapshots` can also sync to S3.
- **Prod would differ:** larger/always-on host, real HA (Qdrant clustering),
  ACM-issued TLS with a domain — see the design doc's revisit triggers.
