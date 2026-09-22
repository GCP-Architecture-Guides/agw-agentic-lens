# ------------------------------------------------------------------------------
# 3. SECURITY & GOVERNANCE POLICIES
# ------------------------------------------------------------------------------
# --- Data Access Audit Logs (Capture Prompts/Responses) ---
resource "google_project_iam_audit_config" "vertex_ai_audit_logs" {
  project = var.project_id
  service = "aiplatform.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# --- DLP Inspect Template ---
resource "google_data_loss_prevention_inspect_template" "identification_template" {
  parent       = "projects/${var.project_id}/locations/${var.location}"
  template_id  = "identification-template"
  display_name = "Identification template"
  description  = "Detects SSN, email, GCP credentials, credit card, medical and FDA/ICD codes."
  depends_on   = [google_project_service.dlp]

  inspect_config {
    min_likelihood = "POSSIBLE"
    include_quote  = true

    info_types { name = "US_SOCIAL_SECURITY_NUMBER" }
    info_types { name = "EMAIL_ADDRESS" }
    info_types { name = "GCP_API_KEY" }
    info_types { name = "GCP_CREDENTIALS" }
    info_types { name = "CREDIT_CARD_NUMBER" }
    info_types { name = "BLOOD_TYPE" }
    info_types { name = "FDA_CODE" }
    info_types { name = "ICD10_CODE" }
    info_types { name = "ICD9_CODE" }
    info_types { name = "MEDICAL_TERM" }
  }
}

# --- DLP Deidentify Template ---
resource "google_data_loss_prevention_deidentify_template" "deidentify_template" {
  parent       = "projects/${var.project_id}/locations/${var.location}"
  template_id  = "deidentify-replace-with-infotype"
  display_name = "Deidentify replace with info type"
  description  = "Replaces sensitive text with the info type name (e.g. [EMAIL_ADDRESS])."
  depends_on   = [google_project_service.dlp]

  deidentify_config {
    info_type_transformations {
      transformations {
        info_types { name = "US_SOCIAL_SECURITY_NUMBER" }
        info_types { name = "EMAIL_ADDRESS" }
        info_types { name = "GCP_API_KEY" }
        info_types { name = "GCP_CREDENTIALS" }
        info_types { name = "CREDIT_CARD_NUMBER" }
        info_types { name = "BLOOD_TYPE" }
        info_types { name = "FDA_CODE" }
        info_types { name = "ICD10_CODE" }
        info_types { name = "ICD9_CODE" }
        info_types { name = "MEDICAL_TERM" }

        primitive_transformation {
          replace_with_info_type_config = true
        }
      }
    }
  }
}

# --- Model Armor Templates ---
resource "google_model_armor_template" "security_high" {
  template_id = "security-high"
  location    = var.location
  project     = var.project_id
  depends_on  = [google_project_service.modelarmor, google_data_loss_prevention_inspect_template.identification_template, google_data_loss_prevention_deidentify_template.deidentify_template]

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "HIGH" # Applied to USER prompts only (request_template_id)
    }
    sdp_settings {
      advanced_config {
        inspect_template    = google_data_loss_prevention_inspect_template.identification_template.id
        deidentify_template = google_data_loss_prevention_deidentify_template.deidentify_template.id
      }
    }
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
    rai_settings {
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "HIGH"
      }
    }
  }
  template_metadata {
    log_sanitize_operations = true
    log_template_operations = true
  }
}

# --- Authz Extensions ---
resource "google_network_services_authz_extension" "ma_extension" {
  provider = google-beta
  name     = "${var.prefix}-ma-extension"
  location = var.location
  project  = var.project_id
  service  = "modelarmor.${var.location}.rep.googleapis.com"
  timeout  = "3s"

  metadata = {
    model_armor_settings = jsonencode([
      {
        # INPUT screening only: PI/Jailbreak + SDP + RAI + malicious URIs applied to user prompts.
        # OUTPUT screening removed: the Vertex AI RE platform wraps :streamQuery responses in
        # gRPC-HTTP transcoding format (contentType/extensions metadata) that falsely triggers
        # the PI/Jailbreak filter. Model response safety is enforced by Gemini's built-in harm
        # filters at the model layer — these are always active and cannot be bypassed.
        request_template_id = "projects/${var.project_id}/locations/${var.location}/templates/security-high"
      }
    ])
  }

  depends_on = [google_project_service.networkservices, google_model_armor_template.security_high]
}



