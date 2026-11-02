# Messaging backbone of the event-driven design.
#   orders topic          the API publishes one message per order; the processor function is triggered by it
#   dead-letter topic     orders that failed every attempt are parked here (and kept for inspection)
#   report-trigger topic  Cloud Scheduler publishes here on a schedule; the report function is triggered by it

resource "google_pubsub_topic" "orders" {
  project = var.project_id
  name    = "${var.name}-orders"
  labels  = var.labels
}

resource "google_pubsub_topic" "dead_letter" {
  project = var.project_id
  name    = "${var.name}-orders-dead-letter"
  labels  = var.labels
}

# A pull subscription keeps dead-lettered messages for a week so nothing is lost while someone investigates.
resource "google_pubsub_subscription" "dead_letter" {
  project              = var.project_id
  name                 = "${var.name}-orders-dead-letter-pull"
  topic                = google_pubsub_topic.dead_letter.id
  ack_deadline_seconds = 60
  labels               = var.labels

  message_retention_duration = "604800s"
  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic" "report" {
  project = var.project_id
  name    = "${var.name}-report-trigger"
  labels  = var.labels
}

resource "google_cloud_scheduler_job" "report" {
  project     = var.project_id
  region      = var.region
  name        = "${var.name}-daily-report"
  description = "Triggers the report function (${var.report_schedule})"
  schedule    = var.report_schedule
  time_zone   = var.report_timezone

  pubsub_target {
    topic_name = google_pubsub_topic.report.id
    data       = base64encode("run-report")
  }
}
