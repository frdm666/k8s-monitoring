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
  name      = "thanos-objstore"
  namespace = dependency.namespace.outputs.namespace_name
  data = {
    "objstore.yml" = <<-EOT
      type: S3
      config:
        bucket: "thanos"
        endpoint: "minio.minio.svc.cluster.local:9000"
        access_key: "${get_env("MINIO_ACCESS_KEY")}"
        secret_key: "${get_env("MINIO_SECRET_KEY")}"
        insecure: true
    EOT
  }
}
