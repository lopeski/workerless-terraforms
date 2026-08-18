locals {
  external_host = trimsuffix(trimprefix(trimprefix(var.external_url, "https://"), "http://"), "/")
  push_host     = trimsuffix(trimprefix(trimprefix(var.push_url, "https://"), "http://"), "/")
  harbor_values = {
    externalURL = var.external_url
    expose = merge({
      type = var.expose_type
      tls = {
        enabled    = startswith(var.external_url, "https://")
        certSource = "secret"
        secret = {
          secretName = var.tls_secret_name
        }
      }
      nodePort = {
        ports = { http = { nodePort = var.node_port } }
      }
      }, var.expose_type == "ingress" ? {
      ingress = {
        className   = "nginx"
        hosts       = { core = var.ingress_host }
        annotations = var.ingress_annotations
      }
    } : {})
    existingSecretAdminPassword    = var.admin_secret_name
    existingSecretAdminPasswordKey = var.admin_secret_password_key
    persistence = {
      enabled = true
      persistentVolumeClaim = {
        registry = { storageClass = var.storage_class, size = var.pvc_sizes.registry }
        database = { storageClass = var.storage_class, size = var.pvc_sizes.database }
        redis    = { storageClass = var.storage_class, size = var.pvc_sizes.redis }
        jobservice = {
          jobLog = { storageClass = var.storage_class, size = var.pvc_sizes.job_logs }
        }
        trivy = { storageClass = var.storage_class, size = var.pvc_sizes.trivy }
      }
    }
    trivy   = { enabled = var.trivy_enabled }
    notary  = { enabled = false }
    metrics = { enabled = true }
  }
}

resource "kubernetes_namespace_v1" "harbor" {
  count = var.enabled && var.create_namespace ? 1 : 0
  metadata {
    name = var.namespace
    labels = {
      "kubernetes.io/metadata.name" = var.namespace
      "app.kubernetes.io/part-of"   = "workerless-registry"
    }
  }
}

resource "helm_release" "harbor" {
  count = var.enabled ? 1 : 0

  name       = "harbor"
  repository = "https://helm.goharbor.io"
  chart      = "harbor"
  version    = var.chart_version
  namespace  = var.namespace

  values  = [yamlencode(local.harbor_values)]
  wait    = true
  atomic  = true
  timeout = 1200
}

resource "kubernetes_service_account_v1" "bootstrap" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "harbor-bootstrap"
    namespace = var.namespace
  }
}

resource "kubernetes_role_v1" "bootstrap" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "harbor-bootstrap"
    namespace = var.namespace
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "create", "patch", "update"]
  }
}

resource "kubernetes_role_binding_v1" "bootstrap" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "harbor-bootstrap"
    namespace = var.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.bootstrap[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.bootstrap[0].metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_job_v1" "bootstrap" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "harbor-workerless-bootstrap"
    namespace = var.namespace
  }
  spec {
    backoff_limit = 6
    template {
      metadata {}
      spec {
        service_account_name = kubernetes_service_account_v1.bootstrap[0].metadata[0].name
        restart_policy       = "OnFailure"
        container {
          name    = "bootstrap"
          image   = var.bootstrap_image
          command = ["/bin/sh", "-ec"]
          args = [<<-SCRIPT
            harbor_api="http://harbor-core.${var.namespace}.svc/api/v2.0"
            until curl -fsS -u "admin:$HARBOR_ADMIN_PASSWORD" "$harbor_api/health" >/dev/null; do sleep 5; done
            project_id=$(curl -fsS -u "admin:$HARBOR_ADMIN_PASSWORD" "$harbor_api/projects?name=${var.project_name}" | jq -r '.[0].project_id // empty')
            if [ -z "$project_id" ]; then
              curl -fsS -u "admin:$HARBOR_ADMIN_PASSWORD" -H 'Content-Type: application/json' -X POST "$harbor_api/projects" -d '{"project_name":"${var.project_name}","metadata":{"public":"false"}}'
              project_id=$(curl -fsS -u "admin:$HARBOR_ADMIN_PASSWORD" "$harbor_api/projects?name=${var.project_name}" | jq -r '.[0].project_id')
            fi
            if kubectl -n ${var.namespace} get secret ${var.robot_secret_name} >/dev/null 2>&1; then exit 0; fi
            robot_id=$(curl -fsS -u "admin:$HARBOR_ADMIN_PASSWORD" "$harbor_api/robots" | jq -r '.[] | select(.name=="robot$workerless-builder") | .id' | head -1)
            if [ -n "$robot_id" ]; then curl -fsS -u "admin:$HARBOR_ADMIN_PASSWORD" -X DELETE "$harbor_api/robots/$robot_id"; fi
            response=$(curl -fsS -u "admin:$HARBOR_ADMIN_PASSWORD" -H 'Content-Type: application/json' -X POST "$harbor_api/robots" -d '{"name":"workerless-builder","description":"Workerless tenant image push/pull","duration":-1,"disable":false,"level":"project","permissions":[{"kind":"project","namespace":"${var.project_name}","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"}]}]}')
            robot_name=$(printf '%s' "$response" | jq -r .name)
            robot_secret=$(printf '%s' "$response" | jq -r .secret)
            auth=$(printf '%s' "$robot_name:$robot_secret" | base64 | tr -d '\n')
            dockerconfig=$(jq -nc --arg host "${local.external_host}" --arg push "${local.push_host}" --arg auth "$auth" --arg user "$robot_name" --arg pass "$robot_secret" '{auths:{($host):{auth:$auth,username:$user,password:$pass},($push):{auth:$auth,username:$user,password:$pass}}}')
            kubectl -n ${var.namespace} create secret generic ${var.robot_secret_name} --type=kubernetes.io/dockerconfigjson --from-literal=.dockerconfigjson="$dockerconfig" --dry-run=client -o yaml | kubectl apply -f -
          SCRIPT
          ]
          env {
            name = "HARBOR_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.admin_secret_name
                key  = var.admin_secret_password_key
              }
            }
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "20m" }
  depends_on = [
    helm_release.harbor,
    kubernetes_role_binding_v1.bootstrap,
  ]
}

resource "kubernetes_network_policy_v1" "harbor" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "harbor-default"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        namespace_selector {}
      }
    }
    egress {
      to {
        namespace_selector {}
      }
    }
    egress {
      to {
        ip_block { cidr = "0.0.0.0/0" }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}
