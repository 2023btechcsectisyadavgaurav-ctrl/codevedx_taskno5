output "api_url" {
  description = "HTTPS URL of the API."
  value       = module.functions.api_url
}

output "api_key" {
  description = "Value for the X-API-Key header (sensitive). Show it with: terraform output -raw api_key"
  value       = random_password.api_key.result
  sensitive   = true
}

output "project_id" {
  description = "Project the application runs in."
  value       = var.project_id
}

output "region" {
  description = "Region of the functions."
  value       = var.region
}

output "function_names" {
  description = "Cloud Run service name of each function."
  value       = module.functions.service_names
}

output "orders_topic" {
  description = "Pub/Sub topic the API publishes orders to."
  value       = module.messaging.orders_topic_name
}

output "dead_letter_topic" {
  description = "Pub/Sub topic holding orders that failed every attempt."
  value       = module.messaging.dead_letter_topic_name
}

output "dead_letter_subscription" {
  description = "Pull subscription for inspecting dead-lettered orders."
  value       = module.messaging.dead_letter_subscription
}

output "report_job" {
  description = "Cloud Scheduler job that triggers the report (run it on demand with gcloud scheduler jobs run)."
  value       = module.messaging.report_job_name
}

output "database" {
  description = "Firestore database ID."
  value       = module.data.database_name
}

output "dashboard_url" {
  description = "Link to the Cloud Monitoring dashboard in the console."
  value       = module.monitoring.dashboard_url
}

output "alert_policy_names" {
  description = "Display names of every alert policy."
  value       = module.monitoring.alert_policy_names
}

output "notification_channels" {
  description = "Number of email notification channels created."
  value       = module.monitoring.notification_channel_count
}

# Exposed so the automated tests (tests/*.tftest.hcl) can assert on the design at plan time.
output "serverless_summary" {
  description = "Scaling, cost, reliability and security settings, asserted by the test suite."
  value = {
    functions            = module.functions.config
    runtime_roles        = module.functions.runtime_roles
    build_roles          = module.functions.build_roles
    source_bucket_public = module.functions.source_bucket_public_access
    public_api           = module.functions.public_api
    database_type        = module.data.database_type
    report_schedule      = module.messaging.report_schedule
    alert_keys           = module.monitoring.alert_keys
    alert_severities     = module.monitoring.alert_severities
    all_filters          = module.monitoring.all_filters
    log_alert_filters    = module.monitoring.log_alert_filters
    dashboard_widgets    = module.monitoring.dashboard_widget_titles
    log_metrics          = module.monitoring.log_metric_names
  }
}
