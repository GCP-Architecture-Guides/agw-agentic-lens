# ==============================================================================
# FOUNDATION VARIABLES
# Set once per project/region. These provision the shared security platform:
# gateways, Model Armor, SGP, PSC, observability, org policies.
#
# When consuming this repo as a Terraform module from another project:
#   module "agw_foundation" {
#     source               = "github.com/your-org/mod-agw-foundation"
#     project_id           = "my-team-project"
#     region               = "us-east1"
#     prefix               = "my-team"
#     org_id               = "123456789"
#     allowed_egress_hosts = ["my-api.example.com"]
#     create_agent         = false   # skip agent provisioning, deploy agents separately
#   }
# ==============================================================================

variable "organization_id" {
  description = "The organization ID for defining custom constraints."
  type        = string
}



variable "cloud_run_service_name" {
  description = "Glass UI Cloud Run service name for Model Armor log-based metrics."
  type        = string
  default     = "ai-prism-agent-glass-ui"
}

variable "security_google_chat_space" {
  description = "Google Chat space for Model Armor security alerts (separate from token alerts). Format: spaces/AAAA..."
  type        = string
  default     = ""  # set in terraform.tfvars — install Cloud Monitoring app in the space first
}

variable "security_google_chat_display_name" {
  description = "Display name for the Terraform-managed security Google Chat notification channel."
  type        = string
  default     = null
}

variable "security_notification_channel_ids" {
  description = "Pre-existing security notification channel IDs (use if the Chat channel was created manually in Console)."
  type        = list(string)
  default     = []
}

variable "enable_model_armor_security_alerts" {
  description = "Enable Model Armor prompt-injection surge alert when security notification channels are set."
  type        = bool
  default     = true
}

variable "prompt_injection_alert_threshold" {
  description = "Prompt injection matches per window before alerting (default 10 per minute)."
  type        = number
  default     = 10
}

variable "prompt_injection_alert_window_seconds" {
  description = "Rolling window for counting prompt injection matches."
  type        = number
  default     = 60
}

variable "prompt_injection_alert_duration_seconds" {
  description = "How long the breach must persist before firing (0 = immediate)."
  type        = number
  default     = 0
}


variable "notification_channel_ids" {
  description = "Additional pre-existing Cloud Monitoring notification channel IDs (email, PagerDuty, etc.)."
  type        = list(string)
  default     = []
}

variable "slack_channel_name" {
  description = "Slack channel for Agent Observability alerts (e.g. #agentic-lens-alerts)."
  type        = string
  default     = ""
}

variable "slack_auth_token" {
  description = "Slack Bot User OAuth Token (xoxb-...) with chat:write scopes."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_display_name" {
  description = "Display name for the Terraform-managed Slack notification channel."
  type        = string
  default     = null
}

variable "google_chat_space" {
  description = "Google Chat space ID (spaces/AAAA...). Install the Cloud Monitoring app in the space first."
  type        = string
  default     = ""  # set in terraform.tfvars
}

variable "google_chat_display_name" {
  description = "Display name for the Terraform-managed Google Chat notification channel."
  type        = string
  default     = null
}

variable "enable_token_alerts" {
  description = "Enable Agent Observability alert policies (AL1–AL6) when notification channels are configured."
  type        = bool
  default     = true
}

variable "alert_email_address" {
  description = "AL7: email address for token alert notifications."
  type        = string
  default     = ""
}

variable "alert_email_display_name" {
  description = "Display name for the Terraform-managed email notification channel."
  type        = string
  default     = null
}

variable "enable_alert_baseline_spike" {
  description = "AL1: per-agent spike vs 1-day baseline."
  type        = bool
  default     = true
}

variable "enable_alert_runaway_loop" {
  description = "AL2: suspected runaway LLM loop."
  type        = bool
  default     = true
}

variable "enable_alert_project_surge" {
  description = "AL3: project-wide Vertex token surge."
  type        = bool
  default     = true
}

variable "enable_alert_absolute_ceiling" {
  description = "AL4: per-agent absolute token ceiling."
  type        = bool
  default     = true
}

variable "enable_alert_error_correlation" {
  description = "AL5: per-agent token spike with llm_usage errors."
  type        = bool
  default     = true
}

