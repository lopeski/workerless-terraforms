# -------------------------------------------------------------------------
# Falco -> Vector internal wiring uses fixed, module-internal ports (not
# exposed as variables): callers only need to configure the
# cluster-externally-relevant ports (audit_webhook_port, collector_*_port).
# -------------------------------------------------------------------------

locals {
  namespace_labels = {
    "app.kubernetes.io/part-of" = "workerless-security-guard"
  }

  collector_coordination_namespace = coalesce(var.collector_coordination_namespace, var.namespace)

  kafka_sink_enabled = length(var.kafka_security_bootstrap_servers) > 0

  falco_alert_sink_port = 9000 # Vector aggregator source fed by Falco's http_output
}

resource "kubernetes_namespace_v1" "security_monitoring" {
  metadata {
    name = var.namespace
    labels = merge(local.namespace_labels, {
      "kubernetes.io/metadata.name"        = var.namespace
      "pod-security.kubernetes.io/enforce" = "privileged"
      "app.kubernetes.io/managed-by"       = "terraform"
    })
  }
}

# -------------------------------------------------------------------------
# NOTA CROSS-MODULE OBRIGATORIA: mesmo com o label PSS "privileged" acima, a
# ClusterPolicy "pss-baseline" do Kyverno (modules/core-platform/main.tf)
# valida TODOS os namespaces exceto a lista explicita em
# namespaceSelector.matchExpressions (hoje: kube-system, kube-public,
# kube-node-lease, kyverno, monitoring). O Falco DaemonSet abaixo roda com
# hostPID/capabilities elevadas (ver helm_release.falco) e sera bloqueado no
# admission do Kyverno a menos que var.namespace seja adicionado aquela
# lista de exclusao em modules/core-platform/main.tf. Este modulo NAO pode
# editar aquele ClusterPolicy (vive em outro modulo) — tratar como
# pre-requisito de integracao, nao coberto por este commit.
# -------------------------------------------------------------------------

# -------------------------------------------------------------------------
# PKI interna Falco -> Vector -> collector. CA própria, independente de
# qualquer outra (security-guard-grpc tem a sua). Usamos Issuer namespaced
# (não ClusterIssuer): todo consumidor desta CA vive neste mesmo namespace,
# e ClusterIssuer do tipo `ca` resolve seu secretName contra o
# "cluster resource namespace" global do controller (kube-system por
# default) — acoplamento cross-namespace evitável e desnecessário aqui.
# -------------------------------------------------------------------------

resource "kubectl_manifest" "internal_ca_root_issuer" {
  depends_on = [kubernetes_namespace_v1.security_monitoring]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "security-monitoring-internal-root-issuer"
      namespace = var.namespace
    }
    spec = {
      selfSigned = {}
    }
  })
}

resource "kubectl_manifest" "internal_ca_root_certificate" {
  depends_on = [kubectl_manifest.internal_ca_root_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "security-monitoring-internal-root-ca"
      namespace = var.namespace
    }
    spec = {
      isCA       = true
      commonName = "security-monitoring-internal-ca"
      secretName = "security-monitoring-internal-ca-tls"
      duration   = "43800h" # 5y
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "security-monitoring-internal-root-issuer"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })
}

resource "kubectl_manifest" "internal_ca_issuer" {
  depends_on = [kubectl_manifest.internal_ca_root_certificate]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "security-monitoring-internal-ca-issuer"
      namespace = var.namespace
    }
    spec = {
      ca = {
        secretName = "security-monitoring-internal-ca-tls"
      }
    }
  })
}

resource "kubectl_manifest" "vector_aggregator_server_certificate" {
  depends_on = [kubectl_manifest.internal_ca_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "vector-aggregator-server-tls"
      namespace = var.namespace
    }
    spec = {
      secretName  = "vector-aggregator-server-tls"
      duration    = "2160h" # 90d
      renewBefore = "360h"  # 15d
      dnsNames = [
        "vector-aggregator.${var.namespace}.svc",
        "vector-aggregator.${var.namespace}.svc.cluster.local",
      ]
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "security-monitoring-internal-ca-issuer"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })
}

