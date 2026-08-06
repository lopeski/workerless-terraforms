# -------------------------------------------------------------------------
# Defaults de resources (CPU/memória) para os componentes da plataforma.
# var.platform_resources permite override seletivo por subcomponente —
# valores não fornecidos caem nos defaults abaixo via try().
# -------------------------------------------------------------------------

locals {
  default_platform_resources = {
    external_secrets = {
      controller      = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
      webhook         = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
      cert_controller = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    }
    keda = {
      operator       = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "1", memory = "1Gi" } }
      metrics_server = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "1", memory = "1Gi" } }
      webhooks       = { requests = { cpu = "50m", memory = "64Mi" }, limits = { cpu = "200m", memory = "256Mi" } }
    }
    kyverno = {
      admission  = { requests = { cpu = "200m", memory = "512Mi" }, limits = { cpu = "2", memory = "2Gi" } }
      background = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "1", memory = "1Gi" } }
      cleanup    = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "1", memory = "1Gi" } }
      reports    = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "1", memory = "1Gi" } }
    }
    kube_prometheus_stack = {
      operator     = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
      prometheus   = { requests = { cpu = "500m", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" } }
      alertmanager = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "200m", memory = "256Mi" } }
      grafana      = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    }
  }

  res = {
    for chart, comps in local.default_platform_resources :
    chart => {
      for comp, default in comps :
      comp => {
        requests = {
          cpu    = try(var.platform_resources[chart][comp].requests.cpu, default.requests.cpu)
          memory = try(var.platform_resources[chart][comp].requests.memory, default.requests.memory)
        }
        limits = {
          cpu    = try(var.platform_resources[chart][comp].limits.cpu, default.limits.cpu)
          memory = try(var.platform_resources[chart][comp].limits.memory, default.limits.memory)
        }
      }
    }
  }
}

# -------------------------------------------------------------------------
# Namespaces explícitos — recurso Terraform em vez de create_namespace=true
# (elimina race com NetworkPolicies e fixa label kubernetes.io/metadata.name
# que selectors abaixo dependem)
# -------------------------------------------------------------------------

locals {
  namespaces = {
    "external-secrets" = { enforce_pss = "baseline" }
    keda               = { enforce_pss = "baseline" }
    monitoring         = { enforce_pss = "privileged" } # node-exporter/grafana initContainers
    kyverno            = { enforce_pss = "privileged" }
  }
}

resource "kubernetes_namespace_v1" "platform" {
  for_each = local.namespaces
  metadata {
    name = each.key
    labels = {
      "kubernetes.io/metadata.name"        = each.key
      "pod-security.kubernetes.io/enforce" = each.value.enforce_pss
    }
  }
}

# -------------------------------------------------------------------------
# External Secrets Operator — materializa Secrets fora do Terraform state
# -------------------------------------------------------------------------

resource "helm_release" "external_secrets" {
  depends_on = [kubernetes_namespace_v1.platform]

  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = kubernetes_namespace_v1.platform["external-secrets"].metadata[0].name
  create_namespace = false
  version          = "2.5.0"

  wait    = true
  timeout = 600
  atomic  = true

  values = [yamlencode({
    installCRDs = true

    replicaCount = 2
    resources    = local.res.external_secrets.controller
    podDisruptionBudget = {
      enabled      = true
      minAvailable = 1
    }
    affinity = {
      podAntiAffinity = {
        preferredDuringSchedulingIgnoredDuringExecution = [{
          weight = 100
          podAffinityTerm = {
            topologyKey = "kubernetes.io/hostname"
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name" = "external-secrets"
              }
            }
          }
        }]
      }
    }
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "external-secrets"
        }
      }
    }]

    webhook = {
      replicaCount = 2
      resources    = local.res.external_secrets.webhook
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
    }

    certController = {
      replicaCount = 2
      resources    = local.res.external_secrets.cert_controller
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
    }
  })]
}

# -------------------------------------------------------------------------
# KEDA — auto-scaling event-driven
# -------------------------------------------------------------------------

