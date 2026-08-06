locals {
  namespace = "wl-${var.tenant_id}-${var.app_id}"

  workload_labels = {
    "app.kubernetes.io/name" = var.app_id
    "workerless.io/tenant"   = var.tenant_id
    "workerless.io/app"      = var.app_id
    "workerless.io/plan"     = var.plan_key
  }

  namespaced_keda_authentication_manifests = [
    for manifest in var.keda_authentication_manifests : try(manifest.kind, "") == "ClusterTriggerAuthentication" ? manifest : merge(
      manifest,
      {
        metadata = merge(
          try(manifest.metadata, {}),
          { namespace = local.namespace },
        )
      },
    )
  ]
}

resource "kubernetes_namespace_v1" "workload" {
  metadata {
    name = local.namespace
    labels = merge(local.workload_labels, {
      "kubernetes.io/metadata.name"        = local.namespace
      "pod-security.kubernetes.io/enforce" = "baseline"
    })
  }
}

resource "kubernetes_service_account_v1" "worker" {
  metadata {
    name      = var.app_id
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  automount_service_account_token = false
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
      name      = var.external_secret_ref.name
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
        name           = var.external_secret_ref.name
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = var.external_secret_ref.name
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
    kubernetes_service_account_v1.worker,
  ]

  metadata {
    name      = var.app_id
    namespace = kubernetes_namespace_v1.workload.metadata[0].name
    labels    = local.workload_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.workload_labels
    }

    template {
      metadata {
        labels = local.workload_labels
        annotations = {
          "prometheus.io/scrape" = "true"
        }
      }
      spec {
        service_account_name            = kubernetes_service_account_v1.worker.metadata[0].name
        automount_service_account_token = false
        node_selector                   = var.node_selector

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
              name = var.external_secret_ref.name
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
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}

# Intencionalmente gavinbunney/kubectl: o CRD TriggerAuthentication vem do KEDA
# (instalado em modules/core-platform), mas kubernetes_manifest exige o CRD no
# plan-time. Ver comentário acima em kubectl_manifest.worker_external_secret.
resource "kubectl_manifest" "keda_authentication" {
  for_each = { for index, manifest in local.namespaced_keda_authentication_manifests : tostring(index) => manifest }

  depends_on = [kubectl_manifest.worker_external_secret]

  yaml_body = yamlencode(each.value)
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
      minReplicaCount = var.min_replicas
      maxReplicaCount = var.plan.max_replicas
      triggers        = var.keda_triggers
    }
  })
}
