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
  release_name  = "loki"
  repository    = "https://grafana.github.io/helm-charts"
  chart         = "loki"
  chart_version = "7.2.0"
  namespace     = dependency.namespace.outputs.namespace_name
  values_file   = "${get_terragrunt_dir()}/values.yaml"
  values_vars = {
    minio_access_key = get_env("MINIO_ACCESS_KEY")
  }
  sensitive_values = {
    "loki.storage.s3.secretAccessKey" = get_env("MINIO_SECRET_KEY")
  }
}
