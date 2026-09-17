locals {
  namespace               = "wl-${var.tenant_id}-${var.app_id}"
  credentials_secret_name = "${var.app_id}-credentials"
  credentials_backend_key = "${var.tenant_id}-${var.app_id}-credentials"
  keda_trigger_auth_name  = "${var.app_id}-keda-auth"
  metrics_enabled         = try(var.metrics.enabled, false)
  metrics_port_name       = try(var.metrics.port_name, "metrics")
  metrics_port            = try(var.metrics.port, 9090)
  metrics_path            = try(var.metrics.path, "/metrics")

  workload_labels = {
    "app.kubernetes.io/name" = var.app_id
    "workerless.io/tenant"   = var.tenant_id
    "workerless.io/app"      = var.app_id
    "workerless.io/plan"     = var.plan_key
  }

  keda_secret_target_refs = flatten([
    for trigger in var.keda_triggers : [
      for ref in trigger.authentication_secret_refs : {
        parameter = ref.parameter
        name      = local.credentials_secret_name
        key       = ref.key
      }
    ]
  ])

  keda_authentication_enabled = length(local.keda_secret_target_refs) > 0

  rendered_keda_triggers = [
    for trigger in var.keda_triggers : merge(
      {
        type     = trigger.type
        metadata = trigger.metadata
      },
      trigger.metric_type == null ? {} : { metricType = trigger.metric_type },
      length(trigger.authentication_secret_refs) == 0 ? {} : {
        authenticationRef = {
          name = local.keda_trigger_auth_name
        }
      },
    )
  ]
}

resource "kubernetes_namespace_v1" "workload" {
  metadata {
    name = local.namespace
    labels = merge(local.workload_labels, {
      "kubernetes.io/metadata.name"                = local.namespace
      "app.kubernetes.io/managed-by"               = "workerless"
      "pod-security.kubernetes.io/enforce"         = "baseline"
      "pod-security.kubernetes.io/enforce-version" = "latest"
    })
  }
}

resource "kubernetes_service_account_v1" "worker_runtime" {
  metadata {
    name      = "workerless-runtime"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  automount_service_account_token = false
}

resource "kubernetes_service_account_v1" "worker_build" {
  metadata {
    name      = "workerless-build"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  automount_service_account_token = false
}

resource "kubernetes_role_binding_v1" "workerless_api_runtime" {
  metadata {
    name      = "workerless-api-runtime"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "workerless-tenant-runtime"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "workerless-api-runtime"
    namespace = "workerless-system"
  }
}

resource "kubernetes_limit_range" "worker_limits" {
  metadata {
    name      = "worker-limits"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  spec {
    limit {
      type = "Container"
      max = {
        cpu    = var.plan.container.max_cpu
        memory = var.plan.container.max_memory
      }
      default = {
        cpu    = var.plan.container.default_cpu
        memory = var.plan.container.default_memory
      }
      default_request = {
        cpu    = var.plan.container.default_request_cpu
        memory = var.plan.container.default_request_memory
      }
    }
  }
}

resource "kubernetes_resource_quota" "worker_quota" {
  metadata {
    name      = "worker-quota"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  spec {
    hard = var.plan.quota
  }
}

# Intencionalmente gavinbunney/kubectl: o CRD ExternalSecret vem do helm_release
# do ESO em modules/core-platform (instalado antes via depends_on no platform/*),
# mas kubernetes_manifest exige o CRD no plan-time, o que quebra `terraform plan`
# em primeiro apply do build.*.sh.
resource "kubectl_manifest" "worker_external_secret" {
  depends_on = [kubernetes_namespace_v1.workload]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.credentials_secret_name
      namespace = kubernetes_namespace_v1.workload.metadata[0].name
      labels    = local.workload_labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = var.external_secret_ref.secret_store_name
        kind = var.external_secret_ref.secret_store_kind
      }
      target = {
        name           = local.credentials_secret_name
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = local.credentials_backend_key
        }
      }]
    }
  })
}

resource "kubernetes_network_policy" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "worker_egress" {
  depends_on = [kubernetes_network_policy.default_deny]

  metadata {
    name      = "worker-egress-allow"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  spec {
    pod_selector {
      match_labels = local.workload_labels
    }
    policy_types = ["Egress"]

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

    egress {
      ports {
        port     = "80"
        protocol = "TCP"
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
      ports {
        port     = "587"
        protocol = "TCP"
      }
      ports {
        port     = "465"
        protocol = "TCP"
      }
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "169.254.0.0/16",
          ]
        }
      }
    }
  }
}