variable "enable_alert_zero_traffic" {
  description = "AL6: no llm_usage traffic project-wide (optional)."
  type        = bool
  default     = false
}

variable "project_token_surge_threshold" {
  description = "AL3: project tokens per 15-minute bucket before alerting."
  type        = number
  default     = 750000
}

variable "project_surge_duration_seconds" {
  description = "AL3: how long the surge must persist before firing."
  type        = number
  default     = 900
}

variable "per_agent_baseline_spike_percent" {
  description = "AL1: percent increase vs same bucket 1 day ago (200 = 2×)."
  type        = number
  default     = 200
}

variable "per_agent_baseline_spike_duration_seconds" {
  description = "AL1: sustained duration before firing."
  type        = number
  default     = 1800
}

variable "per_agent_absolute_ceiling_threshold" {
  description = "AL4: hard token ceiling per agent per 15-minute bucket."
  type        = number
  default     = 100000
}

variable "per_agent_absolute_ceiling_duration_seconds" {
  description = "AL4: sustained duration before firing."
  type        = number
  default     = 1800
}

variable "runaway_loop_call_threshold" {
  description = "AL2: LLM calls per agent per 15-minute bucket."
  type        = number
  default     = 30
}

variable "runaway_loop_min_tokens" {
  description = "AL2: minimum tokens in the same bucket."
  type        = number
  default     = 5000
}

variable "runaway_loop_duration_seconds" {
  description = "AL2: sustained duration before firing."
  type        = number
  default     = 900
}

variable "error_correlation_token_threshold" {
  description = "AL5: tokens per 15-minute bucket when paired with errors."
  type        = number
  default     = 50000
}

variable "error_correlation_error_threshold" {
  description = "AL5: llm_usage errors per 15-minute bucket per agent."
  type        = number
  default     = 3
}

variable "error_correlation_duration_seconds" {
  description = "AL5: sustained duration before firing."
  type        = number
  default     = 900
}

variable "zero_traffic_duration_seconds" {
  description = "AL6: duration with zero llm_usage calls before alerting."
  type        = number
  default     = 21600
}

variable "per_agent_token_spike_threshold" {
  description = "Deprecated alias for per_agent_absolute_ceiling_threshold (AL4)."
  type        = number
  default     = null
}

variable "per_agent_spike_duration_seconds" {
  description = "Deprecated alias for per_agent_absolute_ceiling_duration_seconds (AL4)."
  type        = number
  default     = null
}

variable "enable_org_observability" {
  description = "Create metrics scope members and the Org Agentic Observability dashboard on the hub project."
  type        = bool
  default     = true
}

variable "org_metrics_scope_project_id" {
  description = "Hub GCP project for org metrics scope and the Org Agentic Observability dashboard. Defaults to project_id (this project) when null. Change only if you have a dedicated observability hub project."
  type        = string
  default     = null
}

variable "org_monitored_project_ids" {
  description = <<-EOT
    GCP project IDs to add to the org metrics scope so their agents appear in the
    Org Agentic Observability dashboard. The hub project (project_id) is always
    included automatically.

    Growth path: each time a new team deploys their own per-team gateway in a
    separate GCP project, add that project_id here and run terraform apply.
    No other changes needed — the dashboard auto-discovers agents within each
    project via resource.project_id grouping.

    Example:
      org_monitored_project_ids = [
        "hr-team-project",
        "code-review-project",
        "data-platform-project",
      ]
  EOT
  type        = list(string)
  default     = []
}


# ==============================================================================
# CORE IDENTITY VARIABLES (required by all consumers)
# ==============================================================================

variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "region" {
  description = "The GCP region."
  type        = string
}

variable "location" {
  description = "The GCP location."
  type        = string
}

variable "prefix" {
  description = "Prefix for resources (e.g. 'acme-corp', 'my-team'). Used as a name prefix for all gateway, Model Armor, and network resources."
  type        = string
}

variable "create_agent" {
  description = "When true (default), deploys the chat-agent Reasoning Engine via 06_agent_provisioning.tf. Set to false when using this repo as a Terraform module — consuming projects deploy their own agents separately."
  type        = bool
  default     = true
}

