# Runbook — bootstrap the XbrlRag RDS schema from a local machine

Apply the XbrlRag `xbrl_db` **schema** (Arelle public tables + `pg_trgm` + Layer-0 +
audit) to the private RDS instance `genai-dev-arag`, from a Windows laptop, over an
SSM tunnel. This is the one-time step that makes the DB usable; the **data** and
**materialized-view** phases (the actual ingest) are heavier and belong on the
in-VPC ingest runner (see A7), not on a laptop over a tunnel.

Related: XbrlRag repo `docs/guides/xbrl-flow/02-postgres-setup.md` (authoritative DDL
procedure), `scripts/bootstrap_db.py`. IaC: [`arag-rollout-plan.md`](../design/arag-rollout-plan.md).

## When / prerequisites

- **The NAT must be up.** RDS is private and reached only through an SSM tunnel via
  an in-VPC host; that host's SSM agent egresses through the NAT, which is scheduled
  **10:00–21:00 ET** (`00-networking/nat-schedule`). Off-window the whole private
  estate is SSM-dark and the tunnel is refused. Run this in-window, or start the NAT
  manually (admin) and stop it after.
- The XbrlRag app host (`genai-dev-arag`) is running and SSM-online (it is the tunnel
  hop). Confirm with `aws ssm describe-instance-information`.
- Local: the XbrlRag repo checked out, the `py312` conda env (`psycopg2`), and the AWS
  CLI **Session Manager plugin**.
- **No `psql` required** — every step runs host-side in `py312`.

> **Docker does NOT work for this.** A container reaching the tunnel via
> `host.docker.internal` arrives on a different host interface than the SSM tunnel's
> `127.0.0.1` bind, so it either hangs or drops mid-handshake. Run everything on the
> host, where `localhost:15432` is the tunnel's exact address.

## 1. Credentials + tunnel (admin shell — keep open)

```powershell
$env:AWS_PROFILE = '<admin-profile>'   # admin: can read the rds! managed secret + start SSM sessions
$region = 'us-east-1'

# Resolve by tag/api so this survives instance/endpoint churn.
$app = aws ec2 describe-instances --filters "Name=tag:Name,Values=genai-dev-arag" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text --region $region
$rds = aws rds describe-db-instances --db-instance-identifier genai-dev-arag --query "DBInstances[0].Endpoint.Address" --output text --region $region
$arn = aws rds describe-db-instances --db-instance-identifier genai-dev-arag --query "DBInstances[0].MasterUserSecret.SecretArn" --output text --region $region
$sec = aws secretsmanager get-secret-value --secret-id $arn --query SecretString --output text --region $region | ConvertFrom-Json
$sec.username     # arag_admin
$sec.password     # copy for step 2

# Tunnel: localhost:15432 -> RDS:5432, through the app host. Leave this running.
aws ssm start-session --target $app `
  --document-name AWS-StartPortForwardingSessionToRemoteHost `
  --parameters host="$rds",portNumber="5432",localPortNumber="15432" `
  --region $region
