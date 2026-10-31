# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue. On the repository's **Security**
tab, choose **Report a vulnerability**. That opens a private advisory only the maintainer can see.

Include what you found, where it is, and how to reproduce it. This is a personal project, so there
is no response-time commitment, but reports are read and taken seriously.

## Scope

**In scope:**

- Terraform modules and Terragrunt composition under `infra/`
- The IAM policies, permissions boundary and exec-role model
- The agent guards in `scripts/` and their hook wiring in `.claude/settings.json`
- `scripts/check_public_safe.py` and anything that lets a real identifier past it
- Python code under `src/` and `ui/`

**Out of scope:**

- The applications this repo deploys (MacroRAG, XbrlRag, Faultline, RagInference). They live in
  their own repositories.
- Probing any live AWS environment. The maintainer's account isn't part of this repository, and
  testing against it isn't permitted.

Only the `main` branch is supported.

## What this repository holds

No credentials, account ids or real resource ids are committed. Account-specific values live in
gitignored local files, and runtime secrets live in AWS Secrets Manager and SSM Parameter Store.
`scripts/check_public_safe.py` enforces this in pre-commit and CI, and gitleaks scans full history
in CI.

If you find a real identifier or secret here, please report it as above.

## Accepted dev relaxations

The `dev` environment makes a few deliberate cost and simplicity trade-offs. They aren't
vulnerabilities in themselves, and each is stated in the relevant module README or design document,
along with its compensating control. If you think a stated relaxation is unsafe, that is still a
useful report.
