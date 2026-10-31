# Account-global components (not tied to dev/staging/prod). The root config
# (infra/root.hcl) resolves this via find_in_parent_folders("env.hcl").
locals {
  name        = "global"
  name_prefix = "genai"
}
