output "dashboard_url" {
  description = "Console link to the dashboard."
  value       = "https://console.cloud.google.com/monitoring/dashboards/builder/${element(split("/", google_monitoring_dashboard.main.id), 3)}?project=${var.project_id}"
}

output "alert_policy_names" {
  description = "Display names of all alert policies."
  value = concat(
    [for p in google_monitoring_alert_policy.metric : p.display_name],
    [for p in google_monitoring_alert_policy.log : p.display_name],
  )
}

output "alert_keys" {
  description = "Short identifiers of every alert policy."
  value       = sort(concat(keys(local.metric_alerts), keys(local.log_alerts)))
}

output "alert_severities" {
  description = "Distinct severity tiers used by the alert policies."
  value = sort(distinct(concat(
    [for a in local.metric_alerts : a.severity],
    [for a in local.log_alerts : a.severity],
  )))
}

output "all_filters" {
  description = "Every metric filter used by alert policies and dashboard charts (Google requires each to name a resource type)."
  value = concat(
    [for a in local.metric_alerts : a.filter],
    [for a in local.log_alerts : a.filter],
    [for w in local.widgets : w.filter],
  )
}

output "log_alert_filters" {
  description = "Filters of the log-based alerts (Google does not support starts_with() in these)."
  value       = [for a in local.log_alerts : a.filter]
}

output "dashboard_widget_titles" {
  description = "Titles of every widget on the dashboard."
  value       = concat([local.guide_title], [for w in local.widgets : w.title])
}

output "log_metric_names" {
  description = "Business metrics derived from the structured logs."
  value = [
    google_logging_metric.received.name,
    google_logging_metric.processed.name,
    google_logging_metric.dead_lettered.name,
  ]
}

output "notification_channel_count" {
  description = "Number of email notification channels."
  value       = length(google_monitoring_notification_channel.email)
}
