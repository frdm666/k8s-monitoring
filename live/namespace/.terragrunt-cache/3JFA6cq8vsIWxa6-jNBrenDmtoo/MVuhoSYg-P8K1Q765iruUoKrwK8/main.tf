resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }

  # Rancher's controller injects its own annotations after the namespace
  # is created. Without ignoring them, every apply would strip them and
  # Rancher would add them back — a diff that never converges.
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}