```

Wait for **`Waiting for connections...`**.

## 2. Apply the schema (XbrlRag repo — a second shell)

```powershell
cd <xbrlrag-checkout>
$env:XBRL_DB_HOST='localhost'; $env:XBRL_DB_PORT='15432'; $env:XBRL_DB_NAME='xbrl_db'
$env:XBRL_DB_USER='arag_admin'; $env:XBRL_DB_PASSWORD='<paste $sec.password>'; $env:XBRL_DB_SSLMODE='require'
```

`XBRL_DB_SSLMODE=require` satisfies RDS `force_ssl=1`; over the tunnel, `require`
negotiates TLS without hostname verification (the endpoint the client sees is
`localhost`), which is correct.

**2a. Connectivity check** (must print `connected` before continuing):
```powershell
conda run -n py312 python -c "import os,psycopg2; c=psycopg2.connect(host=os.environ['XBRL_DB_HOST'],port=int(os.environ['XBRL_DB_PORT']),dbname=os.environ['XBRL_DB_NAME'],user=os.environ['XBRL_DB_USER'],password=os.environ['XBRL_DB_PASSWORD'],sslmode=os.environ['XBRL_DB_SSLMODE']); print('connected'); c.close()"
```
`Connection refused` here means the tunnel is down (NAT off, or the session died) —
re-open step 1.

**2b. The `postgres` role.** The vendored Arelle base dump carries 227
`ALTER … OWNER TO postgres`; RDS's master user is `arag_admin`, so a role literally
named `postgres` must exist and `arag_admin` must be a member:
```powershell
conda run -n py312 python -c "import os,psycopg2; c=psycopg2.connect(host=os.environ['XBRL_DB_HOST'],port=int(os.environ['XBRL_DB_PORT']),dbname=os.environ['XBRL_DB_NAME'],user=os.environ['XBRL_DB_USER'],password=os.environ['XBRL_DB_PASSWORD'],sslmode=os.environ['XBRL_DB_SSLMODE']); c.autocommit=True; k=c.cursor(); k.execute('CREATE ROLE postgres'); k.execute('GRANT postgres TO arag_admin'); print('postgres role ready'); c.close()"
```
(If it reports the role already exists, run just the `GRANT`.)

**2c. Base Arelle public schema.** The dump inlines 33 `pgcrypto` functions as
`CREATE FUNCTION … LANGUAGE c`, which **RDS refuses for non-superusers**. `psql`
continues past them by default; `bootstrap_db.py --with-base` does NOT (it sends the
whole file in one `execute()` and aborts on the first error) — so DO NOT use
`--with-base` against RDS. Apply the base file leniently instead. Two options:

- **If you have `psql`** (native, on the host — not in Docker):
  ```powershell
  $env:PGPASSWORD=$env:XBRL_DB_PASSWORD
  psql -h localhost -p 15432 -U arag_admin -d xbrl_db -f scripts/ddl/base/xbrlPublicPostgresDB.ddl
  ```
- **No `psql`** — save the statement-splitting applier in Appendix A as
  `apply_base_lenient.py` in the repo root and run:
  ```powershell
  conda run -n py312 python apply_base_lenient.py scripts/ddl/base/xbrlPublicPostgresDB.ddl
  ```

Expected result: **~67 failures, ALL of them `pgcrypto`** — 33
`permission denied for language c`, 33 `ALTER FUNCTION … does not exist` (the owner
change on each function that failed to create), and 1 empty-query comment block.
Nothing in the XbrlRag schema should fail. XbrlRag never calls `armor`/`crypt`/`digest`/
`gen_salt`/`hmac`/`pgp_*`, so their absence is a non-issue. If anything *else*
errors, stop and investigate.

**2d. Extensions + Layer-0 + audit** (`base` auto-skips without `--with-base`):
```powershell
conda run -n py312 python scripts/bootstrap_db.py --phase schema --plan   # preview: base=SKIP, then extensions/layer0/audit
conda run -n py312 python scripts/bootstrap_db.py --phase schema          # apply
```
Ends with `Bootstrap complete`. `xbrl_db` now has the full schema.

## 3. Cleanup

```powershell
# second shell:
Remove-Item Env:\XBRL_DB_PASSWORD
Remove-Item apply_base_lenient.py       # if you used the no-psql applier
# admin shell: Ctrl-C the tunnel, then (only if you started the NAT off-schedule):
aws ec2 stop-instances --instance-ids $nat --region us-east-1   # $nat from describe-instances by tag
```

## Notes

- **Only the schema is done here.** The DB has no facts, so XbrlRag answers
  structurally but returns nothing until an ingest runs. The `data` and `mv` phases
  (`bootstrap_db.py --phase data` / `--phase mv`) are the ingest — run them on the
  in-VPC ingest runner (A7), which reaches RDS/Qdrant/RagInference directly and is
  the right place to validate the CL #4d silent-empty-vector-load bug.
- The tunnel carries the Postgres/TLS connection *inside* the encrypted SSM channel;
  the app host forwards it to RDS over the private network. No RDS public exposure.

## Appendix A — `apply_base_lenient.py` (no-psql base applier)

A dependency-free statement splitter (dollar-quote / string / comment aware) that
runs each statement in its own `try/except`, so a `LANGUAGE c` rejection does not
abort the file. Save in the XbrlRag repo root; delete after use.

```python
"""Apply a .sql dump statement-by-statement, continuing past errors."""
from __future__ import annotations
import os, sys, psycopg2


def split_sql(text: str) -> list[str]:
    stmts: list[str] = []
    buf: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text[i:i + 2] == "--":                      # line comment
            j = text.find("\n", i); j = n if j == -1 else j
            buf.append(text[i:j]); i = j; continue
        if text[i:i + 2] == "/*":                      # block comment
            j = text.find("*/", i + 2); j = n if j == -1 else j + 2
            buf.append(text[i:j]); i = j; continue
        if c == "'":                                    # single-quoted string
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if text[j:j + 2] == "''":
                        j += 2; continue
                    j += 1; break
                j += 1
            buf.append(text[i:j]); i = j; continue
        if c == "$":                                    # dollar-quote ($$ / $tag$)
            k = i + 1
            while k < n and (text[k].isalnum() or text[k] == "_"):
                k += 1
            if k < n and text[k] == "$":
                tag = text[i:k + 1]
                j = text.find(tag, k + 1); j = n if j == -1 else j + len(tag)
                buf.append(text[i:j]); i = j; continue
        if c == ";":                                    # statement end
            s = "".join(buf).strip()
            if s:
                stmts.append(s)
            buf = []; i += 1; continue
        buf.append(c); i += 1
    tail = "".join(buf).strip()
    if tail:
        stmts.append(tail)
    return stmts


def main() -> int:
    with open(sys.argv[1], encoding="utf-8-sig") as fh:   # utf-8-sig: dump has a BOM
        stmts = split_sql(fh.read())
    conn = psycopg2.connect(
        host=os.environ.get("XBRL_DB_HOST", "localhost"),
        port=int(os.environ.get("XBRL_DB_PORT", "5432")),
        dbname=os.environ.get("XBRL_DB_NAME", "xbrl_db"),
        user=os.environ["XBRL_DB_USER"],
        password=os.environ["XBRL_DB_PASSWORD"],
        sslmode=os.environ.get("XBRL_DB_SSLMODE", "require"),
    )
    conn.autocommit = True
    ok = 0
    failures: list[tuple[str, str]] = []
    with conn.cursor() as cur:
        for s in stmts:
            try:
                cur.execute(s); ok += 1
            except Exception as exc:                      # report + continue, by design
                failures.append((s.splitlines()[0][:90], str(exc).splitlines()[0]))
    conn.close()
    print(f"\napplied: {ok} ok, {len(failures)} failed, {len(stmts)} total")
    if failures:
        print("\nFAILED (expect ONLY pgcrypto LANGUAGE c):")
        for first, err in failures:
            print(f"  - {first!r}\n      -> {err}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```
