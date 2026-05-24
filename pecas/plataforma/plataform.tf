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

# 2.2 Cria a classe de runtime que será usada pelas aplicações (consumidores)
resource "kubernetes_runtime_class_v1" "gvisor" {
  depends_on = [null_resource.gvisor_installer]

  metadata {
    name = "gvisor"
  }

  handler = "runsc"
}

# -------------------------------------------------------------------------
# Plataforma: Instalação do KEDA (Auto-scaling)
# -------------------------------------------------------------------------

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

# NetworkPolicies: namespace keda
resource "kubernetes_manifest" "netpol_keda_deny" {
  depends_on = [helm_release.keda]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = {
      "name"      = "default-deny-all"
      "namespace" = "keda"
    }
    "spec" = {
      "podSelector" = {}
      "policyTypes" = ["Ingress", "Egress"]
    }
  }
}

resource "kubernetes_manifest" "netpol_keda_allow" {
  depends_on = [kubernetes_manifest.netpol_keda_deny]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = {
      "name"      = "keda-allow"
      "namespace" = "keda"
    }
    "spec" = {
      "podSelector" = {}
      "policyTypes" = ["Ingress", "Egress"]
      "ingress" = [
        { "from" = [{ "namespaceSelector" = {} }] }
      ]
      "egress" = [
        {
          "to"    = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "kube-system" } } }]
          "ports" = [{ "port" = 53, "protocol" = "UDP" }, { "port" = 53, "protocol" = "TCP" }]
        },
        {
          "to"    = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "brokers" } } }]
          "ports" = [{ "port" = 5672, "protocol" = "TCP" }]
        },
        {
          "to"    = [{ "ipBlock" = { "cidr" = "10.0.0.0/8" } }]
          "ports" = [{ "port" = 443, "protocol" = "TCP" }, { "port" = 6443, "protocol" = "TCP" }]
        },
        { "to" = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "keda" } } }] }
      ]
    }
  }
}

# -------------------------------------------------------------------------
# Plataforma: Mensageria (RabbitMQ)
# -------------------------------------------------------------------------

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

# NetworkPolicies: namespace brokers
resource "kubernetes_manifest" "netpol_brokers_deny" {
  depends_on = [helm_release.rabbitmq]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = {
      "name"      = "default-deny-all"
      "namespace" = "brokers"
    }
    "spec" = {
      "podSelector" = {}
      "policyTypes" = ["Ingress", "Egress"]
    }
  }
}

resource "kubernetes_manifest" "netpol_brokers_allow" {
  depends_on = [kubernetes_manifest.netpol_brokers_deny]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = {
      "name"      = "brokers-allow"
      "namespace" = "brokers"
    }
    "spec" = {
      "podSelector" = {}
      "policyTypes" = ["Ingress", "Egress"]
      "ingress" = [
        {
          "from" = [
            { "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "default" } } },
            { "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "keda" } } }
          ]
          "ports" = [{ "port" = 5672, "protocol" = "TCP" }]
        }
      ]
      "egress" = [
        {
          "to"    = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "kube-system" } } }]
          "ports" = [{ "port" = 53, "protocol" = "UDP" }, { "port" = 53, "protocol" = "TCP" }]
        },
        { "to" = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "brokers" } } }] }
      ]
    }
  }
}

# -------------------------------------------------------------------------
# DNS Anti-Malware: CoreDNS com Cloudflare 1.1.1.2
# -------------------------------------------------------------------------

resource "null_resource" "coredns_antimalware_patch" {
  depends_on = [null_resource.k3d_cluster]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -e
      PATCH=$(kubectl --context k3d-local-rock get configmap coredns -n kube-system -o json | \
        python3 -c "import sys,json,re; d=json.load(sys.stdin); d['data']['Corefile']=re.sub(r'forward \. \S+.*','forward . 1.1.1.2 1.0.0.2',d['data']['Corefile']); print(json.dumps({'data':d['data']}))")
      kubectl --context k3d-local-rock patch configmap coredns -n kube-system --type merge -p "$PATCH"
      kubectl --context k3d-local-rock rollout restart deployment/coredns -n kube-system
      kubectl --context k3d-local-rock rollout status deployment/coredns -n kube-system --timeout=60s
    BASH
  }
}

# -------------------------------------------------------------------------
# Admission Controller: Kyverno (Governança e Segurança Global)
# -------------------------------------------------------------------------

resource "helm_release" "kyverno" {
  depends_on = [null_resource.k3d_cluster]

  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true

  wait = true
}

resource "kubernetes_manifest" "kyverno_policy_block_privileged" {
  depends_on = [helm_release.kyverno]

  manifest = {
    "apiVersion" = "kyverno.io/v1"
    "kind"       = "ClusterPolicy"
    "metadata" = { "name" = "block-privileged-containers" }
    "spec" = {
      "validationFailureAction" = "Enforce"
      "background"              = true
      "rules" = [{
        "name" = "no-privileged"
        "match" = { "any" = [{ "resources" = { "kinds" = ["Pod"] } }] }
        "validate" = {
          "message" = "Containers privilegiados são bloqueados."
          "pattern" = { "spec" = { "containers" = [{ "=(securityContext)" = { "=(privileged)" = false } }] } }
        }
      }]
    }
  }
}

