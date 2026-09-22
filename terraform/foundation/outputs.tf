# ==============================================================================
# MODULE INTERFACE OUTPUTS
# When this repo is used as a Terraform module by another project, these outputs
# provide everything needed to bind agents to the shared security platform.
#
# Usage in consuming project:
#   module.agw_foundation.ingress_gateway_name  → agentGatewayConfig.clientToAgentConfig
#   module.agw_foundation.egress_gateway_name   → agentGatewayConfig.agentToAnywhereConfig
#   module.agw_foundation.model_armor_template_high_id → custom MA template references
# ==============================================================================

# --- Network ---
output "network_id" {
  value       = google_compute_network.vpc.id
  description = "The ID of the VPC network."
}

output "intf_subnet_id" {
  value       = google_compute_subnetwork.intf_subnet.id
  description = "The ID of the interface subnet."
}

output "psc_network_attachment" {
  value       = google_compute_network_attachment.psc_network_attachment.id
  description = "The ID of the PSC network attachment for egress."
}

# --- Gateways (IDs for Terraform references) ---
output "ingress_gateway_id" {
  value       = google_network_services_agent_gateway.ingress_gateway.id
  description = "The Terraform resource ID of the ingress Agent Gateway."
}

output "egress_gateway_id" {
  value       = google_network_services_agent_gateway.egress_gateway.id
  description = "The Terraform resource ID of the egress Agent Gateway."
}

# --- Gateway Names (resource paths for agentGatewayConfig — use these in RE deployments) ---
output "ingress_gateway_name" {
  value       = "projects/${var.project_id}/locations/${var.region}/agentGateways/${var.prefix}-ingress-gateway"
  description = "Full resource path for agentGatewayConfig.clientToAgentConfig.agentGateway."
}

output "egress_gateway_name" {
  value       = "projects/${var.project_id}/locations/${var.region}/agentGateways/${var.prefix}-egress-gateway"
  description = "Full resource path for agentGatewayConfig.agentToAnywhereConfig.agentGateway."
}

# --- Model Armor ---
output "model_armor_template_id" {
  value       = google_model_armor_template.security_high.id
  description = "The ID of the Model Armor high security template (for user prompt screening)."
}

# NOTE: model_armor_template_responses_id will be added here once
# google_model_armor_template.security_responses is provisioned (see KNOWN_ISSUES.md #001).


# --- Project ---
output "project_number" {
  value       = data.google_project.project.number
  description = "Numeric GCP project number — required for direct REST API calls to Vertex AI."
}

# --- Observability ---
output "agent_observability_dashboard_id" {
  value       = module.agent_observability.dashboard_id
  description = "The ID of the Agent Observability dashboard."
}

output "gateway_observability_dashboard_id" {
  value       = module.gateway_observability.dashboard_id
  description = "The ID of the Gateway Observability dashboard."
}

