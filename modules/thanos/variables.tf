variable "namespace" {
  description = "Namespace to deploy Thanos components into"
  type        = string
}

variable "image" {
  description = "Thanos image. Official upstream image, not Bitnami: Bitnami removed most versioned tags from their public registry."
  type        = string
  default     = "quay.io/thanos/thanos:v0.39.2"
}

variable "objstore_secret_name" {
  description = "Secret holding objstore.yml with the S3 bucket configuration"
  type        = string
}

variable "storegateway_storage_size" {
  description = "PVC size for the Store Gateway local cache"
  type        = string
  default     = "5Gi"
}

variable "compactor_storage_size" {
  description = "PVC size for the Compactor working directory"
  type        = string
  default     = "5Gi"
}
