# dev / 10-security/secrets — secret containers.
#
# Phase 2b. Containers only: Terraform never holds the VALUES, because a secret
# in Terraform is a secret in the state file in plaintext forever. Set them out
# of band after apply — the module's set_value_commands output prints the exact
# commands.
#
# ONE secret PER APPLICATION, each holding all of that app's credentials, rather
# than one secret per key. Secrets Manager bills $0.40 per secret per month
# regardless of size, and an app needs all its own keys anyway. Four today:
# macrorag, qdrant, arag, qlp.
#
# Cost: $1.60/month (4 x $0.40).
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # `try`, not a ternary — see the note in infra/root.hcl.
  account_local_path = find_in_parent_folders("account.local.hcl", "")
  account_local      = try(read_terragrunt_config(local.account_local_path).locals, {})
  merged             = merge(local.account, local.account_local)

  # The MacroRAG instance role's ARN, constructed from known values (the role
  # name is deterministic: <prefix>-<app>). Constructed rather than taken as a
  # dependency because 41-macrorag/app depends on THIS component — a dependency
  # back would be a cycle. aws:PrincipalArn resolves an assumed-role session to
  # this role ARN, so it is what the reader deny excepts.
  macrorag_role_arn = "arn:aws:iam::${local.merged.account_id}:role/${local.env.name_prefix}-macrorag"

  # The ARag app-tier instance role ARN (deterministic <prefix>-<app>), same
  # construct-not-depend rationale as macrorag above (42-arag/app will depend on
  # THIS component, so a dependency back would be a cycle).
  arag_role_arn = "arn:aws:iam::${local.merged.account_id}:role/${local.env.name_prefix}-arag"

  # The ARag ingest runner's instance role (42-arag/ingest) — a SEPARATE role
  # from the app tier above, and it reads the same credentials because ingest
  # embeds (Jina/OpenAI keys) just as query does.
  #
  # It must be named explicitly: the reader deny tests ArnNotLike, which without
  # a wildcard does NOT treat "<prefix>-arag" as covering "<prefix>-arag-ingest".
  # Listing the second ARN rather than globbing "<prefix>-arag*" keeps the
  # exception set enumerable — a glob would silently admit every future role
  # whose name starts with the app's.
  arag_ingest_role_arn = "arn:aws:iam::${local.merged.account_id}:role/${local.env.name_prefix}-arag-ingest"

  # The Faultline app-tier instance role (Q3 of the Faultline rollout),
  # same deterministic <prefix>-<app> construct and the same construct-not-depend
  # rationale as the two above.
  #
  # LOAD-BEARING: Q5 must create the host with app_name = "qlp" exactly. The deny
  # tests ArnNotLike with no wildcard, so a host role named anything else is
  # refused its own credentials — and because that refusal lands inside cloud-init
  # under `set -euo pipefail`, the box boots, aborts before pulling an image, and
  # leaves nothing on disk explaining why. That is precisely how ARag's ingest
  # runner failed (its role was <prefix>-arag-ingest, which <prefix>-arag does not
  # cover). One role only here: the v1 scope is the serving stack, with no
  # separate batch runner.
  qlp_role_arn = "arn:aws:iam::${local.merged.account_id}:role/${local.env.name_prefix}-qlp"
}

