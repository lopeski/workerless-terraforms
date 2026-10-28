locals {
  labels = {
    "app.kubernetes.io/name"       = "guard-grpc"
    "app.kubernetes.io/managed-by" = "workerless"
  }

  db_credentials_secret_name = "guard-grpc-db-credentials"

  server_root_issuer_name   = "guard-grpc-server-root-issuer"
  server_root_ca_secret     = "guard-grpc-server-root-ca-tls"
  server_cluster_issuer     = "guard-grpc-server-ca"
  server_tls_secret         = "guard-grpc-server-tls"
  mac_client_root_issuer    = "guard-grpc-mac-client-root-issuer"
  mac_client_root_ca_secret = "guard-grpc-mac-client-root-ca-tls"
  mac_client_cluster_issuer = "guard-grpc-mac-clients"
}

resource "kubernetes_namespace_v1" "guard_grpc" {
  metadata {
    name = var.namespace
    labels = merge(local.labels, {
      "kubernetes.io/metadata.name"        = var.namespace
      "pod-security.kubernetes.io/enforce" = "restricted"
    })
  }
}

# -------------------------------------------------------------------------
# PKI domain 1 — gRPC server certificate.
#
# Root CA: self-signed Issuer + CA Certificate, created in cert-manager's
# namespace so the generated Secret lands in cert-manager's default
# clusterResourceNamespace (required for ClusterIssuer.spec.ca.secretName to
# resolve it). ClusterIssuer then issues the leaf Certificate consumed by the
# Deployment below, in this module's own namespace, with automatic rotation
# via duration/renewBefore.
# -------------------------------------------------------------------------

resource "kubectl_manifest" "server_root_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = local.server_root_issuer_name
      namespace = var.cert_manager_namespace
    }
    spec = {
      selfSigned = {}
    }
  })
}

resource "kubectl_manifest" "server_root_ca" {
  depends_on = [kubectl_manifest.server_root_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "guard-grpc-server-root-ca"
      namespace = var.cert_manager_namespace
    }
    spec = {
      isCA       = true
      commonName = "workerless-guard-grpc-server-ca"
      secretName = local.server_root_ca_secret
      duration   = "87600h" # 10y — root, never auto-rotated in place
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name = local.server_root_issuer_name
        kind = "Issuer"
      }
    }
  })
}

resource "kubectl_manifest" "server_cluster_issuer" {
  depends_on = [kubectl_manifest.server_root_ca]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = local.server_cluster_issuer
    }
    spec = {
      ca = {
        secretName = local.server_root_ca_secret
      }
    }
  })
}

resource "kubectl_manifest" "server_certificate" {
  depends_on = [
    kubectl_manifest.server_cluster_issuer,
    kubernetes_namespace_v1.guard_grpc,
  ]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.server_tls_secret
      namespace = var.namespace
    }
    spec = {
      secretName  = local.server_tls_secret
      dnsNames    = [var.tailnet_hostname]
      duration    = var.server_cert_duration
      renewBefore = var.server_cert_renew_before
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      usages = ["server auth"]
      issuerRef = {
        name = local.server_cluster_issuer
        kind = "ClusterIssuer"
      }
    }
  })
}

# -------------------------------------------------------------------------
# PKI domain 2 — Mac client certificates. Fully independent root from the
# server-cert CA above (spec: "CA de clientes Mac separada de CAs genéricas
# do cluster"). Terraform stops at the ClusterIssuer: per-device leaf
# Certificates are issued by the admin CLI out-of-band (CertificateRequest
# against this ClusterIssuer), so no device private key is ever created by,
# or stored in, Terraform state.
# -------------------------------------------------------------------------

resource "kubectl_manifest" "mac_client_root_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = local.mac_client_root_issuer
      namespace = var.cert_manager_namespace
    }
    spec = {
      selfSigned = {}
    }
  })
}

resource "kubectl_manifest" "mac_client_root_ca" {
  depends_on = [kubectl_manifest.mac_client_root_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "guard-grpc-mac-client-root-ca"
      namespace = var.cert_manager_namespace
    }
    spec = {
      isCA       = true
      commonName = var.mac_client_ca_common_name
      secretName = local.mac_client_root_ca_secret
      duration   = "87600h" # 10y — root, never auto-rotated in place
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name = local.mac_client_root_issuer
        kind = "Issuer"
      }
    }
  })
}

resource "kubectl_manifest" "mac_client_cluster_issuer" {
  depends_on = [kubectl_manifest.mac_client_root_ca]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = local.mac_client_cluster_issuer
    }
    spec = {
      ca = {
        secretName = local.mac_client_root_ca_secret
      }
    }
  })
}

# -------------------------------------------------------------------------
# DB credentials — materialized by ESO, never passed through Terraform.
# -------------------------------------------------------------------------

