terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
  }
}
