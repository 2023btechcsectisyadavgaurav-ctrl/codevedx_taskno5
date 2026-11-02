# One dashboard for the three questions that matter in a serverless system:
# is it healthy, is it scaling the way I expect, and what is it costing?

locals {
  guide_title = "How to read this dashboard"
  guide_text  = <<-EOT
    **Health** (rows 1-2): request rate, server errors and latency of the API. p95 latency should stay under ${var.latency_threshold_ms} ms and errors should be flat at zero.

    **Scaling and cost** (rows 3-4): *Active instances* returns to **0** when idle, which is what makes serverless cheap. *Billable instance time* is what you pay for. Memory and CPU close to 100% mean a function is under-sized; near 0% means over-sized.

    **Business flow** (row 5): orders received, processed and dead-lettered per minute. Received and processed should track each other; any dead-lettered order raises an alert.

    **Queue** (row 6): messages waiting to be processed. It should be near zero and never grow for long.
  EOT

  widgets = [
    {
      title   = "API requests per minute"
      filter  = "metric.type=\"run.googleapis.com/request_count\" AND ${local.api_scope}"
      aligner = "ALIGN_SUM"
      period  = "60s"
    },
    {
      title   = "API server errors (5xx) per minute"
      filter  = "metric.type=\"run.googleapis.com/request_count\" AND ${local.api_scope} AND metric.labels.response_code_class=\"5xx\""
      aligner = "ALIGN_SUM"
      period  = "60s"
    },
    {
      title   = "API latency p50 (ms)"
      filter  = "metric.type=\"run.googleapis.com/request_latencies\" AND ${local.api_scope}"
      aligner = "ALIGN_PERCENTILE_50"
      period  = "60s"
    },
    {
      title   = "API latency p95 (ms)"
      filter  = "metric.type=\"run.googleapis.com/request_latencies\" AND ${local.api_scope}"
      aligner = "ALIGN_PERCENTILE_95"
      period  = "60s"
    },
    {
      title   = "Active instances (0 = scaled to zero)"
      filter  = "metric.type=\"run.googleapis.com/container/instance_count\" AND ${local.all_fn_scope} AND metric.labels.state=\"active\""
      aligner = "ALIGN_MAX"
      period  = "60s"
    },
    {
      title   = "Billable instance time (cost driver)"
      filter  = "metric.type=\"run.googleapis.com/container/billable_instance_time\" AND ${local.all_fn_scope}"
      aligner = "ALIGN_RATE"
      period  = "60s"
    },
    {
      title   = "Memory utilization p95 (1.0 = limit)"
      filter  = "metric.type=\"run.googleapis.com/container/memory/utilizations\" AND ${local.all_fn_scope}"
      aligner = "ALIGN_PERCENTILE_95"
      period  = "60s"
    },
    {
      title   = "CPU utilization p95 (1.0 = limit)"
      filter  = "metric.type=\"run.googleapis.com/container/cpu/utilizations\" AND ${local.all_fn_scope}"
      aligner = "ALIGN_PERCENTILE_95"
      period  = "60s"
    },
    {
      title   = "Orders received per minute"
      filter  = "metric.type=\"logging.googleapis.com/user/${local.received_name}\" AND ${local.log_scope}"
      aligner = "ALIGN_SUM"
      period  = "60s"
    },
    {
      title   = "Orders processed per minute"
      filter  = "metric.type=\"logging.googleapis.com/user/${local.processed_name}\" AND ${local.log_scope}"
      aligner = "ALIGN_SUM"
      period  = "60s"
    },
    {
      title   = "Orders dead-lettered per minute"
      filter  = "metric.type=\"logging.googleapis.com/user/${local.dead_name}\" AND ${local.log_scope}"
      aligner = "ALIGN_SUM"
      period  = "60s"
    },
    {
      title   = "Messages waiting to be processed"
      filter  = "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND ${local.pubsub_scope}"
      aligner = "ALIGN_MAX"
      period  = "60s"
    },
  ]

  chart_tiles = [
    for i, w in local.widgets : {
      xPos   = (i % 2) * 6
      yPos   = 3 + floor(i / 2) * 4
      width  = 6
      height = 4
      widget = {
        title = w.title
        xyChart = {
          dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = {
              timeSeriesFilter = {
                filter = w.filter
                aggregation = {
                  alignmentPeriod  = w.period
                  perSeriesAligner = w.aligner
                }
              }
            }
          }]
          yAxis = { scale = "LINEAR" }
        }
      }
    }
  ]

  guide_tile = {
    xPos   = 0
    yPos   = 0
    width  = 12
    height = 3
    widget = {
      title = local.guide_title
      text = {
        content = local.guide_text
        format  = "MARKDOWN"
      }
    }
  }
}

resource "google_monitoring_dashboard" "main" {
  project = var.project_id

  dashboard_json = jsonencode({
    displayName = "${var.name} | Serverless application"
    mosaicLayout = {
      columns = 12
      tiles   = concat([local.guide_tile], local.chart_tiles)
    }
  })
}
