locals {
  proxy_group_name = "guard-grpc-proxies"

  # Full-replace tailnet policy. Tailscale ACLs default-deny anything not
  # explicitly granted, so the single grant below is sufficient: every tag
  # and device NOT listed here (including any pre-existing manual grants in
  # the admin console) has no path to tag_proxy. Owning the full ACL means
  # this repo is the single source of truth for the tailnet policy — manual
  # admin-console edits are reverted on the next apply (see README).
  tailnet_acl = {
    tagOwners = {
      (var.tailscale_operator_tag) = ["autogroup:admin"]
      (var.tailscale_proxy_tag)    = [var.tailscale_operator_tag, "autogroup:admin"]
    }

    autoApprovers = {
      services = {
        (var.tailscale_proxy_tag) = [var.tailscale_proxy_tag]
      }
    }

    grants = concat([
      {
        src = var.tailscale_allowed_device_tags
        dst = [var.tailscale_proxy_tag]
        ip  = ["tcp:443"]
      }
      ], var.guard_grpc_proxy_enabled ? [{
        src = var.tailscale_allowed_device_tags
        dst = [var.tailscale_proxy_tag]
        ip  = ["tcp:${var.guard_grpc_port}"]
    }] : [])
  }
}

resource "kubernetes_namespace_v1" "tailscale_operator" {
  metadata {
    name = var.tailscale_operator_namespace
    labels = {
      "kubernetes.io/metadata.name" = var.tailscale_operator_namespace
      # Tailscale proxy pods use /dev/net/tun and privileged containers by
      # default. Keep this exception isolated to the dedicated namespace.
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# Intencionalmente gavinbunney/kubectl: o CRD ExternalSecret vem do helm_release
# do ESO em modules/core-platform (instalado antes via depends_on no platform/*),
# mas kubernetes_manifest exige o CRD no plan-time, o que quebra `terraform plan`
# em primeiro apply do build.*.sh. Mesmo padrão de modules/workload.
#
# O Secret alvo DEVE se chamar literalmente "operator-oauth" com as chaves
# "client_id"/"client_secret" — é a convenção que o chart tailscale-operator
# consome automaticamente quando nenhum oauth.clientId/clientSecret é
# passado via values (ver README).
resource "kubectl_manifest" "tailscale_operator_oauth_external_secret" {
  depends_on = [kubernetes_namespace_v1.tailscale_operator]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "operator-oauth"
      namespace = kubernetes_namespace_v1.tailscale_operator.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = var.tailscale_oauth_secret_ref.secret_store_name
        kind = var.tailscale_oauth_secret_ref.secret_store_kind
      }
      target = {
        name           = "operator-oauth"
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = "tailscale-operator-oauth"
        }
      }]
    }
  })
}

# Chart manages its own CRDs (ProxyGroup, Connector, etc.) and its own
# operator/proxy ServiceAccounts/RBAC — mirrors how modules/core-platform
# installs ESO/KEDA/Kyverno as cluster-singleton Helm releases.
resource "helm_release" "tailscale_operator" {
  depends_on = [
    kubernetes_namespace_v1.tailscale_operator,
    kubectl_manifest.tailscale_operator_oauth_external_secret,
  ]

  name             = "tailscale-operator"
  repository       = "https://pkgs.tailscale.com/helmcharts"
  chart            = "tailscale-operator"
  namespace        = kubernetes_namespace_v1.tailscale_operator.metadata[0].name
  create_namespace = false
  version          = "1.102.4"

  wait    = true
  timeout = 600
  atomic  = true

  # OAuth client credentials are deliberately absent from these values: the
  # chart auto-discovers a pre-existing Secret literally named
  # "operator-oauth" (keys client_id/client_secret) in its own namespace
  # when oauth.clientId/oauth.clientSecret aren't set here — never pass the
  # secret value through a Helm set/set_sensitive.
  values = [yamlencode({
    operatorConfig = {
      defaultTags = [var.tailscale_operator_tag]
    }

    proxyConfig = {
      defaultTags = [var.tailscale_proxy_tag]
    }

    apiServerProxyConfig = {
      allowImpersonation = true
    }
  })]
}

# Production administration endpoint. Auth mode maps a Tailscale user to a
# Kubernetes user and a tagged client to Kubernetes groups matching its tags.
# The ClusterRoleBindings below then apply normal Kubernetes RBAC.
resource "kubectl_manifest" "kube_apiserver_proxy_group" {
  depends_on = [helm_release.tailscale_operator]

  yaml_body = yamlencode({
    apiVersion = "tailscale.com/v1alpha1"
    kind       = "ProxyGroup"
    metadata = {
      name = var.kube_apiserver_proxy_group_name
    }
    spec = {
      type     = "kube-apiserver"
      replicas = var.proxy_group_replicas
      tags     = [var.tailscale_proxy_tag]
      kubeAPIServer = {
        mode = "auth"
      }
    }
  })
}

