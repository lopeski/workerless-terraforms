terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.27" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
  }
}
