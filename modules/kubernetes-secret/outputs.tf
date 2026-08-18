output "secret_name" {
  description = "Name of the created secret"
  value       = kubernetes_secret.this.metadata[0].name
}
