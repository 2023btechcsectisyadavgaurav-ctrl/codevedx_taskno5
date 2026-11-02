variable "project_id" {
  description = "Project that owns the functions."
  type        = string
}

variable "name" {
  description = "Name prefix."
  type        = string
}

variable "region" {
  description = "Region of the functions."
  type        = string
}

variable "source_dir" {
  description = "Folder holding main.py and requirements.txt."
  type        = string
}

variable "labels" {
  description = "Labels applied to the functions and the source bucket."
  type        = map(string)
  default     = {}
}

variable "firestore_database" {
  description = "Firestore database ID the functions use."
  type        = string
}

variable "orders_topic_id" {
  description = "Full ID of the orders topic (trigger of the processor)."
  type        = string
}

variable "orders_topic_name" {
  description = "Short name of the orders topic."
  type        = string
}

variable "dead_letter_topic_name" {
  description = "Short name of the dead-letter topic."
  type        = string
}

variable "report_topic_id" {
  description = "Full ID of the report trigger topic."
  type        = string
}

variable "min_instances" {
  description = "Minimum instances per function (0 = scale to zero)."
  type        = number
}

variable "max_instances" {
  description = "Maximum instances per function."
  type        = number
}

variable "memory_mb" {
  description = "Memory per instance in MB."
  type        = number
}

variable "api_timeout_seconds" {
  description = "API request timeout."
  type        = number
}

variable "worker_timeout_seconds" {
  description = "Worker timeout."
  type        = number
}

variable "max_delivery_attempts" {
  description = "Attempts before an order is dead-lettered."
  type        = number
}

variable "allow_unauthenticated" {
  description = "Allow unauthenticated HTTP access to the API URL."
  type        = bool
}

variable "require_api_key" {
  description = "Require the X-API-Key header on data routes."
  type        = bool
}

variable "api_key" {
  description = "The API key value."
  type        = string
  sensitive   = true
}
