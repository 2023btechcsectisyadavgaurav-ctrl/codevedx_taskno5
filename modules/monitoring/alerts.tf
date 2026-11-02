# Alert policies, tiered by urgency:  WARNING = look soon,  ERROR = users may be affected,  CRITICAL = act now.
# Each policy embeds its own runbook in the notification.

locals {
  # Metric-based alerts (Cloud Run and Pub/Sub platform metrics)
  metric_alerts = {
    api_errors = {
      severity   = "ERROR"
      title      = "API returning server errors (more than ${var.error_threshold_count} in 5 minutes)"
      filter     = "metric.type=\"run.googleapis.com/request_count\" AND ${local.api_scope} AND metric.labels.response_code_class=\"5xx\""
      aligner    = "ALIGN_SUM"
      reducer    = "REDUCE_SUM"
      period     = 300
      comparison = "COMPARISON_GT"
      threshold  = var.error_threshold_count
      duration   = 0
      doc        = <<-EOT
        **The API is failing requests (HTTP 5xx).**

        1. Open the dashboard: do errors line up with a deployment or a traffic spike?
        2. Logs Explorer: `resource.type="cloud_run_revision" severity>=ERROR` shows the failing path and error.
        3. If a new revision caused it, roll back (see docs/OPERATIONS.md, "Rollback").
      EOT
    }

    api_latency = {
      severity   = "WARNING"
      title      = "API p95 latency above ${var.latency_threshold_ms} ms"
      filter     = "metric.type=\"run.googleapis.com/request_latencies\" AND ${local.api_scope}"
      aligner    = "ALIGN_PERCENTILE_95"
      reducer    = ""
      period     = 60
      comparison = "COMPARISON_GT"
      threshold  = var.latency_threshold_ms
      duration   = 300
      doc        = <<-EOT
        **The slowest 5% of API requests are slower than ${var.latency_threshold_ms} ms for 5 minutes.**

        1. Check for cold starts (instance count rising from 0) and Firestore latency.
        2. If cold starts dominate and latency matters, set `min_instances = 1` (costs money all month).
        3. If memory utilization is high, raise `memory_mb`.
      EOT
    }

    backlog_age = {
      severity   = "ERROR"
      title      = "Orders waiting unprocessed for more than ${floor(var.backlog_age_seconds / 60)} minutes"
      filter     = "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND ${local.pubsub_scope}"
      aligner    = "ALIGN_MAX"
      reducer    = ""
      period     = 60
      comparison = "COMPARISON_GT"
      threshold  = var.backlog_age_seconds
      duration   = 300
      doc        = <<-EOT
        **Order messages are not being consumed.** The processor is failing, throttled by max_instances, or not running.

        1. Check processor errors: `resource.labels.service_name="${var.processor_service}" severity>=ERROR`.
        2. Check the instance cap: the dashboard shows active instances against `max_instances`.
        3. Orders that fail repeatedly end up in the dead-letter topic; see docs/OPERATIONS.md.
      EOT
    }

    memory_pressure = {
      severity   = "WARNING"
      title      = "Function memory above 85% (right-sizing signal)"
      filter     = "metric.type=\"run.googleapis.com/container/memory/utilizations\" AND ${local.all_fn_scope}"
      aligner    = "ALIGN_PERCENTILE_99"
      reducer    = ""
      period     = 60
      comparison = "COMPARISON_GT"
      threshold  = 0.85
      duration   = 600
      doc        = <<-EOT
        **A function is close to its memory limit.** It risks being killed (out of memory), which appears as 5xx or retries.

        Raise `memory_mb` one step (for example 256 to 512) and watch the memory chart. Also review whether the code loads too much data.
      EOT
    }
  }

  # Log-based alerts: match structured log entries directly, so they fire within about a minute.
  log_alerts = {
    dead_lettered = {
      severity = "CRITICAL"
      title    = "Order dead-lettered (failed every attempt)"
      filter   = "${local.log_scope} AND jsonPayload.event=\"dead_lettered\""
      doc      = <<-EOT
        **An order could not be processed after every retry and was moved to the dead-letter topic.**

        1. Read the log entry: `order_id` and `reason` explain why.
        2. Inspect the parked message: `gcloud pubsub subscriptions pull <dead-letter subscription> --limit=5`.
        3. Fix the cause (data or code), then re-submit the order.
      EOT
    }

    publish_failed = {
      severity = "ERROR"
      title    = "Order stored but could not be queued"
      filter   = "${local.log_scope} AND jsonPayload.event=\"publish_failed\""
      doc      = <<-EOT
        **The API accepted an order but Pub/Sub refused the message.** The caller received HTTP 503 and should retry; the order is marked `publish_failed`.

        1. Check Pub/Sub status and the runtime identity's publisher permission.
        2. After the fix, re-submit the affected orders.
      EOT
    }

    function_errors = {
      severity = "WARNING"
      title    = "Unexpected error in a function"
      filter   = "${local.fn_log_scope} AND severity>=ERROR AND NOT jsonPayload.event=\"dead_lettered\" AND NOT jsonPayload.event=\"publish_failed\""
      doc      = <<-EOT
        **A function logged an error that is not a known failure mode.**

        Open the log entry for the stack trace. Repeated errors on the same path usually mean a bug introduced by the latest revision.
      EOT
    }
  }
}

resource "google_monitoring_alert_policy" "metric" {
  for_each = local.metric_alerts

  project               = var.project_id
  display_name          = "[${each.value.severity}] ${var.name} | ${each.value.title}"
  combiner              = "OR"
  severity              = each.value.severity
  notification_channels = local.channel_ids

  user_labels = {
    area = "serverless"
    tier = lower(each.value.severity)
  }

  conditions {
    display_name = each.value.title

    condition_threshold {
      filter          = each.value.filter
      comparison      = each.value.comparison
      threshold_value = each.value.threshold
      duration        = "${each.value.duration}s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "${each.value.period}s"
        per_series_aligner   = each.value.aligner
        cross_series_reducer = each.value.reducer == "" ? null : each.value.reducer
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = each.value.doc
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "log" {
  for_each = local.log_alerts

  project               = var.project_id
  display_name          = "[${each.value.severity}] ${var.name} | ${each.value.title}"
  combiner              = "OR"
  severity              = each.value.severity
  notification_channels = local.channel_ids

  user_labels = {
    area = "serverless"
    tier = lower(each.value.severity)
  }

  conditions {
    display_name = each.value.title

    condition_matched_log {
      filter = each.value.filter
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }

    auto_close = "1800s"
  }

  documentation {
    content   = each.value.doc
    mime_type = "text/markdown"
  }
}
