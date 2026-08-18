resource "helm_release" "this" {
  name       = var.release_name
  repository = var.repository
  chart      = var.chart
  version    = var.chart_version
  namespace  = var.namespace

  # When values_vars is empty the file is read as-is. Otherwise it is
  # treated as a template, so non-secret values (chat IDs, hostnames)
  # can be injected without hardcoding them in the repository.
  values = var.values_file == "" ? [] : [
    length(var.values_vars) > 0
    ? templatefile(var.values_file, var.values_vars)
    : file(var.values_file)
  ]

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