dependency "kms" {
  config_path = "../kms"

  mock_outputs = {
    key_arn = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/security/secrets"
}

inputs = {
  secrets = {
    "${local.env.name_prefix}/macrorag/app" = {
      description = "MacroRAG application credentials (LLM + data-source API keys). KEY=value lines (compose env_file format); set out of band."

      # Second gate in front of the values: only the MacroRAG instance role may
      # GetSecretValue, enforced as a deny-with-exception. PER SECRET — it does
      # NOT touch the qdrant secret below, whose owner is a different role.
      reader_role_arn_patterns = [local.macrorag_role_arn]
    }
    # Shared Qdrant API key. Qdrant ships auth-off by default; the bootstrap reads
    # this at start and enforces it, closing that default (qdrant §6a/§6). JSON
    # object {api_key}; set out of band, never in tfvars or state.
    #
    # No reader_role_arn_patterns yet: Qdrant is auth-off so nothing reads this,
    # and naming the Qdrant host role here belongs with the phase-2 auth close
    # (see qdrant-rollout). IAM-only until then.
    "${local.env.name_prefix}/qdrant/app" = {
      description = "Shared Qdrant vector store API key. JSON object {api_key}; set out of band."
    }
    # ARag application credentials (A3 of the ARag rollout). Query-time OpenAI +
    # Jina API keys, KEY=value lines (compose env_file), set out of band. The
    # DATABASE credential is deliberately NOT here: RDS uses an AWS-managed
    # master-user secret (A4) that the app reads directly, so the password stays
    # out of Terraform state and rotates on RDS's schedule rather than being copied
    # into a second place that can drift. Reader deny excepts ONLY the two ARag
    # roles (per-secret, does not touch macrorag/qdrant above).
    "${local.env.name_prefix}/arag/app" = {
      description              = "ARag application credentials (OpenAI + Jina API keys). KEY=value lines (compose env_file); set out of band. DB creds come from the RDS-managed secret (A4), not here."
      reader_role_arn_patterns = [local.arag_role_arn, local.arag_ingest_role_arn]
    }
    # Faultline application credentials (Q3 of the Faultline rollout).
    # KEY=value lines rendered verbatim into /opt/qlp/.env, which its compose
    # stack loads via env_file. Four keys, and the EXACT names matter:
    #
    #   PRICER_API_KEY   X-API-Key on the pricer FastAPI service. Unset = the
    #                    middleware is a no-op, i.e. an unauthenticated API.
    #   QLP_WRITE_TOKEN  gate on the BFF's four gated writes (limits, sign-off,
    #                    jobs, sizing-activate). Unset = the writes are open.
    #   OPENAI_API_KEY   scenariogen narrative + LLM flow. UN-prefixed: the code
    #                    reads os.environ["OPENAI_API_KEY"] directly.
    #   FRED_API_KEY     market-data ingest. ALSO un-prefixed. The app's
    #                    .env.example documents PRICER_FRED_API_KEY, but that
    #                    name belongs to a settings object the pricing module
    #                    does not use; the downloaders read the un-prefixed name
    #                    via marketdata.common.settings.load_credentials(). Get
    #                    this wrong and ingest runs KEYLESS AND SILENT — a
    #                    missing source key only disables that source.
    #
    # The other five un-prefixed source keys (STOOQ_API_KEY, FINRA_API_KEY,
    # FINRA_API_KEY_SECRET, EIA_API_KEY, OPENFIGI_API_KEY) belong in this same
    # secret if those feeds are ever used: Secrets Manager bills per secret, not
    # per key, so adding one is an out-of-band value edit and needs no infra
    # change. ARAG_API_KEY / MACRORAG_API_KEY are deliberately absent — dev
    # reaches both services over the network boundary with no auth.
    "${local.env.name_prefix}/qlp/app" = {
      description              = "QuantLibPricer application credentials (PRICER_API_KEY, QLP_WRITE_TOKEN, OPENAI_API_KEY, FRED_API_KEY). KEY=value lines (compose env_file); set out of band."
      reader_role_arn_patterns = [local.qlp_role_arn]
    }
  }

  kms_key_arn = dependency.kms.outputs.key_arn

  # dev: short window. A pending deletion blocks recreating the same name, which
  # makes repeated teardown painful. prod must use 30 and never 0.
  recovery_window_days = 7

  # reader_role_arn_patterns is intentionally empty for now: the application
  # role does not exist yet, and a resource policy naming a non-existent
  # principal would deny everything including our own verification. Set it when
  # the MacroRAG instance role lands in Phase 3 — that is the point at which the
  # second gate becomes meaningful rather than merely restrictive.
}