resource "kubernetes_manifest" "kyverno_policy_block_host_paths" {
  depends_on = [helm_release.kyverno]

  manifest = {
    "apiVersion" = "kyverno.io/v1"
    "kind"       = "ClusterPolicy"
    "metadata" = { "name" = "block-host-paths" }
    "spec" = {
      "validationFailureAction" = "Enforce"
      "background"              = true
      "rules" = [{
        "name" = "no-hostpath"
        "match" = { "any" = [{ "resources" = { "kinds" = ["Pod"] } }] }
        "validate" = {
          "message" = "Volumes hostPath são proibidos."
          "deny" = { "conditions" = { "any" = [{ "key" = "{{ request.object.spec.volumes[] | [?hostPath] | length(@) }}", "operator" = "GreaterThan", "value" = "0" }] } }
        }
      }]
    }
  }
}

resource "kubernetes_manifest" "kyverno_policy_block_host_namespaces" {
  depends_on = [helm_release.kyverno]

  manifest = {
    "apiVersion" = "kyverno.io/v1"
    "kind"       = "ClusterPolicy"
    "metadata" = { "name" = "block-host-namespaces" }
    "spec" = {
      "validationFailureAction" = "Enforce"
      "background"              = true
      "rules" = [{
        "name" = "no-host-namespaces"
        "match" = { "any" = [{ "resources" = { "kinds" = ["Pod"] } }] }
        "validate" = {
          "message" = "hostNetwork, hostPID e hostIPC são proibidos."
          "pattern" = { "spec" = { "=(hostNetwork)" = false, "=(hostPID)" = false, "=(hostIPC)" = false } }
        }
      }]
    }
  }
}

# -------------------------------------------------------------------------
# Observabilidade: kube-prometheus-stack
# -------------------------------------------------------------------------

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [null_resource.k3d_cluster]

  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "61.9.0"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  set { name = "prometheus.prometheusSpec.scrapeInterval", value = "30s" }
  set { name = "prometheus.prometheusSpec.evaluationInterval", value = "30s" }
  set { name = "prometheus.prometheusSpec.kubeletMetrics.enabled", value = "true" }

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        additionalScrapeConfigs = [{
          job_name        = "cadvisor-workers-fast"
          scrape_interval = "5s"
          scrape_timeout  = "4s"
          kubernetes_sd_configs = [{ role = "pod", namespaces = { names = ["default"] } }]
          relabel_configs = [{
            source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
            action        = "keep"
            regex         = "true"
          }]
          metrics_path      = "/metrics/cadvisor"
          scheme            = "https"
          tls_config        = { insecure_skip_verify = true }
          bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        }]
      }
    }
  })]
}

resource "kubernetes_manifest" "netpol_monitoring_deny" {
  depends_on = [helm_release.kube_prometheus_stack]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = { "name" = "default-deny-all", "namespace" = "monitoring" }
    "spec" = { "podSelector" = {}, "policyTypes" = ["Ingress", "Egress"] }
  }
}

resource "kubernetes_manifest" "netpol_monitoring_allow" {
  depends_on = [kubernetes_manifest.netpol_monitoring_deny]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = { "name" = "monitoring-allow", "namespace" = "monitoring" }
    "spec" = {
      "podSelector" = {}
      "policyTypes" = ["Ingress", "Egress"]
      "ingress" = [
        { "from" = [{ "namespaceSelector" = {} }] }
      ]
      "egress" = [
        { "to" = [{ "namespaceSelector" = {} }] },
        {
          "to"    = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "kube-system" } } }]
          "ports" = [{ "port" = 53, "protocol" = "UDP" }, { "port" = 53, "protocol" = "TCP" }]
        },
        {
          "to"    = [{ "ipBlock" = { "cidr" = "0.0.0.0/0" } }]
          "ports" = [{ "port" = 6443, "protocol" = "TCP" }, { "port" = 10250, "protocol" = "TCP" }]
        }
      ]
    }
  }
}

# -------------------------------------------------------------------------
# Banco de Dados de Estado: PostgreSQL local
# -------------------------------------------------------------------------

resource "helm_release" "postgres_state_db" {
  depends_on = [null_resource.k3d_cluster]

  name             = "postgres-state-db"
  repository       = "https://charts.bitnami.com/bitnami"
  chart            = "postgresql"
  version          = "15.5.38"
  namespace        = "state-db"
  create_namespace = true

  set { name = "auth.username", value = "stateuser" }
  set { name = "auth.password", value = "statepass" }
  set { name = "auth.database", value = "k3d_state" }
  set { name = "primary.persistence.enabled", value = "true" }
  set { name = "primary.persistence.size", value = "1Gi" }
}

resource "kubernetes_manifest" "netpol_state_db_deny" {
  depends_on = [helm_release.postgres_state_db]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = { "name" = "default-deny-all", "namespace" = "state-db" }
    "spec" = { "podSelector" = {}, "policyTypes" = ["Ingress", "Egress"] }
  }
}

resource "kubernetes_manifest" "netpol_state_db_allow" {
  depends_on = [kubernetes_manifest.netpol_state_db_deny]

  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "NetworkPolicy"
    "metadata" = { "name" = "state-db-allow", "namespace" = "state-db" }
    "spec" = {
      "podSelector" = {}
      "policyTypes" = ["Ingress", "Egress"]
      "ingress" = [
        {
          "from"  = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "default" } } }]
          "ports" = [{ "port" = 5432, "protocol" = "TCP" }]
        }
      ]
      "egress" = [
        {
          "to"    = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "kube-system" } } }]
          "ports" = [{ "port" = 53, "protocol" = "UDP" }, { "port" = 53, "protocol" = "TCP" }]
        },
        { "to" = [{ "namespaceSelector" = { "matchLabels" = { "kubernetes.io/metadata.name" = "state-db" } } }] }
      ]
    }
  }
}
