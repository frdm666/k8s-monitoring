include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules/kubernetes-secret"
}

dependency "namespace" {
  config_path = "../namespace"

  mock_outputs = {
    namespace_name = "monitoring"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name      = "telegram-bot-token"
  namespace = dependency.namespace.outputs.namespace_name

  # Read from the environment, never stored in the repository.
  # Alertmanager mounts this secret and reads the token from a file
  # rather than having it inlined in its config.
  data = {
    token = get_env("TELEGRAM_BOT_TOKEN")
  }
}