# --- Ingress Authz Policies ---
resource "google_network_security_authz_policy" "ingress_ma_policy" {
  provider       = google-beta
  name           = "${var.prefix}-ma-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.ma_extension.id]
    }
  }
}



# --- Egress Authz Policies ---


resource "google_network_security_authz_policy" "egress_ma_policy" {
  provider       = google-beta
  name           = "${var.prefix}-ma-egress-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.ma_extension.id]
    }
  }

  http_rules {
    to {
      # Covers both:
      #   - Regional: us-central1-aiplatform.googleapis.com (suffix match)
      #   - Global:   aiplatform.googleapis.com (explicit exact match for GlobalGemini / Gemini 2.5+)
      # Note: the API only allows ONE operations block per to{} — both host variants
      # must be declared as separate hosts{} entries within the same block.
      operations {
        hosts { suffix = ".aiplatform.googleapis.com" }
        hosts { exact  = "aiplatform.googleapis.com" }
        paths {
          contains    = "generatecontent"
          ignore_case = true
        }
        paths {
          contains    = "predict"
          ignore_case = true
        }
        paths {
          contains    = "streamquery"
          ignore_case = true
        }
        paths {
          contains    = "sessions"
          ignore_case = true
        }
        paths {
          contains    = "events"
          ignore_case = true
        }
      }
    }
  }
}


# =========================================================================
# AUTOMATED SEMANTIC GOVERNANCE POLICY (SGP) ENGINE PROVISIONING
# =========================================================================
data "external" "sgp_engine" {
  program = ["bash", "${path.module}/scripts/provision_sgp_engine.sh", var.project_id, var.location]

  depends_on = [google_project_service.aiplatform]
}


# --- SGP Authz Extension & Policy ---
resource "google_network_services_authz_extension" "sgp_extension" {
  provider = google-beta
  name     = "${var.prefix}-sgp-extension"
  location = var.location
  project  = var.project_id
  service  = "sgp.internal.gemini-corp"
  timeout  = "3s"

  depends_on = [google_project_service.networkservices]
}

resource "google_network_security_authz_policy" "egress_sgp_policy" {
  provider       = google-beta
  name           = "${var.prefix}-sgp-egress-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.sgp_extension.id]
    }
  }

  # NOTE: The SGP extension (sgp.internal.gemini-corp) with CONTENT_AUTHZ profile
  # does NOT support http_rules — the API enforces this constraint.
  # The SGP evaluates ALL outbound content semantically by design.
  # Egress allowlist enforcement is handled at the PSC routing level:
  # hosts not registered in allowed_egress_hosts have no PSC route and are
  # blocked by the gateway's deny-by-default posture at the routing layer.
}

# ==============================================================================
# INGRESS ENFORCEMENT — RESTRICT DIRECT REASONING ENGINE ACCESS
# ==============================================================================
# The ideal enforcement is an IAM Deny Policy (IAM v2 API) that would deny
# aiplatform.reasoningEngines.query + streamQuery to all human identities,
# forcing 100% of traffic through the Agent Gateway. However, the IAM v2 API
# endpoint (iam.googleapis.com/v2) is unreachable from this deployment
# environment (network-level block on the deny-policies API path).
#
# Current enforcement layers (defence in depth without IAM Deny):
#   Layer 1 — Content authz (MA/DLP/SGP):
#       The RE's agentGatewayConfig.clientToAgentConfig triggers the ingress
#       gateway's authz extension for ALL calls to this RE via the Vertex AI
#       API — including direct calls from Agent Playground. Prompt injection,
#       DLP violations, and RAI violations are blocked at 403 regardless of how
#       the RE is invoked.
#   Layer 2 — Egress PSC routing:
#       The RE's agentGatewayConfig.agentToAnywhereConfig routes all outbound
#       traffic through the egress gateway's PSC attachment. Hosts not
#       registered in allowed_egress_hosts have no PSC route and are dropped.
#   Layer 3 — fetch_url explicit failure:
#       fetch_url() now returns [GATEWAY BLOCKED] on ConnectionError/Timeout,
#       preventing the model from hallucinating content when egress is blocked.
#   Layer 4 — Explicit gateway SA grant:
#       The gateway SA is explicitly granted reasoningEngines.queryer below.
#       This makes the gateway's service identity unambiguous in audit logs.
#
# Remaining gap (tracked):
#   Users with roles/owner can still call the RE directly with their own
#   credentials, bypassing Layer 1 content policies. Full closure requires
#   either: (a) IAM Deny policy (blocked here), (b) VPC Service Controls
#   perimeter around aiplatform.googleapis.com, or (c) removing roles/owner
#   and granting scoped roles only.
# ==============================================================================

