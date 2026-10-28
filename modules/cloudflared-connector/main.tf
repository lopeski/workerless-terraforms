resource "kubernetes_deployment_v1" "connector" {
  metadata {
    name      = "workerless-cloudflared"
    namespace = var.namespace
    labels    = { "app.kubernetes.io/name" = "workerless-cloudflared" }
  }

  spec {
    replicas = var.replicas
    selector { match_labels = { "app.kubernetes.io/name" = "workerless-cloudflared" } }
    template {
      metadata { labels = { "app.kubernetes.io/name" = "workerless-cloudflared" } }
      spec {
        automount_service_account_token = false
        security_context { run_as_non_root = true }
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector { match_labels = { "app.kubernetes.io/name" = "workerless-cloudflared" } }
              }
            }
          }
        }
        container {
          name  = "cloudflared"
          image = var.image
          args  = ["tunnel", "--no-autoupdate", "run", "--token", "$(TUNNEL_TOKEN)"]
          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = var.tunnel_token_secret_name
                key  = var.tunnel_token_secret_key
              }
            }
          }
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "256Mi" }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
        }
      }
    }
  }
}