resource "helm_release" "keda" {
  depends_on = [kubernetes_namespace_v1.platform]

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = kubernetes_namespace_v1.platform["keda"].metadata[0].name
  create_namespace = false
  version          = "2.19.0"

  wait    = true
  timeout = 600
  atomic  = true

  values = [yamlencode({
    resources = local.res.keda.operator

    operator = {
      replicaCount = 2
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              topologyKey = "kubernetes.io/hostname"
              labelSelector = {
                matchLabels = {
                  "app.kubernetes.io/name" = "keda-operator"
                }
              }
            }
          }]
        }
      }
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = "ScheduleAnyway"
        labelSelector = {
          matchLabels = {
            "app.kubernetes.io/name" = "keda-operator"
          }
        }
      }]
    }

    metricsServer = {
      replicaCount = 2
      resources    = local.res.keda.metrics_server
    }

    webhooks = {
      replicaCount = 2
      resources    = local.res.keda.webhooks
    }

    podDisruptionBudget = {
      operator = {
        enabled      = true
        minAvailable = 1
      }
      metricsServer = {
        enabled      = true
        minAvailable = 1
      }
      webhooks = {
        enabled      = true
        minAvailable = 1
      }
    }
  })]
}

resource "kubernetes_network_policy" "netpol_keda_deny" {
  depends_on = [helm_release.keda]

  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.platform["keda"].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "netpol_keda_allow" {
  depends_on = [kubernetes_network_policy.netpol_keda_deny]

  metadata {
    name      = "keda-allow"
    namespace = kubernetes_namespace_v1.platform["keda"].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["monitoring", "kyverno"]
          }
        }
      }
    }

    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
    }

    dynamic "egress" {
      for_each = var.event_source_egress_rules
      content {
        dynamic "ports" {
          for_each = egress.value.ports
          content {
            port     = tostring(ports.value.port)
            protocol = upper(ports.value.protocol)
          }
        }
        to {
          ip_block { cidr = egress.value.cidr }
        }
      }
    }

    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
      ports {
        port     = "6443"
        protocol = "TCP"
      }
      to {
        ip_block { cidr = var.cluster_service_cidr }
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "keda" }
        }
      }
    }
  }
}

# -------------------------------------------------------------------------
# CoreDNS hardening — força resolver Cloudflare anti-malware (1.1.1.2)
# Substitui null_resource + local-exec + Python por gerenciamento declarativo
# do campo Corefile via kubernetes_config_map_v1_data (não toma posse do
# resto do ConfigMap, preservando NodeHosts gerenciado pelo k3s)
# -------------------------------------------------------------------------

data "kubernetes_config_map_v1" "coredns_current" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }
}

# Patch linha-a-linha do Corefile: encontra a linha "forward ." preservando a
# indentação e substitui pelos resolvers Cloudflare anti-malware. Substitui
# replace(...) com regex frágil, que falhava silenciosamente quando o k3s
# mudava a formatação default do ConfigMap.
locals {
  coredns_lines = split("\n", data.kubernetes_config_map_v1.coredns_current.data["Corefile"])
  coredns_forward_indices = [
    for i, line in local.coredns_lines : i
    if startswith(trimspace(line), "forward .")
  ]
  coredns_patched_lines = [
    for i, line in local.coredns_lines :
    contains(local.coredns_forward_indices, i)
    ? "${regex("^(\\s*)", line)[0]}forward . 1.1.1.2 1.0.0.2"
    : line
  ]
  coredns_patched_corefile = join("\n", local.coredns_patched_lines)
}

resource "kubernetes_config_map_v1_data" "coredns_antimalware" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }
  data = {
    Corefile = local.coredns_patched_corefile
  }
  force = true

  lifecycle {
    precondition {
      condition     = length(local.coredns_forward_indices) > 0
      error_message = "CoreDNS Corefile não contém uma diretiva 'forward .' — o formato pode ter mudado em k3s/k3d, revise o patch antes de prosseguir."
    }
  }
}

resource "kubernetes_annotations" "coredns_restart" {
  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }
  template_annotations = {
    "kubectl.kubernetes.io/restartedAt" = kubernetes_config_map_v1_data.coredns_antimalware.id
  }
  force = true
}

