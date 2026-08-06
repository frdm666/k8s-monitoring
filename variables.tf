variable "kubeconfig_path" {
  description = "Путь к kubeconfig целевого кластера"
  type        = string
  default     = "/root/.kube/lab-cluster.yaml"
}

variable "namespace" {
  description = "Namespace для стека мониторинга"
  type        = string
  default     = "monitoring"
}

variable "chart_version" {
  description = "Версия чарта kube-prometheus-stack"
  type        = string
}

variable "grafana_admin_password" {
  description = "Пароль администратора Grafana"
  type        = string
  sensitive   = true
}

variable "grafana_node_port" {
  description = "NodePort для доступа к Grafana"
  type        = number
  default     = 30300
}