resource "kubectl_manifest" "falco_client_certificate" {
  depends_on = [kubectl_manifest.internal_ca_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "falco-vector-client-tls"
      namespace = var.namespace
    }
    spec = {
      secretName  = "falco-vector-client-tls"
      duration    = "2160h"
      renewBefore = "360h"
      commonName  = "falco-client"
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "security-monitoring-internal-ca-issuer"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })
}

resource "kubectl_manifest" "collector_server_certificate" {
  depends_on = [kubectl_manifest.internal_ca_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "security-collector-server-tls"
      namespace = var.namespace
    }
    spec = {
      secretName  = "security-collector-server-tls"
      duration    = "2160h"
      renewBefore = "360h"
      dnsNames = [
        "security-collector.${var.namespace}.svc",
        "security-collector.${var.namespace}.svc.cluster.local",
      ]
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "security-monitoring-internal-ca-issuer"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })
}

resource "kubectl_manifest" "vector_collector_client_certificate" {
  depends_on = [kubectl_manifest.internal_ca_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "vector-collector-client-tls"
      namespace = var.namespace
    }
    spec = {
      secretName  = "vector-collector-client-tls"
      duration    = "2160h"
      renewBefore = "360h"
      commonName  = "vector-aggregator-client"
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "security-monitoring-internal-ca-issuer"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })
}

# -------------------------------------------------------------------------
# Vector Kafka credentials (only materialized when a Kafka sink is used)
# -------------------------------------------------------------------------

resource "kubectl_manifest" "vector_kafka_external_secret" {
  count      = local.kafka_sink_enabled ? 1 : 0
  depends_on = [kubernetes_namespace_v1.security_monitoring]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "vector-kafka-credentials"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = var.vector_kafka_credentials_secret_ref.secret_store_name
        kind = var.vector_kafka_credentials_secret_ref.secret_store_kind
      }
      target = {
        name           = "vector-kafka-credentials"
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = "security-monitoring-vector-kafka-credentials"
        }
      }]
    }
  })
}

# -------------------------------------------------------------------------
# Falco — DaemonSet com drivers do kernel. Desvio de pod-security
# documentado: hostPID e privileged/capabilities elevadas sao exigidos pelo
# chart para os drivers kmod/modern_ebpf lerem eventos de syscall do host;
# nao ha forma de rodar Falco sob um perfil restricted/baseline genuino. O
# escopo fica estritamente neste Deployment (nao se propaga a outros
# workloads do namespace) e depende da exclusao Kyverno citada acima.
# -------------------------------------------------------------------------

resource "helm_release" "falco" {
  depends_on = [
    kubernetes_namespace_v1.security_monitoring,
    kubectl_manifest.falco_client_certificate,
  ]

  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  namespace        = kubernetes_namespace_v1.security_monitoring.metadata[0].name
  create_namespace = false
  version          = var.falco_chart_version

  wait    = true
  timeout = 600
  atomic  = true

  values = [yamlencode({
    image = {
      registry   = "docker.io"
      repository = "falcosecurity/falco@sha256"
      tag        = var.falco_image_digest
    }

    podPriorityClassName = "system-node-critical"

    driver = {
      kind = var.falco_driver
    }

    resources = {
      requests = var.falco_resources.requests
      limits   = var.falco_resources.limits
    }

    certs = {
      existingClientSecret = "falco-vector-client-tls"
    }

    customRules = var.falco_custom_rules

    serviceMonitor = {
      create = true
    }

    falco = {
      json_output = true

      http_output = {
        enabled     = true
        url         = "https://vector-aggregator.${var.namespace}.svc:${local.falco_alert_sink_port}/falco"
        mtls        = true
        ca_cert     = "/etc/falco/certs/client/ca.crt"
        client_cert = "/etc/falco/certs/client/tls.crt"
        client_key  = "/etc/falco/certs/client/tls.key"
        keep_alive  = true
      }

      grpc = {
        enabled = false
      }
      grpc_output = {
        enabled = false
      }
    }
  })]
}

# -------------------------------------------------------------------------
# Vector agent (DaemonSet) — coleta node-local (hostPath logs). Sem papel
# na ingestão de Falco/Audit (feita diretamente pelo aggregator via
# http_output/webhook); hoje apenas encaminha logs de nó para o aggregator,
# mantido para paridade com o padrão agent+aggregator do chart e expansão
# futura (ex.: coleta de logs de container runtime).
# -------------------------------------------------------------------------

