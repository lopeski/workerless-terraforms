variable "enabled" {
  description = "Install Harbor and bootstrap the private Workerless project."
  type        = bool
  default     = true
}

variable "namespace" {
  type    = string
  default = "harbor"
}

variable "create_namespace" {
  type    = bool
  default = true
}

variable "chart_version" {
  description = "Pinned Harbor Helm chart version."
  type        = string
  default     = "1.16.2"
}

variable "external_url" {
  description = "Canonical URL used by Kubernetes when pulling images."
  type        = string
}

variable "push_url" {
  description = "Registry host reachable from in-cluster builders."
  type        = string
}

variable "expose_type" {
  type    = string
  default = "clusterIP"

  validation {
    condition     = contains(["clusterIP", "ingress", "nodePort"], var.expose_type)
    error_message = "expose_type must be clusterIP, ingress, or nodePort."
  }
}

variable "ingress_host" {
  type    = string
  default = null
}

variable "ingress_annotations" {
  type    = map(string)
  default = {}
}

variable "tls_secret_name" {
  type    = string
  default = null
}

variable "node_port" {
  type    = number
  default = 30001
}

variable "storage_class" {
  type = string
}

variable "pvc_sizes" {
  type = object({
    registry = string
    database = string
    redis    = string
    job_logs = string
    trivy    = string
  })
  default = {
    registry = "20Gi"
    database = "5Gi"
    redis    = "1Gi"
    job_logs = "1Gi"
    trivy    = "5Gi"
  }
}

variable "trivy_enabled" {
  type    = bool
  default = false
}

variable "admin_secret_name" {
  description = "Pre-existing Secret containing Harbor's admin password."
  type        = string
  default     = "harbor-admin"
}

variable "admin_secret_password_key" {
  type    = string
  default = "HARBOR_ADMIN_PASSWORD"
}

variable "robot_secret_name" {
  type    = string
  default = "registry-credentials-source"
}

variable "project_name" {
  type    = string
  default = "workerless"
}

variable "bootstrap_image" {
  type    = string
  default = "alpine/k8s:1.30.3"
}