# -------------------------------------------------------------------------
# Kyverno — admission controller com policy PSS baseline
# (substitui 3 policies custom que bloqueavam node-exporter)
# -------------------------------------------------------------------------

resource "helm_release" "kyverno" {
  depends_on = [kubernetes_namespace_v1.platform]

  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = kubernetes_namespace_v1.platform["kyverno"].metadata[0].name
  create_namespace = false

  wait    = true
  timeout = 600
  atomic  = true

  values = [yamlencode({
    admissionController = {
      replicas = 2
      resources = {
        requests = local.res.kyverno.admission.requests
        limits   = local.res.kyverno.admission.limits
      }
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
      antiAffinity = {
        enabled = true
      }
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = "ScheduleAnyway"
      }]
    }

    backgroundController = {
      replicas = 2
      resources = {
        requests = local.res.kyverno.background.requests
        limits   = local.res.kyverno.background.limits
      }
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
      antiAffinity = {
        enabled = true
      }
    }

    cleanupController = {
      replicas = 2
      resources = {
        requests = local.res.kyverno.cleanup.requests
        limits   = local.res.kyverno.cleanup.limits
      }
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
      antiAffinity = {
        enabled = true
      }
    }

    reportsController = {
      replicas = 2
      resources = {
        requests = local.res.kyverno.reports.requests
        limits   = local.res.kyverno.reports.limits
      }
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
      antiAffinity = {
        enabled = true
      }
    }
  })]
}

# Webhook TLS/registration é async — esperar antes de aplicar ClusterPolicy
resource "time_sleep" "kyverno_webhook_ready" {
  depends_on      = [helm_release.kyverno]
  create_duration = "30s"
}

# Intencionalmente gavinbunney/kubectl em vez de hashicorp/kubernetes_manifest:
# o CRD ClusterPolicy é instalado pelo helm_release.kyverno acima no mesmo apply,
# e kubernetes_manifest exigiria o CRD presente já no plan-time. Reavaliar quando
# o provider oficial suportar lazy CRD validation.
resource "kubectl_manifest" "kyverno_pss_baseline" {
  depends_on = [time_sleep.kyverno_webhook_ready]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "pss-baseline"
    }
    spec = {
      background = true
      rules = [{
        name = "baseline"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
              namespaceSelector = {
                matchExpressions = [{
                  key      = "kubernetes.io/metadata.name"
                  operator = "NotIn"
                  values = [
                    "kube-system",
                    "kube-public",
                    "kube-node-lease",
                    "kyverno",
                    "monitoring",
                  ]
                }]
              }
            }
          }]
        }
        validate = {
          failureAction = "Enforce"
          podSecurity = {
            level   = "baseline"
            version = "latest"
          }
        }
      }]
    }
  })
}