resource "helm_release" "vector_agent" {
  depends_on = [kubernetes_namespace_v1.security_monitoring]

  name             = "vector-agent"
  repository       = "https://helm.vector.dev"
  chart            = "vector"
  namespace        = kubernetes_namespace_v1.security_monitoring.metadata[0].name
  create_namespace = false
  version          = var.vector_chart_version

  wait    = true
  timeout = 600
  atomic  = true

  values = [yamlencode({
    role = "Agent"

    resources = {
      requests = var.vector_agent_resources.requests
      limits   = var.vector_agent_resources.limits
    }

    podMonitor = {
      enabled = true
    }

    customConfig = {
      data_dir = "/vector-data-dir"
      api      = { enabled = true, address = "127.0.0.1:8686" }
      sources = {
        host_logs = {
          type    = "file"
          include = ["/var/log/**/*.log"]
        }
        internal_metrics = { type = "internal_metrics" }
      }
      sinks = {
        aggregator = {
          type    = "vector"
          inputs  = ["host_logs"]
          address = "vector-aggregator.${var.namespace}.svc:6000"
        }
        prometheus_metrics = {
          type    = "prometheus_exporter"
          inputs  = ["internal_metrics"]
          address = "0.0.0.0:9598"
        }
      }
    }
  })]
}

# -------------------------------------------------------------------------
# Vector aggregator (Stateless-Aggregator => Deployment; "Aggregator" role
# in this chart maps to a StatefulSet, which we deliberately avoid since
# nothing here needs stable network identity/PVC-per-replica).
# -------------------------------------------------------------------------