resource "kubernetes_network_policy" "monitoring_scrape" {
  count = local.metrics_enabled ? 1 : 0

  depends_on = [kubernetes_network_policy.default_deny]

  metadata {
    name      = "worker-allow-monitoring-scrape"
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  spec {
    pod_selector {
      match_labels = local.workload_labels
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "worker" {
  depends_on = [
    kubernetes_limit_range.worker_limits,
    kubernetes_resource_quota.worker_quota,
    kubernetes_network_policy.worker_egress,
    kubectl_manifest.worker_external_secret,
    kubernetes_service_account_v1.worker_runtime,
  ]

  metadata {
    name      = var.app_id
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  spec {
    replicas = var.min_replicas

    selector {
      match_labels = local.workload_labels
    }

    template {
      metadata {
        labels = local.workload_labels
      }
      spec {
        service_account_name             = kubernetes_service_account_v1.worker_runtime.metadata[0].name
        automount_service_account_token  = false
        node_selector                    = var.node_selector
        termination_grace_period_seconds = var.termination_grace_period_seconds

        dynamic "image_pull_secrets" {
          for_each = var.image_pull_secret_refs
          content {
            name = image_pull_secrets.value
          }
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          image = var.worker_image
          name  = "worker"

          env_from {
            secret_ref {
              name = local.credentials_secret_name
            }
          }

          dynamic "port" {
            for_each = local.metrics_enabled ? [1] : []
            content {
              name           = local.metrics_port_name
              container_port = local.metrics_port
              protocol       = "TCP"
            }
          }

          resources {
            requests = {
              cpu    = var.plan.container.default_request_cpu
              memory = var.plan.container.default_request_memory
            }
            limits = {
              cpu    = var.plan.container.max_cpu
              memory = var.plan.container.max_memory
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

          dynamic "readiness_probe" {
            for_each = var.probes.readiness == null ? [] : [var.probes.readiness]
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
            for_each = var.probes.liveness == null ? [] : [var.probes.liveness]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].replicas]
  }
}

# Intencionalmente gavinbunney/kubectl: o CRD TriggerAuthentication vem do KEDA
# (instalado em modules/core-platform), mas kubernetes_manifest exige o CRD no
# plan-time. Ver comentário acima em kubectl_manifest.worker_external_secret.
resource "kubectl_manifest" "keda_authentication" {
  count = local.keda_authentication_enabled ? 1 : 0

  depends_on = [kubectl_manifest.worker_external_secret]

  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "TriggerAuthentication"
    metadata = {
      name      = local.keda_trigger_auth_name
      namespace = kubernetes_namespace_v1.workload.metadata[0].name
      labels    = local.workload_labels
    }
    spec = {
      secretTargetRef = local.keda_secret_target_refs
    }
  })
}

# Intencionalmente gavinbunney/kubectl: CRD ScaledObject vem do KEDA. Ver
# comentário acima em kubectl_manifest.worker_external_secret.
resource "kubectl_manifest" "consumer_scaler" {
  depends_on = [
    kubernetes_deployment.worker,
    kubectl_manifest.keda_authentication,
  ]

  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "${var.app_id}-scaledobject"
      namespace = kubernetes_namespace_v1.workload.metadata[0].name
      labels    = local.workload_labels
    }
    spec = {
      scaleTargetRef = {
        name = kubernetes_deployment.worker.metadata[0].name
      }
      pollingInterval = var.keda_polling_interval
      cooldownPeriod  = var.keda_cooldown_period
      minReplicaCount = var.min_replicas
      maxReplicaCount = var.plan.max_replicas
      triggers        = local.rendered_keda_triggers
    }
  })

  lifecycle {
    precondition {
      condition     = var.min_replicas <= var.plan.max_replicas
      error_message = "min_replicas cannot be greater than plan.max_replicas."
    }
  }
}

resource "kubectl_manifest" "worker_pod_monitor" {
  count = local.metrics_enabled ? 1 : 0

  depends_on = [kubernetes_deployment.worker]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "${var.app_id}-metrics"
      namespace = kubernetes_namespace_v1.workload.metadata[0].name
      labels    = local.workload_labels
    }
    spec = {
      selector = {
        matchLabels = local.workload_labels
      }
      podMetricsEndpoints = [{
        port = local.metrics_port_name
        path = local.metrics_path
      }]
    }
  })
}