# NOTE: roles/aiplatform.reasoningEngines.queryer is a resource-level role and
# cannot be bound at the project scope — grant it per-RE resource if needed.
# The gateway SA receives access to invoke the RE through the platform-level
# agentGatewayConfig.clientToAgentConfig binding set during agent deployment.

# ==============================================================================
# IAP (Identity-Aware Proxy) — Ingress Identity Enforcement
# ==============================================================================
# Gated by var.iap_enabled (default: false).
# Set iap_enabled = true in terraform.tfvars to enforce that only
# iap_allowed_members can call the Agent Gateway.
#
# Purpose: IAP at the gateway level is the CENTRALIZED identity control for ALL
# agents behind this gateway. It answers "is this caller allowed to use this
# gateway?" before content policies (Model Armor / SGP) are evaluated.
# This complements — not replaces — Vertex AI IAM (which is per-RE).
#
# Recommended combined pattern (from official docs):
#   REQUEST_AUTHZ policy (IAP)   → who can access the gateway
#   CONTENT_AUTHZ policy (MA)    → what content is allowed through
#
# Per official docs (docs.cloud.google.com/gemini-enterprise-agent-platform/
#   govern/gateways/delegate-authorization#configure-authz-iap):
#   - service: iap.googleapis.com  (global, NOT a regional REP endpoint)
#   - policy_profile: REQUEST_AUTHZ
#   - metadata.iapPolicyVersion: "V1"  (required — extension will fail without it)
#
# Dependency chain:
#   google_project_service.iap
#     → google_network_services_authz_extension.iap_extension
#       → google_network_security_authz_policy.ingress_iap_policy
#   google_project_iam_member.iap_accessor  (parallel — grants caller access)
# ==============================================================================

# IAP Authz Extension — delegates access decisions to IAP
# Note: iapPolicyVersion = "V1" is REQUIRED in metadata per the official spec.
# Fail-closed behavior (deny if IAP unreachable) is the API default for authz extensions.
resource "google_network_services_authz_extension" "iap_extension" {
  count    = var.iap_enabled ? 1 : 0
  provider = google-beta

  name     = "${var.prefix}-iap-extension"
  location = var.location
  project  = var.project_id

  # Global IAP service endpoint (not a regional REP endpoint like Model Armor)
  service  = "iap.googleapis.com"
  timeout  = "1s"

  metadata = {
    iapPolicyVersion = "V1" # Required — extension will reject requests without this
  }

  depends_on = [google_project_service.iap]
}

# IAP Authz Policy — attaches the IAP extension to the INGRESS gateway.
# Profile: REQUEST_AUTHZ — IAP verifies caller identity on every inbound request.
# (Distinct from CONTENT_AUTHZ used by Model Armor, which inspects request body)
resource "google_network_security_authz_policy" "ingress_iap_policy" {
  count    = var.iap_enabled ? 1 : 0
  provider = google-beta

  name           = "${var.prefix}-iap-ingress-policy"
  location       = var.location
  project        = var.project_id

  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ" # Identity-based check (not PRINCIPAL_AUTHZ)

  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.iap_extension[0].id]
    }
  }

  depends_on = [google_network_services_authz_extension.iap_extension]
}

# Grant allowed identities the IAP accessor role so they pass the extension check
resource "google_project_iam_member" "iap_accessor" {
  for_each = var.iap_enabled ? toset(var.iap_allowed_members) : toset([])

  project = var.project_id
  role    = "roles/iap.httpsResourceAccessor"
  member  = each.value
}