resource "helm_release" "vector_aggregator" {
  depends_on = [
    kubernetes_namespace_v1.security_monitoring,
    kubectl_manifest.vector_aggregator_server_certificate,
    kubectl_manifest.vector_collector_client_certificate,
  ]

  name             = "vector-aggregator"
  repository       = "https://helm.vector.dev"
  chart            = "vector"
  namespace        = kubernetes_namespace_v1.security_monitoring.metadata[0].name
  create_namespace = false
  version          = var.vector_chart_version

  wait    = true
  timeout = 600
  atomic  = true

  values = [yamlencode(merge(
    {
      role     = "Stateless-Aggregator"
      replicas = var.vector_aggregator_replicas

      resources = {
        requests = var.vector_aggregator_resources.requests
        limits   = var.vector_aggregator_resources.limits
      }

      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }

      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = "ScheduleAnyway"
      }]

      podMonitor = {
        enabled = true
      }

      containerPorts = concat(
        [
          { name = "falco-alerts", containerPort = local.falco_alert_sink_port, protocol = "TCP" },
          { name = "audit-webhook", containerPort = var.audit_webhook_port, protocol = "TCP" },
          { name = "vector-sink", containerPort = 6000, protocol = "TCP" },
        ]
      )

      service = {
        enabled = true
        ports = [
          { name = "falco-alerts", port = local.falco_alert_sink_port, targetPort = "falco-alerts", protocol = "TCP" },
          { name = "audit-webhook", port = var.audit_webhook_port, targetPort = "audit-webhook", protocol = "TCP" },
          { name = "vector-sink", port = 6000, targetPort = "vector-sink", protocol = "TCP" },
        ]
      }

      extraVolumes = [
        {
          name   = "aggregator-server-tls"
          secret = { secretName = "vector-aggregator-server-tls" }
        },
        {
          name   = "collector-client-tls"
          secret = { secretName = "vector-collector-client-tls" }
        },
      ]
      extraVolumeMounts = [
        { name = "aggregator-server-tls", mountPath = "/etc/vector/tls/server", readOnly = true },
        { name = "collector-client-tls", mountPath = "/etc/vector/tls/collector-client", readOnly = true },
      ]

      envFrom = local.kafka_sink_enabled ? [
        { secretRef = { name = "vector-kafka-credentials" } }
      ] : []

      customConfig = {
        data_dir = "/vector-data-dir"
        api      = { enabled = true, address = "127.0.0.1:8686" }

        sources = merge(
          {
            falco_alerts = {
              type     = "http_server"
              address  = "0.0.0.0:${local.falco_alert_sink_port}"
              encoding = "json"
              tls = {
                enabled            = true
                crt_file           = "/etc/vector/tls/server/tls.crt"
                key_file           = "/etc/vector/tls/server/tls.key"
                ca_file            = "/etc/vector/tls/server/ca.crt"
                verify_certificate = true
              }
            }
            audit_events = {
              type     = "http_server"
              address  = "0.0.0.0:${var.audit_webhook_port}"
              encoding = "json"
              tls = {
                enabled  = true
                crt_file = "/etc/vector/tls/server/tls.crt"
                key_file = "/etc/vector/tls/server/tls.key"
              }
            }
            from_agent = {
              type    = "vector"
              address = "0.0.0.0:6000"
            }
            internal_metrics = { type = "internal_metrics" }
            internal_logs    = { type = "internal_logs" }
          }
        )

        transforms = {
          redact = {
            type   = "remap"
            inputs = ["falco_alerts", "audit_events", "from_agent"]
            source = <<-VRL
              # Defensive redaction: strip common secret-bearing fields before
              # anything leaves this transform. Field names are best-effort —
              # this is a floor, not a substitute for upstream data minimization.
              del(.requestObject.data)
              del(.responseObject.data)
              del(.annotations."kubectl.kubernetes.io/last-applied-configuration")
              for_each(["authorization", "cookie", "set-cookie", "x-api-key"]) -> |_i, k| {
                if exists(.requestHeaders) { del(.requestHeaders[k]) }
                if exists(.responseHeaders) { del(.responseHeaders[k]) }
              }
            VRL
          }

          route_quarantine = {
            type   = "route"
            inputs = ["redact"]
            route = {
              ok = ".source_type != null"
            }
          }
        }

        sinks = merge(
          {
            collector = {
              type     = "http"
              inputs   = ["route_quarantine.ok"]
              uri      = "https://security-collector.${var.namespace}.svc:${var.collector_ingest_port}/ingest"
              encoding = { codec = "json" }
              tls = {
                ca_file  = "/etc/vector/tls/collector-client/ca.crt"
                crt_file = "/etc/vector/tls/collector-client/tls.crt"
                key_file = "/etc/vector/tls/collector-client/tls.key"
              }
              buffer = {
                type      = "disk"
                max_size  = var.vector_disk_buffer_max_size_bytes
                when_full = "drop_newest"
              }
            }
            quarantine_dlq = {
              type     = "file"
              inputs   = ["route_quarantine._unmatched"]
              path     = "/vector-data-dir/dlq/quarantine-%Y-%m-%d.log"
              encoding = { codec = "json" }
            }
            prometheus_metrics = {
              type    = "prometheus_exporter"
              inputs  = ["internal_metrics"]
              address = "0.0.0.0:9598"
            }
          },
          local.kafka_sink_enabled ? {
            kafka = {
              type              = "kafka"
              inputs            = ["route_quarantine.ok"]
              bootstrap_servers = join(",", var.kafka_security_bootstrap_servers)
              topic             = "security-guard-events"
              encoding          = { codec = "json" }
              sasl = {
                enabled   = true
                mechanism = "SCRAM-SHA-512"
                username  = "$${VECTOR_KAFKA_USERNAME}"
                password  = "$${VECTOR_KAFKA_PASSWORD}"
              }
              tls = { enabled = true }
              buffer = {
                type      = "disk"
                max_size  = var.vector_disk_buffer_max_size_bytes
                when_full = "drop_newest"
              }
            }
          } : {}
        )
      }
    }
  ))]
}

# -------------------------------------------------------------------------
# Collector
# -------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "security_collector" {
  metadata {
    name      = "security-collector"
    namespace = kubernetes_namespace_v1.security_monitoring.metadata[0].name
  }

  automount_service_account_token = false
}