# ==============================================================================
# AGENT VARIABLES
# Customize per agent/use case. Only used when create_agent = true.
# ==============================================================================

variable "agent_name" {
  type        = string
  description = "The display name of the deployed agent."
  default     = "chat-agent-v1"
}

variable "agent_description" {
  type        = string
  description = "A description of what the agent does."
  default     = "A sample chat agent with telemetry and gateway routing."
}

variable "agent_department" {
  type        = string
  description = "The department label for the agent."
  default     = "engineering"
}

variable "agent_team" {
  type        = string
  description = "The team label for the agent."
  default     = "sec-ops"
}

variable "allowed_egress_hosts" {
  type        = list(string)
  description = "List of external API hosts (like DEV or PRD endpoints) the agent is allowed to access via the Gateway."
  default = [
    "cloudasset.googleapis.com",
    "logging.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudresourcemanager.mtls.googleapis.com",
    "storage.googleapis.com",
    "cloudtrace.googleapis.com",
    "discoveryengine.googleapis.com",
    "github.com",
    "api.github.com",
    "raw.githubusercontent.com",
    "www.googleapis.com",
    "docs.cloud.google.com",
    "www.google.com",
    "iamcredentials.googleapis.com",
    "oauth2.googleapis.com",
    "secretmanager.googleapis.com",
    "terraform.io",
    "aiplatform.googleapis.com",
    # OTEL trace export: ADK sends spans to telemetry.googleapis.com/v1/traces
    # Without this, the OTEL BatchSpanProcessor SSL context crash kills Thread-2
    # after the first query — all subsequent queries return 0 events.
    # See: KNOWN_ISSUES.md #007
    "telemetry.googleapis.com"
  ]
}

variable "agent_role" {
  type        = string
  description = "The role label for the agent telemetry."
  default     = "customer-support"
}

# ==============================================================================
# SGP SEMANTIC GOVERNANCE POLICY
# ==============================================================================

variable "sgp_nlc_constraint" {
  type        = string
  description = <<-EOT
    Natural-language constraint for the Semantic Governance Policy (SGP) engine.
    This text defines what the agent is semantically ALLOWED and DENIED to do.
    The SGP engine evaluates every request against this constraint before the
    agent processes it.

    The value is passed to create_sgp_policy.sh and can also be overridden at
    runtime via the SGP_NLC_CONSTRAINT environment variable.

    Leave empty ("") to use the default constraint built from agent_name and
    agent_description.

    For language-scoped agents (Python/Terraform/Bash only), use the default
    below or adapt it to your agent's specific purpose.
  EOT
  default     = ""
}

# ==============================================================================
# IAP (Identity-Aware Proxy) — Ingress Identity Enforcement
# Configures IAP as a REQUEST_AUTHZ extension on the ingress gateway.
# IAP verifies the caller's Google identity before Model Armor content checks.
# This is the centralized identity door for ALL agents behind this gateway.
# Distinct from Vertex AI IAM (per-RE) — IAP applies at the gateway level.
# Pattern: authz_extension (service=iap.googleapis.com) + REQUEST_AUTHZ policy
# Note: callers must have roles/iap.httpsResourceAccessor in iap_allowed_members.
# ==============================================================================

variable "iap_allowed_members" {
  description = <<-EOT
    List of identities granted roles/iap.httpsResourceAccessor on the Agent Gateway.
    Only these identities can invoke Reasoning Engines through the ingress gateway.
    Use standard IAM member format:
      - "user:alice@example.com"
      - "serviceAccount:my-sa@project.iam.gserviceaccount.com"
      - "group:my-team@example.com"
    Leave empty ([]) to skip the IAM binding (add manually via Console instead).
  EOT
  type        = list(string)
  default     = []
}

variable "iap_enabled" {
  description = <<-EOT
    Set to true to deploy the IAP authz extension on the ingress gateway.
    When false (default), the IAP extension and policy resources are not created.
    The ingress gateway still enforces Model Armor content policies.
    IAP adds identity-layer enforcement on top — only iap_allowed_members
    can invoke Reasoning Engines through the gateway.
  EOT
  type        = bool
  default     = false
}
