variable "project_id" {
  description = "Project that owns the monitoring resources."
  type        = string
}

variable "name" {
  description = "Name prefix (the functions' Cloud Run services all start with it)."
  type        = string
}

variable "api_service" {
  description = "Cloud Run service name of the API function."
  type        = string
}

variable "processor_service" {
  description = "Cloud Run service name of the order processor."
  type        = string
}

variable "report_service" {
  description = "Cloud Run service name of the report function."
  type        = string
}

variable "alert_emails" {
  description = "Email addresses that receive alert notifications."
  type        = list(string)
  default     = []
}

variable "error_threshold_count" {
  description = "API 5xx count in 5 minutes that raises an alert."
  type        = number
}

variable "latency_threshold_ms" {
  description = "p95 API latency alert threshold in milliseconds."
  type        = number
}

variable "backlog_age_seconds" {
  description = "Oldest-unprocessed-message age alert threshold in seconds."
  type        = number
}
