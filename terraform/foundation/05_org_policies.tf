locals {
  safe_prefix = replace(var.prefix, "/[^a-zA-Z0-9]/", "")
}

resource "google_org_policy_custom_constraint" "agent_gateway_config" {
  name           = "custom.${local.safe_prefix}EnforceReasoningEngineAgentGatewayConfig"
  parent         = "organizations/${var.organization_id}"
  display_name   = "${var.prefix} - Enforce Agent Gateway Config for Reasoning Engines"
  description    = "Ensures Reasoning Engine deployments use the configured Agent Gateway."
  action_type    = "ALLOW"
  condition      = "has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)"
  method_types   = ["CREATE", "UPDATE"]
  resource_types = ["aiplatform.googleapis.com/ReasoningEngine"]
}

resource "google_org_policy_custom_constraint" "agent_identity" {
  name           = "custom.${local.safe_prefix}EnforceAgentIdentityForReasoningEngine"
  parent         = "organizations/${var.organization_id}"
  display_name   = "${var.prefix} - Enforce AGENT_IDENTITY for Reasoning Engines"
  description    = "Ensures Reasoning Engines are deployed with an explicit Agent Identity instead of User Identity."
  action_type    = "ALLOW"
  condition      = "resource.spec.identityType == \"AGENT_IDENTITY\""
  method_types   = ["CREATE", "UPDATE"]
  resource_types = ["aiplatform.googleapis.com/ReasoningEngine"]
}

resource "google_org_policy_custom_constraint" "otel_config" {
  name           = "custom.${local.safe_prefix}EnforceReasoningEngineOtelConfig"
  parent         = "organizations/${var.organization_id}"
  display_name   = "${var.prefix} - Enforce Otel Config with Tags for Reasoning Engines"
  description    = "Ensures Reasoning Engines deploy with OpenTelemetry and required organizational metadata tags."
  action_type    = "ALLOW"
  condition      = "has(resource.spec.deploymentSpec.env) && resource.spec.deploymentSpec.env.exists(e, e.name == \"GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY\") && resource.spec.deploymentSpec.env.exists(e, e.name == \"agent_name\") && resource.spec.deploymentSpec.env.exists(e, e.name == \"agent_description\") && resource.spec.deploymentSpec.env.exists(e, e.name == \"agent_department\") && resource.spec.deploymentSpec.env.exists(e, e.name == \"agent_team\") && resource.spec.deploymentSpec.env.exists(e, e.name == \"agent_role\")"
  method_types   = ["CREATE", "UPDATE"]
  resource_types = ["aiplatform.googleapis.com/ReasoningEngine"]
}

# Add sleep to handle eventual consistency when the OrgPolicy API is enabled
# and when constraints are propagated from the Org level.
resource "time_sleep" "wait_for_org_policy_propagation" {
  depends_on = [
    google_org_policy_custom_constraint.agent_gateway_config,
    google_org_policy_custom_constraint.agent_identity,
    google_org_policy_custom_constraint.otel_config,
    google_project_service.orgpolicy
  ]

  create_duration = "180s"
}

resource "google_org_policy_policy" "enforce_agent_gateway_config" {
  name   = "projects/${var.project_id}/policies/custom.${local.safe_prefix}EnforceReasoningEngineAgentGatewayConfig"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }

  depends_on = [time_sleep.wait_for_org_policy_propagation]
}

resource "google_org_policy_policy" "enforce_agent_identity" {
  name   = "projects/${var.project_id}/policies/custom.${local.safe_prefix}EnforceAgentIdentityForReasoningEngine"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }

  depends_on = [time_sleep.wait_for_org_policy_propagation]
}

resource "google_org_policy_policy" "enforce_otel_config" {
  name   = "projects/${var.project_id}/policies/custom.${local.safe_prefix}EnforceReasoningEngineOtelConfig"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }

  depends_on = [time_sleep.wait_for_org_policy_propagation]
}
