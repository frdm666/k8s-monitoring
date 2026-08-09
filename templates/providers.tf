terraform {
  required_version = ">= 1.5"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = "/root/.kube/lab-cluster.yaml"
  }
}

provider "kubernetes" {
  config_path = "/root/.kube/lab-cluster.yaml"
}