resource "kubernetes_cluster_role_binding_v1" "tailscale_cluster_admin" {
  for_each = toset(var.tailscale_allowed_device_tags)

  metadata {
    name = "tailscale-${replace(trimprefix(each.value, "tag:"), ":", "-")}-cluster-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = each.value
  }
}

# ProxyGroup fronting the gRPC Service with HA replicas (>= 2 in production,
# enforced by the proxy_group_replicas validation). type=ingress: proxies
# accept tailnet-originated connections and forward them into the cluster —
# the correct mode for exposing a cluster workload, as opposed to type=egress
# (cluster -> tailnet) or type=kube-apiserver.
resource "kubectl_manifest" "proxy_group" {
  count      = var.guard_grpc_proxy_enabled ? 1 : 0
  depends_on = [helm_release.tailscale_operator]

  yaml_body = yamlencode({
    apiVersion = "tailscale.com/v1alpha1"
    kind       = "ProxyGroup"
    metadata = {
      name = local.proxy_group_name
    }
    spec = {
      type     = "ingress"
      replicas = var.proxy_group_replicas
      tags     = [var.tailscale_proxy_tag]
    }
  })
}

# Forwarding Service: a dedicated ExternalName Service in THIS module's
# namespace, pointing at the existing ClusterIP Service owned by
# modules/security-guard-grpc via its cluster-internal DNS name. This keeps
# the gRPC module's own Service a plain ClusterIP (per spec: "Service do gRPC
# deve ser ClusterIP") while this module alone owns the tailnet-facing proxy
# object, satisfying the L3 TCP exposure model documented by Tailscale for
# forwarding to an existing TCP endpoint reachable from inside the cluster
# (the same ExternalName + tailscale.com/expose pattern Tailscale documents
# for reaching an external database is applied here to an in-cluster
# ClusterIP backend instead — this is the officially documented mechanism
# extrapolated to an in-cluster target, not a literally-published example;
# verify end-to-end against a real tailnet before relying on it in
# production). No Ingress, Gateway, NodePort, or public LoadBalancer is ever
# created for this.
resource "kubernetes_service_v1" "guard_grpc_tailnet_proxy" {
  count      = var.guard_grpc_proxy_enabled ? 1 : 0
  depends_on = [kubectl_manifest.proxy_group]

  metadata {
    name      = "guard-grpc-tailnet-proxy"
    namespace = kubernetes_namespace_v1.tailscale_operator.metadata[0].name
    annotations = merge(
      {
        "tailscale.com/expose"      = "true"
        "tailscale.com/proxy-group" = local.proxy_group_name
      },
      var.tailscale_hostname_override == null ? {} : {
        "tailscale.com/hostname" = var.tailscale_hostname_override
      }
    )
  }

  spec {
    type          = "ExternalName"
    external_name = "${var.guard_grpc_service_name}.${var.guard_grpc_namespace}.svc.cluster.local"

    port {
      name     = "grpc"
      port     = var.guard_grpc_port
      protocol = "TCP"
    }
  }
}

resource "tailscale_acl" "guard" {
  acl = jsonencode(local.tailnet_acl)
}

resource "kubernetes_network_policy" "netpol_tailscale_deny" {
  depends_on = [kubernetes_namespace_v1.tailscale_operator]

  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.tailscale_operator.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "netpol_tailscale_allow" {
  depends_on = [kubernetes_network_policy.netpol_tailscale_deny]

  metadata {
    name      = "tailscale-allow"
    namespace = kubernetes_namespace_v1.tailscale_operator.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    # Proxy pods -> gRPC API namespace, only on the gRPC port.
    egress {
      ports {
        port     = tostring(var.guard_grpc_port)
        protocol = "TCP"
      }
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.guard_grpc_namespace }
        }
      }
    }

    # Operator/proxies -> Tailscale's control plane and DERP relays. These
    # do not sit behind a small, stable CIDR block (anycast/CDN-fronted,
    # documented at https://tailscale.com/kb/1103/exit-nodes and the
    # coordination server docs), so this is a deliberately broad 443/tcp
    # egress rule — narrower than a generic internet-egress allowance
    # because it is single-port, and documented here as the one accepted
    # exception to "never a bare 0.0.0.0/0" in this namespace.
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
      to {
        ip_block { cidr = "0.0.0.0/0" }
      }
    }

    # DERP/STUN fallback for NAT traversal.
    egress {
      ports {
        port     = "3478"
        protocol = "UDP"
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

    # kube-apiserver — the Operator watches/reconciles cluster CRDs/Services.
    egress {
      ports {
        port     = "6443"
        protocol = "TCP"
      }
      to {
        ip_block { cidr = "0.0.0.0/0" }
      }
    }
  }
}
