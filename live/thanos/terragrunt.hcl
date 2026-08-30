include "root" {
  path = find_in_parent_folders("root.hcl")
}
terraform {
  source = "${get_repo_root()}/modules/thanos"
}
dependency "namespace" {
  config_path = "../namespace"
  mock_outputs = {
    namespace_name = "monitoring"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}
# The bucket credentials must exist before Thanos tries to mount them.
dependency "thanos_secret" {
  config_path = "../thanos-secret"
  mock_outputs = {
    secret_name = "thanos-objstore"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}
inputs = {
  namespace            = dependency.namespace.outputs.namespace_name
  objstore_secret_name = dependency.thanos_secret.outputs.secret_name
}
