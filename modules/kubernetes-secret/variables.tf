variable "name" {
  description = "Secret name"
  type        = string
}

variable "namespace" {
  description = "Namespace the secret lives in"
  type        = string
}

variable "data" {
  description = "Key-value pairs stored in the secret"
  type        = map(string)
  sensitive   = true
}

variable "kubeconfig_path" {
  description = "Passed from root inputs, unused here"
  type        = string
  default     = ""
}
