# Store Gateway serves historical blocks from the S3 bucket.
# StatefulSet, not Deployment: it keeps a local index cache on disk
# that should survive a restart.
resource "kubernetes_stateful_set" "storegateway" {
  metadata {
    name      = "thanos-storegateway"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "thanos"
      "app.kubernetes.io/component" = "storegateway"
    }
  }

  spec {
    service_name = "thanos-storegateway"
    replicas     = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name"      = "thanos"
        "app.kubernetes.io/component" = "storegateway"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "thanos"
          "app.kubernetes.io/component" = "storegateway"
        }
      }

      spec {
        container {
          name  = "storegateway"
          image = var.image

          args = [
            "store",
            "--data-dir=/data",
            "--objstore.config-file=/conf/objstore.yml",
            "--http-address=0.0.0.0:10902",
            "--grpc-address=0.0.0.0:10901",
          ]

          port {
            name           = "http"
            container_port = 10902
          }
          port {
            name           = "grpc"
            container_port = 10901
          }

          volume_mount {
            name       = "objstore-config"
            mount_path = "/conf"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "objstore-config"
          secret {
            secret_name = var.objstore_secret_name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "local-path"
        resources {
          requests = {
            storage = var.storegateway_storage_size
          }
        }
      }
    }
  }
}
# Compactor compacts and downsamples blocks in the bucket, and applies
# retention. Prometheus has disableCompaction set, so this is the only
# component doing that work now.
#
# Single replica by design: running two compactors against the same
# bucket corrupts data. This is a hard constraint from Thanos itself,
# not a lab shortcut.
resource "kubernetes_stateful_set" "compactor" {
  metadata {
    name      = "thanos-compactor"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "thanos"
      "app.kubernetes.io/component" = "compactor"
    }
  }

  spec {
    service_name = "thanos-compactor"
    replicas     = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name"      = "thanos"
        "app.kubernetes.io/component" = "compactor"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "thanos"
          "app.kubernetes.io/component" = "compactor"
        }
      }

      spec {
        container {
          name  = "compactor"
          image = var.image

          args = [
            "compact",
            "--wait",
            "--data-dir=/data",
            "--objstore.config-file=/conf/objstore.yml",
            "--http-address=0.0.0.0:10902",
            "--retention.resolution-raw=7d",
            "--retention.resolution-5m=30d",
            "--retention.resolution-1h=90d",
          ]

          port {
            name           = "http"
            container_port = 10902
          }

          volume_mount {
            name       = "objstore-config"
            mount_path = "/conf"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "objstore-config"
          secret {
            secret_name = var.objstore_secret_name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "local-path"
        resources {
          requests = {
            storage = var.compactor_storage_size
          }
        }
      }
    }
  }
}
# Query fans out to all StoreAPI endpoints and merges the results.
# --query.replica-label lets it deduplicate metrics coming from
# multiple Prometheus replicas scraping the same targets.
resource "kubernetes_deployment" "query" {
  metadata {
    name      = "thanos-query"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "thanos"
      "app.kubernetes.io/component" = "query"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name"      = "thanos"
        "app.kubernetes.io/component" = "query"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "thanos"
          "app.kubernetes.io/component" = "query"
        }
      }

      spec {
        container {
          name  = "query"
          image = var.image

          args = [
            "query",
            "--http-address=0.0.0.0:9090",
            "--grpc-address=0.0.0.0:10901",
            "--query.replica-label=prometheus_replica",
            "--endpoint=dnssrv+_grpc._tcp.thanos-storegateway.${var.namespace}.svc.cluster.local",
            "--endpoint=dnssrv+_grpc._tcp.kube-prometheus-stack-thanos-discovery.${var.namespace}.svc.cluster.local",
          ]

          port {
            name           = "http"
            container_port = 9090
          }
          port {
            name           = "grpc"
            container_port = 10901
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
}
# Headless service: Query resolves individual Store Gateway pods
# through its SRV records, so a single virtual IP would not work here.
resource "kubernetes_service" "storegateway" {
  metadata {
    name      = "thanos-storegateway"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "thanos"
      "app.kubernetes.io/component" = "storegateway"
    }
  }

  spec {
    cluster_ip = "None"

    selector = {
      "app.kubernetes.io/name"      = "thanos"
      "app.kubernetes.io/component" = "storegateway"
    }

    port {
      name        = "grpc"
      port        = 10901
      target_port = 10901
    }
    port {
      name        = "http"
      port        = 10902
      target_port = 10902
    }
  }
}

# Regular ClusterIP: Grafana talks to Query like any other datasource.
resource "kubernetes_service" "query" {
  metadata {
    name      = "thanos-query"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "thanos"
      "app.kubernetes.io/component" = "query"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name"      = "thanos"
      "app.kubernetes.io/component" = "query"
    }

    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
  }
}
