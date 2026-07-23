# Mirrors ../locals.tf's workspace guard — this stack is meaningless
# without a specific environment selected (it reads that environment's
# cluster from remote state), so fail fast with an actionable message
# instead of silently doing nothing useful under the "default" workspace.

check "valid_workspace" {
  assert {
    condition     = terraform.workspace != "default"
    error_message = "No environment selected. Run `terraform workspace select dev` (or `terraform workspace new dev` the first time) before planning or applying — this must match the workspace you already applied in ../ (the root stack). See ../README.md and ./README.md."
  }
}
