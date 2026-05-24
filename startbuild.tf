terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
  }
}

# 1. Provisiona o cluster Kubernetes via k3d
resource "null_resource" "k3d_cluster" {
  provisioner "local-exec" {
    command = "k3d cluster create local-rock --api-port 6550 --servers 1 --agents 1 --wait"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete local-rock"
  }
}

# 2. Configura os providers
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "k3d-local-rock"
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "k3d-local-rock"
}

# -------------------------------------------------------------------------
# Instalação do gVisor no Cluster
# -------------------------------------------------------------------------

# 2.1 Aplica o DaemonSet oficial do Google para instalar o gVisor no containerd
resource "null_resource" "gvisor_installer" {
  depends_on = [null_resource.k3d_cluster]

  provisioner "local-exec" {
    command = "kubectl apply -f https://raw.githubusercontent.com/google/gvisor/master/k8s/manifests/install/containerd/gvisor-containerd.yaml --context k3d-local-rock"
  }

  # Tempo de espera para garantir que os Pods do DaemonSet configurem os nós
  provisioner "local-exec" {
    command = "sleep 15"
  }
}

# 2.2 Cria a classe de runtime que será usada pelas aplicações
resource "kubernetes_runtime_class_v1" "gvisor" {
  depends_on = [null_resource.gvisor_installer]

  metadata {
    name = "gvisor"
  }

  handler = "runsc"
}

# -------------------------------------------------------------------------
# Segurança de Rede: NetworkPolicies (namespace: default)
# -------------------------------------------------------------------------

# Bloqueia todo tráfego de entrada e saída por padrão
resource "kubernetes_manifest" "netpol_default_deny" {
  depends_on = [null_resource.k3d_cluster]

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

# Permite saída apenas para: RabbitMQ, DNS e internet pública (sem IPs privados/metadados)
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
        # RabbitMQ no namespace brokers
        {
          "to" = [{
            "namespaceSelector" = {
              "matchLabels" = { "kubernetes.io/metadata.name" = "brokers" }
            }
          }]
          "ports" = [{ "port" = 5672, "protocol" = "TCP" }]
        },
        # DNS (kube-dns)
        {
          "to" = [{
            "namespaceSelector" = {
              "matchLabels" = { "kubernetes.io/metadata.name" = "kube-system" }
            }
          }]
          "ports" = [
            { "port" = 53, "protocol" = "UDP" },
            { "port" = 53, "protocol" = "TCP" }
          ]
        },
        # Internet pública — bloqueia IPs privados e o IP de metadados da nuvem (169.254.169.254)
        {
          "to" = [{
            "ipBlock" = {
              "cidr" = "0.0.0.0/0"
              "except" = [
                "10.0.0.0/8",
                "172.16.0.0/12",
                "192.168.0.0/16",
                "169.254.0.0/16"
              ]
            }
          }]
        }
      ]
    }
  }
}

# -------------------------------------------------------------------------
# Governança de Recursos: LimitRange + ResourceQuota (namespace: default)
# -------------------------------------------------------------------------

# Teto por contêiner: impede loop infinito de sugar CPU/RAM dos outros tenants
resource "kubernetes_limit_range" "default_ns" {
  depends_on = [null_resource.k3d_cluster]

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

# Teto do namespace inteiro: impede que um único tenant esgote o nó
resource "kubernetes_resource_quota" "default_ns" {
  depends_on = [null_resource.k3d_cluster]

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

# 3. Instala o KEDA via Helm chart
resource "helm_release" "keda" {
  depends_on = [null_resource.k3d_cluster]

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.19.0"

  wait = true
}

# 4. Subir o RabbitMQ
resource "helm_release" "rabbitmq" {
  depends_on = [null_resource.k3d_cluster]

  name             = "rabbitmq"
  repository       = "https://charts.bitnami.com/bitnami"
  chart            = "rabbitmq"
  namespace        = "brokers"
  create_namespace = true

  set {
    name  = "replicaCount"
    value = "1"
  }
  set {
    name  = "auth.username"
    value = "user"
  }
  set {
    name  = "auth.password"
    value = "password"
  }
}

# 5. Deploy do Worker Consumidor
resource "kubernetes_deployment" "worker_app" {
  depends_on = [
    helm_release.rabbitmq,
    kubernetes_runtime_class_v1.gvisor,
    kubernetes_limit_range.default_ns,
    kubernetes_resource_quota.default_ns,
    kubernetes_manifest.netpol_worker_egress,
  ]

  metadata {
    name      = "worker-consumidor"
    namespace = "default"
  }

  spec {
    replicas = 1 # O KEDA assumirá o controle depois

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
      }
      spec {
        runtime_class_name = "gvisor"

        # Força execução sem privilégios de root no nível do Pod
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

          # Sem root, sem escalonamento de privilégios, filesystem somente leitura
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          # /tmp gravável via emptyDir (filesystem raiz permanece read-only)
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

# 6. O ScaledObject do KEDA
resource "kubernetes_manifest" "keda_rabbitmq_scaler" {
  depends_on = [helm_release.keda, kubernetes_deployment.worker_app]

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