resource "kubernetes_cluster_role_v1" "security_collector" {
  metadata {
    name = "security-collector"
  }

  dynamic "rule" {
    for_each = var.collector_watched_resources
    content {
      api_groups = rule.value.api_groups
      resources  = rule.value.resources
      verbs      = rule.value.verbs
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "security_collector" {
  metadata {
    name = "security-collector"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.security_collector.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.security_collector.metadata[0].name
    namespace = kubernetes_service_account_v1.security_collector.metadata[0].namespace
  }
}

# Lease é namespaced (não cluster-scoped): o collector só coordena réplicas
# entre si, não precisa — e não deve ter — alcance cluster-wide para isso.
resource "kubernetes_role_v1" "security_collector_lease" {
  metadata {
    name      = "security-collector-lease"
    namespace = local.collector_coordination_namespace
  }

  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "update"]
  }
}

resource "kubernetes_role_binding_v1" "security_collector_lease" {
  metadata {
    name      = "security-collector-lease"
    namespace = local.collector_coordination_namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.security_collector_lease.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.security_collector.metadata[0].name
    namespace = kubernetes_service_account_v1.security_collector.metadata[0].namespace
  }
}

resource "kubernetes_deployment_v1" "security_collector" {
  depends_on = [
    kubectl_manifest.collector_server_certificate,
    kubernetes_role_binding_v1.security_collector_lease,
    kubernetes_cluster_role_binding_v1.security_collector,
  ]

  metadata {
    name      = "security-collector"
    namespace = kubernetes_namespace_v1.security_monitoring.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "security-collector"
    }
  }

  spec {
    replicas = var.collector_replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "security-collector"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "security-collector"
        }
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.security_collector.metadata[0].name
        automount_service_account_token = false

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "collector"
          image = var.collector_image

          port {
            name           = "ingest"
            container_port = var.collector_ingest_port
            protocol       = "TCP"
          }
          port {
            name           = "metrics"
            container_port = var.collector_metrics_port
            protocol       = "TCP"
          }

          resources {
            requests = var.collector_resources.requests
            limits   = var.collector_resources.limits
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

          volume_mount {
            name       = "server-tls"
            mount_path = "/etc/collector/tls"
            read_only  = true
          }

          dynamic "startup_probe" {
            for_each = var.collector_probes.startup == null ? [] : [var.collector_probes.startup]
            content {
              http_get {
                path   = startup_probe.value.http_get.path
                port   = startup_probe.value.http_get.port
                scheme = startup_probe.value.http_get.scheme
              }
              initial_delay_seconds = startup_probe.value.initial_delay_seconds
              period_seconds        = startup_probe.value.period_seconds
              timeout_seconds       = startup_probe.value.timeout_seconds
              failure_threshold     = startup_probe.value.failure_threshold
            }
          }

          dynamic "readiness_probe" {
            for_each = var.collector_probes.readiness == null ? [] : [var.collector_probes.readiness]
            content {
              http_get {
                path   = readiness_probe.value.http_get.path
                port   = readiness_probe.value.http_get.port
                scheme = readiness_probe.value.http_get.scheme
              }
              initial_delay_seconds = readiness_probe.value.initial_delay_seconds
              period_seconds        = readiness_probe.value.period_seconds
              timeout_seconds       = readiness_probe.value.timeout_seconds
              failure_threshold     = readiness_probe.value.failure_threshold
            }
          }

          dynamic "liveness_probe" {
            for_each = var.collector_probes.liveness == null ? [] : [var.collector_probes.liveness]
            content {
              http_get {
                path   = liveness_probe.value.http_get.path
                port   = liveness_probe.value.http_get.port
                scheme = liveness_probe.value.http_get.scheme
              }
              initial_delay_seconds = liveness_probe.value.initial_delay_seconds
              period_seconds        = liveness_probe.value.period_seconds
              timeout_seconds       = liveness_probe.value.timeout_seconds
              failure_threshold     = liveness_probe.value.failure_threshold
            }
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }

        volume {
          name = "server-tls"
          secret {
            secret_name = "security-collector-server-tls"
          }
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "security_collector" {
  count = var.collector_replicas > 1 ? 1 : 0

  metadata {
    name      = "security-collector"
    namespace = kubernetes_namespace_v1.security_monitoring.metadata[0].name
  }

  spec {
    min_available = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "security-collector"
      }
    }
  }
}

resource "kubernetes_service_v1" "security_collector" {
  metadata {
    name      = "security-collector"
    namespace = kubernetes_namespace_v1.security_monitoring.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "security-collector"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "security-collector"
    }

    port {
      name        = "ingest"
      port        = var.collector_ingest_port
      target_port = "ingest"
      protocol    = "TCP"
    }
    port {
      name        = "metrics"
      port        = var.collector_metrics_port
      target_port = "metrics"
      protocol    = "TCP"
    }
  }
}

