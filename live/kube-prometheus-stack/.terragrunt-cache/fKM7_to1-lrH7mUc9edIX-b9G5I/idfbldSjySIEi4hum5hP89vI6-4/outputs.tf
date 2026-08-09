output "release_name" {
  value = helm_release.this.name
}

output "namespace" {
  value = helm_release.this.namespace
}
