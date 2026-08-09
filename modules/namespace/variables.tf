variable "namespace" {
  description = "Namespace to create"
  type        = string
}

variable "kubeconfig_path" {
  description = "Passed from root inputs, unused here"
  type        = string
  default     = ""
}
