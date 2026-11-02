locals {
  # Google requires every metric filter to name a resource type, so every scope below does.
  api_scope    = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.api_service}\""
  all_fn_scope = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=starts_with(\"${var.name}-\")"
  log_scope    = "resource.type=\"cloud_run_revision\""
  # Log-alert filters do not support starts_with(); list the three services explicitly instead.
  fn_log_scope   = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=(\"${var.api_service}\" OR \"${var.processor_service}\" OR \"${var.report_service}\")"
  pubsub_scope   = "resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=starts_with(\"eventarc-\")"
  metric_prefix  = replace(var.name, "-", "_")
  received_name  = "${local.metric_prefix}_orders_received"
  processed_name = "${local.metric_prefix}_orders_processed"
  dead_name      = "${local.metric_prefix}_orders_dead_lettered"

  channel_ids = [for c in google_monitoring_notification_channel.email : c.id]
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.alert_emails)

  project      = var.project_id
  display_name = "${var.name} | email ${each.value}"
  type         = "email"

  labels = {
    email_address = each.value
  }
}

# ---------------------------------------------------------------------------
# Business metrics from the structured logs
# ---------------------------------------------------------------------------
resource "google_logging_metric" "received" {
  project     = var.project_id
  name        = local.received_name
  description = "Orders accepted by the API"
  filter      = "${local.log_scope} AND jsonPayload.event=\"order_received\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "processed" {
  project     = var.project_id
  name        = local.processed_name
  description = "Orders processed successfully by the worker"
  filter      = "${local.log_scope} AND jsonPayload.event=\"order_processed\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "dead_lettered" {
  project     = var.project_id
  name        = local.dead_name
  description = "Orders that failed every attempt and were dead-lettered"
  filter      = "${local.log_scope} AND jsonPayload.event=\"dead_lettered\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}
