output "query_service_name" {
  description = "Service name Grafana should use as the Prometheus datasource"
  value       = kubernetes_service.query.metadata[0].name
}

output "namespace" {
  value = var.namespace
}
