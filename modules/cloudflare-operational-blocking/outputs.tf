output "cloudflare_guard_list_id" {
  description = "ID of the dedicated IP list used for Security Guard operational blocking. Not sensitive."
  value       = cloudflare_list.guard.id
}

output "cloudflare_guard_ruleset_ids" {
  description = "Ruleset IDs keyed by zone ID. Not sensitive."
  value       = { for zone_id, rs in cloudflare_ruleset.guard : zone_id => rs.id }
}