resource "kubectl_manifest" "security_collector_pod_monitor" {
  depends_on = [kubernetes_deployment_v1.security_collector]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "security-collector"
      namespace = var.namespace
    }
    spec = {
      selector = {
        matchLabels = { "app.kubernetes.io/name" = "security-collector" }
      }
      podMetricsEndpoints = [{
        port = "metrics"
        path = "/metrics"
      }]
    }
  })
}

# -------------------------------------------------------------------------
# NetworkPolicies — default-deny por namespace + allow por componente
# (pod_selector escopado por app.kubernetes.io/name ou .../instance, nunca
# o namespace inteiro, já que o namespace hospeda 3 workloads com
# necessidades de rede distintas)
# -------------------------------------------------------------------------

resource "kubernetes_network_policy" "default_deny" {
  depends_on = [kubernetes_namespace_v1.security_monitoring]

  metadata {
    name      = "default-deny-all"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "falco_egress" {
  depends_on = [kubernetes_network_policy.default_deny]

  metadata {
    name      = "falco-egress-allow"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "falco" }
    }
    policy_types = ["Egress"]

    egress {
      ports {
        port     = tostring(local.falco_alert_sink_port)
        protocol = "TCP"
      }
      to {
        pod_selector {
          match_labels = { "app.kubernetes.io/instance" = "vector-aggregator" }
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
  }
}

resource "kubernetes_network_policy" "vector_agent_egress" {
  depends_on = [kubernetes_network_policy.default_deny]

  metadata {
    name      = "vector-agent-egress-allow"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/instance" = "vector-agent" }
    }
    policy_types = ["Egress"]

    egress {
      ports {
        port     = "6000"
        protocol = "TCP"
      }
      to {
        pod_selector {
          match_labels = { "app.kubernetes.io/instance" = "vector-aggregator" }
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
  }
}

resource "kubernetes_network_policy" "vector_aggregator_policy" {
  depends_on = [kubernetes_network_policy.default_deny]

  metadata {
    name      = "vector-aggregator-allow"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/instance" = "vector-aggregator" }
    }
    policy_types = ["Ingress", "Egress"]

    # Falco (http_output) e o próprio vector-agent
    ingress {
      ports {
        port     = tostring(local.falco_alert_sink_port)
        protocol = "TCP"
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "falco" }
        }
      }
    }
    ingress {
      ports {
        port     = "6000"
        protocol = "TCP"
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/instance" = "vector-agent" }
        }
      }
    }

    # Webhook de audit — somente dos nós de control-plane
    ingress {
      ports {
        port     = tostring(var.audit_webhook_port)
        protocol = "TCP"
      }
      from {
        ip_block { cidr = var.audit_ingestion_allowed_cidr }
      }
    }

    # Scrape de métricas
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
      }
    }

    egress {
      ports {
        port     = tostring(var.collector_ingest_port)
        protocol = "TCP"
      }
      to {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "security-collector" }
        }
      }
    }

    dynamic "egress" {
      for_each = local.kafka_sink_enabled ? [1] : []
      content {
        to {
          ip_block { cidr = "0.0.0.0/0" }
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
  }
}

resource "kubernetes_network_policy" "collector_policy" {
  depends_on = [kubernetes_network_policy.default_deny]

  metadata {
    name      = "security-collector-allow"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "security-collector" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      ports {
        port     = tostring(var.collector_ingest_port)
        protocol = "TCP"
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/instance" = "vector-aggregator" }
        }
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
      }
    }

    egress {
      ports {
        port     = "6443"
        protocol = "TCP"
      }
      to {
        ip_block { cidr = "0.0.0.0/0" }
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
  }
}
