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

inputs = {
  release_name  = "kube-prometheus-stack"
  repository    = "https://prometheus-community.github.io/helm-charts"
  chart         = "kube-prometheus-stack"
  chart_version = "88.1.5"
  namespace     = dependency.namespace.outputs.namespace_name
  values_file   = "${get_terragrunt_dir()}/values.yaml"

  sensitive_values = {
    "grafana.adminPassword" = get_env("GRAFANA_ADMIN_PASSWORD")
  }
}
