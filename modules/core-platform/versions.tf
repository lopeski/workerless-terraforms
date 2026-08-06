terraform {
  required_providers {
    null       = { source = "hashicorp/null", version = "~> 3.2" }
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
    time       = { source = "hashicorp/time", version = "~> 0.11" }
  }
}
