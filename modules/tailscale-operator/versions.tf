terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
    tailscale  = { source = "tailscale/tailscale", version = "~> 0.29" }
  }
}
