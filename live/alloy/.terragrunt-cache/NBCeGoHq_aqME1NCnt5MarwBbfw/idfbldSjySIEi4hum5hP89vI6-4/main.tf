resource "helm_release" "this" {
  name       = var.release_name
  repository = var.repository
  chart      = var.chart
  version    = var.chart_version
  namespace  = var.namespace

  values = var.values_file == "" ? [] : [file(var.values_file)]

  dynamic "set_sensitive" {
    for_each = var.sensitive_values
    content {
      name  = set_sensitive.key
      value = set_sensitive.value
    }
  }

  timeout = var.timeout
  wait    = true
}
