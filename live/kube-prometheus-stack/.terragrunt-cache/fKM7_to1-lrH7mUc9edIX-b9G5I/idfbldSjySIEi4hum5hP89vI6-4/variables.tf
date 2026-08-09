variable "release_name" {
  type = string
}

variable "repository" {
  type = string
}

variable "chart" {
  type = string
}

variable "chart_version" {
  type = string
}

variable "namespace" {
  type = string
}

variable "values_file" {
  description = "Path to a values file, empty for chart defaults"
  type        = string
  default     = ""
}

variable "sensitive_values" {
  description = "Values passed via set_sensitive, kept out of plan output"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "timeout" {
  type    = number
  default = 900
}

variable "kubeconfig_path" {
  type    = string
  default = ""
}
