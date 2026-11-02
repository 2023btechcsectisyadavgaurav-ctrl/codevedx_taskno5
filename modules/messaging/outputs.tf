output "orders_topic_id" {
  description = "Full ID of the orders topic."
  value       = google_pubsub_topic.orders.id
}

output "orders_topic_name" {
  description = "Short name of the orders topic."
  value       = google_pubsub_topic.orders.name
}

output "dead_letter_topic_name" {
  description = "Short name of the dead-letter topic."
  value       = google_pubsub_topic.dead_letter.name
}

output "dead_letter_subscription" {
  description = "Pull subscription that holds dead-lettered messages."
  value       = google_pubsub_subscription.dead_letter.name
}

output "report_topic_id" {
  description = "Full ID of the report trigger topic."
  value       = google_pubsub_topic.report.id
}

output "report_job_name" {
  description = "Name of the Cloud Scheduler job."
  value       = google_cloud_scheduler_job.report.name
}

output "report_schedule" {
  description = "Cron schedule of the report job."
  value       = google_cloud_scheduler_job.report.schedule
}
