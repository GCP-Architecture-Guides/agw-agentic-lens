# ------------------------------------------------------------------------------
# 4. OBSERVABILITY DASHBOARDS & ALERTS
# ------------------------------------------------------------------------------
module "lens_model_armor" {
  source = "./modules/lens_model_armor"

  project_id                              = var.project_id
  cloud_run_service_name                  = var.cloud_run_service_name
  security_google_chat_space              = var.security_google_chat_space
  security_google_chat_display_name       = var.security_google_chat_display_name
  security_notification_channel_ids       = var.security_notification_channel_ids
  enable_model_armor_security_alerts      = var.enable_model_armor_security_alerts
  prompt_injection_alert_threshold        = var.prompt_injection_alert_threshold
  prompt_injection_alert_window_seconds   = var.prompt_injection_alert_window_seconds
  prompt_injection_alert_duration_seconds = var.prompt_injection_alert_duration_seconds
}

module "gateway_observability" {
  source = "./modules/gateway_observability"

  project_id             = var.project_id
  cloud_run_service_name = var.cloud_run_service_name

  depends_on = [module.lens_model_armor]
}

module "org_observability" {
  count  = var.enable_org_observability ? 1 : 0
  source = "./modules/org_observability"

  metrics_scope_project_id           = coalesce(var.org_metrics_scope_project_id, var.project_id)
  monitored_project_ids              = var.org_monitored_project_ids
  scope_project_agent_dashboard_id   = module.agent_observability.dashboard_id
  scope_project_gateway_dashboard_id = module.gateway_observability.dashboard_id

  depends_on = [
    module.agent_observability,
    module.gateway_observability,
  ]
}

module "agent_observability" {
  source = "./modules/agent_observability"

  project_id                                  = var.project_id
  notification_channel_ids                    = var.notification_channel_ids
  slack_channel_name                          = var.slack_channel_name
  slack_auth_token                            = var.slack_auth_token
  slack_display_name                          = var.slack_display_name
  google_chat_space                           = var.google_chat_space
  google_chat_display_name                    = var.google_chat_display_name
  alert_email_address                         = var.alert_email_address
  alert_email_display_name                    = var.alert_email_display_name
  enable_token_alerts                         = var.enable_token_alerts
  enable_alert_baseline_spike                 = var.enable_alert_baseline_spike
  enable_alert_runaway_loop                   = var.enable_alert_runaway_loop
  enable_alert_project_surge                  = var.enable_alert_project_surge
  enable_alert_absolute_ceiling               = var.enable_alert_absolute_ceiling
  enable_alert_error_correlation              = var.enable_alert_error_correlation
  enable_alert_zero_traffic                   = var.enable_alert_zero_traffic
  project_token_surge_threshold               = var.project_token_surge_threshold
  project_surge_duration_seconds              = var.project_surge_duration_seconds
  per_agent_baseline_spike_percent            = var.per_agent_baseline_spike_percent
  per_agent_baseline_spike_duration_seconds   = var.per_agent_baseline_spike_duration_seconds
  per_agent_absolute_ceiling_threshold        = var.per_agent_absolute_ceiling_threshold
  per_agent_absolute_ceiling_duration_seconds = var.per_agent_absolute_ceiling_duration_seconds
  runaway_loop_call_threshold                 = var.runaway_loop_call_threshold
  runaway_loop_min_tokens                     = var.runaway_loop_min_tokens
  runaway_loop_duration_seconds               = var.runaway_loop_duration_seconds
  error_correlation_token_threshold           = var.error_correlation_token_threshold
  error_correlation_error_threshold           = var.error_correlation_error_threshold
  error_correlation_duration_seconds          = var.error_correlation_duration_seconds
  zero_traffic_duration_seconds               = var.zero_traffic_duration_seconds
  per_agent_token_spike_threshold             = var.per_agent_token_spike_threshold
  per_agent_spike_duration_seconds            = var.per_agent_spike_duration_seconds
}

