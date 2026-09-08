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

# Alertmanager mounts this secret, so it must exist first.
dependency "telegram_secret" {
  config_path = "../telegram-secret"

  mock_outputs = {
    secret_name = "telegram-bot-token"
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

  # Not a secret in the strict sense, but kept out of the repository
  # so the private channel is not exposed in git history.
  values_vars = {
    telegram_chat_id = get_env("TELEGRAM_CHAT_ID")
  }

  sensitive_values = {
    "grafana.adminPassword" = get_env("GRAFANA_ADMIN_PASSWORD")
  }
}
