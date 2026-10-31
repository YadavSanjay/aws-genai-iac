# compute/ingest-runner

An **on-demand** EC2 that runs a subsystem's batch/CLI pipeline. Built for the XbrlRag
ingest (Arelle → RDS facts, S3 filings, embeddings via RagInference → Qdrant), but
subsystem-agnostic.

## Purpose

Not a service. The bootstrap installs docker, renders the runtime env-files, and
pre-pulls the pipeline image; an operator then connects via **SSM Session Manager**
and runs the pipeline with the `arag-ingest` wrapper. Launch it, ingest, stop it —
it bills only while running, unlike a standing service.

## The image is a deploy, not a provision

**The image tag is not an input to this module.** `image_pointer_uri` names a small
S3 object holding one line:

```
ARAG_INGEST_IMAGE=<registry>/genai-dev/arag-ingest:arm64-<sha>
```

`arag-resolve-image` reads it on **every** `arag-ingest` invocation, so publishing a
new tag reaches an already-running host with no restart, and a stopped host picks it
up when next started.

This indirection is load-bearing, not ceremony. The instance carries
`user_data_replace_on_change = true`, so a tag rendered into user_data made every
image bump **replace the box** — a provisioning operation for what is really a
deploy, destroying the host's staged scratch data each time. It also let the pin
drift: the tag sat five commits behind the code that added the pipeline's own
entrypoints, and the failure surfaced only as `No such file or directory` partway
through an operator runbook.

Bump an image with:

```bash
AWS_PROFILE=genai-tf python scripts/deploy_arag_ingest_image.py --tag arm64-<sha>
```

The pointer is fetched with `aws s3 cp`, never `s3 sync` — two git-SHA tags are the
same length, so a bump does not change the object's size and `sync` would silently
skip it. Enforced by `tests/unit/test_ingest_image_decoupling.py`.

Distinct from `compute/ec2-app` on purpose: that module runs `docker compose up` on
every boot (a long-running stack); this one prepares a box and hands control to an
operator. Trying to force the ingest into the compose model would mean surgery on a
module every app tier shares.

## How to run (operator)

```bash
aws ssm start-session --target <instance-id> --region us-east-1
# on the host:
sudo arag-ingest python scripts/bootstrap_db.py --phase data --ticker NVDA
sudo arag-ingest python scripts/bootstrap_db.py --phase mv
```
The wrapper re-renders the secret env-file (so a rotated DB password is picked up),
logs in to ECR, and `docker run`s the image with `/opt/app/.env` (non-secret) +
`/opt/arag/.env` (secrets) + a `/var/lib/arag-scratch` mount. Then stop the box.

## Inputs (selected)

| Input | Notes |
|---|---|
| `image_pointer_uri` | `s3://…` object naming the image to run, read at **run** time. Never the image URI itself — see above. |
| `ecr_repository_arns` | Pull scope — the ingest repo only. |
| `secret_arns` / `db_secret_arn` / `db_secret_env_map` | App secret (verbatim) + RDS-managed JSON secret → env-file names. |
| `s3_bucket_arns` | **Read+WRITE** (the ingest downloads and writes filings), unlike the app tier's read-only bundle. |
| `runtime_env` | Non-secret endpoints/mode written to `/opt/app/.env`. |
| `instance_type` / `root_volume_gb` | `t4g.medium` / 40 GB scratch by default. |
| `imds_hop_limit` | `2` — the container runs boto3 and reaches the role through the docker bridge. |

## Security posture

- Private subnet, no public IP, no inbound rule; access is SSM only.
- Root volume CMK-encrypted; IMDSv2 enforced.
- Role ARN-scoped: pulls only its image, reads only its own secrets (+ the RDS
  managed secret via the boundary's `rds!` grant), read/writes only the filings
  bucket. The read+write S3 grant is the one broader-than-the-app-tier grant, and
  it's what ingest legitimately needs.
- Reuses the app-tier SG (already egresses to RDS/Qdrant/RagInference/443).

## Cost profile

`t4g.medium` ≈ $0.034/hr **only while running** — a few hours per ingest, then
stopped. 40 GB gp3 ≈ $3.20/mo for the (stopped) root volume is the idle floor.
