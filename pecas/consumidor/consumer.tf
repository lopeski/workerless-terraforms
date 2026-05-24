terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
  }
}

# Assume que o cluster (k3d-local-rock) já foi provisionado pelo Terraform de Plataforma
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "k3d-local-rock"
}

# -------------------------------------------------------------------------
# Governança de Recursos do Consumidor (namespace: default)
# -------------------------------------------------------------------------

resource "kubernetes_limit_range" "default_ns" {
  metadata {
    name      = "worker-limits"
    namespace = "default"
  }

  spec {
    limit {
      type = "Container"
      max = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default = {
        cpu    = "250m"
        memory = "256Mi"
      }
      default_request = {
        cpu    = "100m"
        memory = "128Mi"
      }
    }
  }
}

resource "kubernetes_resource_quota" "default_ns" {
  metadata {
    name      = "worker-quota"
    namespace = "default"
  }

  spec {
    hard = {
      "requests.cpu"    = "2"
      "requests.memory" = "1Gi"
      "limits.cpu"      = "5"
      "limits.memory"   = "5Gi"
      "pods"            = "15"
    }
  }
}

# -------------------------------------------------------------------------
# Segurança de Rede do Consumidor
# -------------------------------------------------------------------------

resource "kubernetes_manifest" "netpol_default_deny" {
  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = {
      "name"      = "default-deny-all"
      "namespace" = "default"
    }
    "spec" = {
      "podSelector" = {}
      "policyTypes" = ["Ingress", "Egress"]
    }
  }
}

resource "kubernetes_manifest" "netpol_worker_egress" {
  depends_on = [kubernetes_manifest.netpol_default_deny]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = {
      "name"      = "worker-egress-allow"
      "namespace" = "default"
    }
    "spec" = {
      "podSelector" = {
        "matchLabels" = { "app" = "worker-consumidor" }
      }
      "policyTypes" = ["Egress"]
      "egress" = [
        # RabbitMQ
        {
          "to" = [{
            "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "brokers" } }
          }]
          "ports" = [{ "port" = 5672, "protocol" = "TCP" }]
        },
        # DNS
        {
          "to" = [{
            "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "kube-system" } }
          }]
          "ports" = [
            { "port" = 53, "protocol" = "UDP" },
            { "port" = 53, "protocol" = "TCP" }
          ]
        },
        # Internet pública
        {
          "to" = [{
            "ipBlock" = {
              "cidr" = "0.0.0.0/0"
              "except" = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
            }
          }]
          "ports" = [
            { "port" = 80,  "protocol" = "TCP" },
            { "port" = 443, "protocol" = "TCP" },
            { "port" = 587, "protocol" = "TCP" },
            { "port" = 465, "protocol" = "TCP" }
          ]
        },
        # Banco de estado
        {
          "to" = [{
            "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "state-db" } }
          }]
          "ports" = [{ "port" = 5432, "protocol" = "TCP" }]
        }
      ]
    }
  }
}

# -------------------------------------------------------------------------
# Aplicação: Deploy do Worker
# -------------------------------------------------------------------------

resource "kubernetes_deployment" "worker_app" {
  depends_on = [
    kubernetes_limit_range.default_ns,
    kubernetes_resource_quota.default_ns,
    kubernetes_manifest.netpol_worker_egress,
  ]

  metadata {
    name      = "worker-consumidor"
    namespace = "default"
  }

  spec {
    replicas = 1 # O KEDA controlará as réplicas reais

    selector {
      match_labels = {
        app = "worker-consumidor"
      }
    }

    template {
      metadata {
        labels = {
          app = "worker-consumidor"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
        }
      }
      spec {
        # Conta que a classe do gVisor já foi instalada pelo TF base
        runtime_class_name = "gvisor"

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          image = "sua-imagem-worker:latest"
          name  = "worker"

          env {
            name  = "RABBITMQ_CONNECTION_STRING"
            value = "amqp://user:password@rabbitmq.brokers.svc.cluster.local:5672/"
          }

          env {
            name  = "STATE_DB_URL"
            value = "postgresql://stateuser:statepass@postgres-state-db-postgresql.state-db.svc.cluster.local:5432/k3d_state"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}

# -------------------------------------------------------------------------
# Escalabilidade: KEDA ScaledObject
# -------------------------------------------------------------------------

resource "kubernetes_manifest" "keda_rabbitmq_scaler" {
  depends_on = [kubernetes_deployment.worker_app]

  manifest = {
    "apiVersion" = "keda.sh/v1alpha1"
    "kind"       = "ScaledObject"
    "metadata" = {
      "name"      = "rabbitmq-scaledobject"
      "namespace" = "default"
    }
    "spec" = {
      "scaleTargetRef" = {
        "name" = kubernetes_deployment.worker_app.metadata[0].name
      }
      "minReplicaCount" = 0
      "maxReplicaCount" = 10
      "triggers" = [
        {
          "type" = "rabbitmq"
          "metadata" = {
            "queueName"   = "minha-fila-de-eventos"
            "mode"        = "QueueLength"
            "value"       = "5"
            "hostFromEnv" = "RABBITMQ_CONNECTION_STRING"
          }
        }
      ]
    }
  }
}
