locals {
  kubeconfig_path = "/root/.kube/lab-cluster.yaml"
  namespace       = "monitoring"
}

remote_state {
  backend = "local"
  config = {
    path = "${get_repo_root()}/state/${path_relative_to_include()}/terraform.tfstate"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = file("${get_repo_root()}/templates/providers.tf")
}

inputs = {
  kubeconfig_path = local.kubeconfig_path
  namespace       = local.namespace
}
