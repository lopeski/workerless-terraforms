output "r2_evidence_bucket_name" {
  description = "Name of the evidence R2 bucket. Non-sensitive — needed by other repos/tools to construct the S3-compatible endpoint."
  value       = cloudflare_r2_bucket.evidence.name
}

output "r2_evidence_bucket_id" {
  description = "Cloudflare resource ID of the evidence R2 bucket (same as name for this resource type). Non-sensitive."
  value       = cloudflare_r2_bucket.evidence.id
}
