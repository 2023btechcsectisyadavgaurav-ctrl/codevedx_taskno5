variable "project_id" {
  description = "Project that owns the messaging resources."
  type        = string
}

variable "name" {
  description = "Name prefix."
  type        = string
}

variable "region" {
  description = "Region of the scheduler job."
  type        = string
}

variable "report_schedule" {
  description = "Cron schedule of the report job."
  type        = string
}

variable "report_timezone" {
  description = "Time zone of the report schedule."
  type        = string
}

variable "labels" {
  description = "Labels applied to topics and subscriptions."
  type        = map(string)
  default     = {}
}