resource "kubectl_manifest" "db_credentials_external_secret" {
  depends_on = [kubernetes_namespace_v1.guard_grpc]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.db_credentials_secret_name
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = var.db_credentials_secret_ref.secret_store_name
        kind = var.db_credentials_secret_ref.secret_store_kind
      }
      target = {
        name           = local.db_credentials_secret_name
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = var.db_credentials_backend_key
        }
      }]
    }
  })
}

# -------------------------------------------------------------------------
# Identity + workload.
# -------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "guard_grpc_runtime" {
  metadata {
    name      = "guard-grpc-runtime"
    namespace = kubernetes_namespace_v1.guard_grpc.metadata[0].name
    labels    = local.labels
  }

  automount_service_account_token = false
}

resource "kubernetes_deployment_v1" "guard_grpc" {
  depends_on = [
    kubectl_manifest.server_certificate,
    kubectl_manifest.db_credentials_external_secret,
    kubernetes_network_policy.allow,
  ]

  metadata {
    name      = "guard-grpc"
    namespace = kubernetes_namespace_v1.guard_grpc.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = var.guard_grpc_replicas

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.guard_grpc_runtime.metadata[0].name
        automount_service_account_token = false

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        dynamic "topology_spread_constraint" {
          for_each = var.guard_grpc_replicas > 1 ? [1] : []
          content {
            max_skew           = 1
            topology_key       = "kubernetes.io/hostname"
            when_unsatisfiable = "ScheduleAnyway"
            label_selector {
              match_labels = local.labels
            }
          }
        }

        container {
          name  = "guard-grpc"
          image = var.guard_grpc_image

          port {
            name           = "grpc"
            container_port = var.guard_grpc_port
            protocol       = "TCP"
          }

          env_from {
            secret_ref {
              name = local.db_credentials_secret_name
            }
          }

          resources {
            requests = var.container_resources.requests
            limits   = var.container_resources.limits
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "server-tls"
            mount_path = "/etc/guard-grpc/tls"
            read_only  = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          dynamic "startup_probe" {
            for_each = var.probes.startup == null ? [] : [var.probes.startup]
            content {
              grpc {
                port = var.guard_grpc_port
              }
              initial_delay_seconds = startup_probe.value.initial_delay_seconds
              period_seconds        = startup_probe.value.period_seconds
              timeout_seconds       = startup_probe.value.timeout_seconds
              failure_threshold     = startup_probe.value.failure_threshold
            }
          }

          dynamic "readiness_probe" {
            for_each = var.probes.readiness == null ? [] : [var.probes.readiness]
            content {
              grpc {
                port = var.guard_grpc_port
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
              grpc {
                port = var.guard_grpc_port
              }
              initial_delay_seconds = liveness_probe.value.initial_delay_seconds
              period_seconds        = liveness_probe.value.period_seconds
              timeout_seconds       = liveness_probe.value.timeout_seconds
              failure_threshold     = liveness_probe.value.failure_threshold
            }
          }
        }

        volume {
          name = "server-tls"
          secret {
            secret_name  = local.server_tls_secret
            default_mode = "0440"
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

resource "kubernetes_pod_disruption_budget_v1" "guard_grpc" {
  count = var.guard_grpc_replicas > 1 ? 1 : 0

  metadata {
    name      = "guard-grpc"
    namespace = kubernetes_namespace_v1.guard_grpc.metadata[0].name
    labels    = local.labels
  }

  spec {
    min_available = 1
    selector {
      match_labels = local.labels
    }
  }
}

resource "kubernetes_service_v1" "guard_grpc" {
  metadata {
    name      = "guard-grpc"
    namespace = kubernetes_namespace_v1.guard_grpc.metadata[0].name
    labels    = local.labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.labels

    port {
      name        = "grpc"
      port        = var.guard_grpc_port
      target_port = "grpc"
      protocol    = "TCP"
    }
  }
}

# -------------------------------------------------------------------------
# NetworkPolicy — defense in depth only. This shapes L3/L4 reachability; it
# is NOT what protects the server-TLS or DB-credential Secrets (that's RBAC —
# no Role/RoleBinding anywhere grants `get` on these Secret names except the
# kubelet's own Secret-volume mechanism for the owning Pod). See README.
# -------------------------------------------------------------------------

resource "kubernetes_network_policy" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.guard_grpc.metadata[0].name
    labels    = local.labels
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "allow" {
  depends_on = [kubernetes_network_policy.default_deny]

  metadata {
    name      = "guard-grpc-allow"
    namespace = kubernetes_namespace_v1.guard_grpc.metadata[0].name
    labels    = local.labels
  }

  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      ports {
        port     = tostring(var.guard_grpc_port)
        protocol = "TCP"
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.tailscale_namespace }
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
        port     = tostring(var.db_egress_port)
        protocol = "TCP"
      }
      to {
        ip_block { cidr = var.db_egress_cidr }
      }
    }

    dynamic "egress" {
      for_each = var.authorized_egress_rules
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
  }
}
