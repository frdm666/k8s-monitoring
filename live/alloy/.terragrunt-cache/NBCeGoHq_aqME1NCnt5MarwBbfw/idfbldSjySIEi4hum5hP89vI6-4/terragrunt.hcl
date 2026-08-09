include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules/helm-release"
}

dependency "namespace" {
  config_path = "../namespace"

  mock_outputs = {
    namespace_name = "monitoring"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Alloy has nowhere to send logs until Loki exists, so the dependency
# is declared even though no output is consumed from it.
dependency "loki" {
  config_path = "../loki"

  mock_outputs = {
    release_name = "loki"
    namespace    = "monitoring"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  release_name  = "alloy"
  repository    = "https://grafana.github.io/helm-charts"
  chart         = "alloy"
  chart_version = "1.11.1"
  namespace     = dependency.namespace.outputs.namespace_name
  values_file   = "${get_terragrunt_dir()}/values.yaml"
}