# -------------------------------------------------------------------------
# Observabilidade — kube-prometheus-stack
# -------------------------------------------------------------------------

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [kubernetes_namespace_v1.platform]

  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "61.9.0"
  namespace        = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  create_namespace = false

  wait    = true
  timeout = 900
  atomic  = true

  set {
    name  = "prometheus.prometheusSpec.scrapeInterval"
    value = "30s"
  }
  set {
    name  = "prometheus.prometheusSpec.evaluationInterval"
    value = "30s"
  }
  values = [yamlencode({
    kubelet = {
      enabled = true
      serviceMonitor = {
        cAdvisor = true
      }
    }

    prometheusOperator = {
      replicas  = 2
      resources = local.res.kube_prometheus_stack.operator
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              topologyKey = "kubernetes.io/hostname"
              labelSelector = {
                matchLabels = {
                  "app.kubernetes.io/name" = "kube-prometheus-stack-operator"
                }
              }
            }
          }]
        }
      }
    }

    prometheus = merge(
      {
        podDisruptionBudget = {
          enabled      = true
          minAvailable = 1
        }
        prometheusSpec = {
          replicas        = 2
          resources       = local.res.kube_prometheus_stack.prometheus
          retention       = var.monitoring_storage.prometheus_retention
          retentionSize   = var.monitoring_storage.prometheus_retention_size
          podAntiAffinity = "soft"
          topologySpreadConstraints = [{
            maxSkew           = 1
            topologyKey       = "kubernetes.io/hostname"
            whenUnsatisfiable = "ScheduleAnyway"
          }]
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes      = ["ReadWriteOnce"]
                storageClassName = var.monitoring_storage.storage_class_name
                resources = {
                  requests = {
                    storage = var.monitoring_storage.prometheus_size
                  }
                }
              }
            }
          }
        }
      },
      var.prometheus_node_port == null ? {} : {
        service = {
          type     = "NodePort"
          nodePort = var.prometheus_node_port
        }
      }
    )

    alertmanager = {
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }
      alertmanagerSpec = {
        replicas        = 2
        resources       = local.res.kube_prometheus_stack.alertmanager
        podAntiAffinity = "soft"
        topologySpreadConstraints = [{
          maxSkew           = 1
          topologyKey       = "kubernetes.io/hostname"
          whenUnsatisfiable = "ScheduleAnyway"
        }]
        storage = {
          volumeClaimTemplate = {
            spec = {
              accessModes      = ["ReadWriteOnce"]
              storageClassName = var.monitoring_storage.storage_class_name
              resources = {
                requests = {
                  storage = var.monitoring_storage.alertmanager_size
                }
              }
            }
          }
        }
      }
    }

    # Grafana usa replicas=1: PVC ReadWriteOnce (local-path/hcloud-volumes) não
    # suporta múltiplos pods anexados ao mesmo volume. Persistência > HA aqui —
    # dashboards e configs sobrevivem a restart.
    grafana = {
      replicas  = 1
      resources = local.res.kube_prometheus_stack.grafana
      persistence = {
        enabled          = true
        type             = "pvc"
        storageClassName = var.monitoring_storage.storage_class_name
        size             = var.monitoring_storage.grafana_size
        accessModes      = ["ReadWriteOnce"]
      }
    }
  })]
}

resource "kubernetes_network_policy" "netpol_monitoring_deny" {
  depends_on = [helm_release.kube_prometheus_stack]

  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "netpol_monitoring_allow" {
  depends_on = [kubernetes_network_policy.netpol_monitoring_deny]

  metadata {
    name      = "monitoring-allow"
    namespace = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    # Grafana UI / Prometheus UI / Alertmanager — acessível de qualquer namespace interno
    ingress {
      from {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["monitoring", "kyverno"]
          }
        }
      }
    }

    # Prometheus via NodePort para consumidor externo ao cluster (ex.: PaaS
    # control-plane). O tráfego chega ao pod já com SNAT para o IP privado do
    # nó que recebeu a conexão — quem restringe quais IPs externos acessam o
    # NodePort é o firewall da Hetzner (control_plane_cidrs em envs/hetzner),
    # não esta policy.
    dynamic "ingress" {
      for_each = var.node_private_cidr == null ? [] : [1]
      content {
        ports {
          port     = "9090"
          protocol = "TCP"
        }
        from {
          ip_block { cidr = var.node_private_cidr }
        }
      }
    }

    # Scrape metrics em pods de qualquer namespace
    egress {
      to {
        namespace_selector {}
      }
    }

    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
    }

    # API server + kubelet — em k3s/k3d ficam em CIDRs distintos por ambiente.
    # Mantém 0.0.0.0/0 para portas específicas (não é egress geral).
    egress {
      ports {
        port     = "6443"
        protocol = "TCP"
      }
      ports {
        port     = "10250"
        protocol = "TCP"
      }
      to {
        ip_block { cidr = "0.0.0.0/0" }
      }
    }
  }
}

# -------------------------------------------------------------------------
# ServiceAccount para acesso externo/PaaS
# -------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "paas_admin" {
  metadata {
    name      = "paas-admin-sa"
    namespace = "kube-system"
  }
}

resource "kubernetes_secret_v1" "paas_admin_token" {
  metadata {
    name      = "paas-admin-sa-token"
    namespace = kubernetes_service_account_v1.paas_admin.metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.paas_admin.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_cluster_role_binding_v1" "paas_admin_binding" {
  metadata {
    name = "paas-admin-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.paas_admin.metadata[0].name
    namespace = kubernetes_service_account_v1.paas_admin.metadata[0].namespace
  }
}
