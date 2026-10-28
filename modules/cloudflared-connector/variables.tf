variable "namespace" {
  type    = string
  default = "workerless-system"
}

variable "tunnel_token_secret_name" {
  description = "Name of a pre-existing Secret containing the Cloudflare Tunnel token."
  type        = string
}

variable "tunnel_token_secret_key" {
  type    = string
  default = "token"
}

variable "replicas" {
  type    = number
  default = 2
  validation {
    condition     = var.replicas >= 2
    error_message = "At least two cloudflared replicas are required."
  }
}

variable "image" {
  type    = string
  default = "cloudflare/cloudflared:2026.10.0"
}
