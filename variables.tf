variable "project_id" {
  description = "GCP project ID that will hold every resource."
  type        = string
}

variable "region" {
  description = "Region for the functions, Pub/Sub and the scheduler."
  type        = string
  default     = "us-central1"
}

variable "firestore_location" {
  description = "Firestore location (a region such as us-central1, or a multi-region such as nam5). Empty = same as region."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name, used in resource names and labels."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "name_prefix" {
  description = "Prefix for all resource names (3-12 chars: lowercase letters, digits, hyphens)."
  type        = string
  default     = "serverless"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,11}$", var.name_prefix))
    error_message = "name_prefix must start with a letter, be 3-12 characters, and use only lowercase letters, digits and hyphens."
  }
}

# ---------------------------------------------------------------------------
# Efficiency, scaling and cost
# ---------------------------------------------------------------------------
variable "min_instances" {
  description = "Instances kept warm per function. 0 (default) means scale to zero: you pay nothing while idle, at the price of an occasional cold start. 1 removes cold starts but costs money all month."
  type        = number
  default     = 0

  validation {
    condition     = var.min_instances >= 0 && var.min_instances <= 5
    error_message = "min_instances must be between 0 and 5."
  }
}

variable "max_instances" {
  description = "Hard cap on instances per function. Protects you from a runaway bill during a traffic spike or an attack."
  type        = number
  default     = 10

  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 100
    error_message = "max_instances must be between 1 and 100."
  }

  validation {
    condition     = var.max_instances >= var.min_instances
    error_message = "max_instances must be greater than or equal to min_instances."
  }
}

variable "memory_mb" {
  description = "Memory per instance in MB. Right-size it: more memory costs more and also gives more CPU."
  type        = number
  default     = 256

  validation {
    condition     = contains([128, 256, 512, 1024, 2048], var.memory_mb)
    error_message = "memory_mb must be one of 128, 256, 512, 1024, 2048."
  }
}

variable "api_timeout_seconds" {
  description = "Maximum run time of one API request."
  type        = number
  default     = 30

  validation {
    condition     = var.api_timeout_seconds >= 1 && var.api_timeout_seconds <= 300
    error_message = "api_timeout_seconds must be between 1 and 300."
  }
}

variable "worker_timeout_seconds" {
  description = "Maximum run time of one order-processing or report run."
  type        = number
  default     = 120

  validation {
    condition     = var.worker_timeout_seconds >= 1 && var.worker_timeout_seconds <= 540
    error_message = "worker_timeout_seconds must be between 1 and 540."
  }
}

# ---------------------------------------------------------------------------
# Reliability
# ---------------------------------------------------------------------------
variable "max_delivery_attempts" {
  description = "How many times an order is tried before it is moved to the dead-letter topic."
  type        = number
  default     = 5

  validation {
    condition     = var.max_delivery_attempts >= 1 && var.max_delivery_attempts <= 10
    error_message = "max_delivery_attempts must be between 1 and 10."
  }
}

variable "report_schedule" {
  description = "Cron schedule (5 fields, unix-cron) of the report job."
  type        = string
  default     = "0 6 * * *"

  validation {
    condition     = can(regex("^(\\S+\\s+){4}\\S+$", var.report_schedule))
    error_message = "report_schedule must be a five-field cron expression such as \"0 6 * * *\"."
  }
}

variable "report_time_zone" {
  description = "Time zone of the report schedule."
  type        = string
  default     = "Etc/UTC"
}

# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------
variable "allow_unauthenticated" {
  description = "Let anyone on the internet reach the API URL (the API key still protects the data routes). Set false to require a Google identity token on every request."
  type        = bool
  default     = true
}

variable "require_api_key" {
  description = "Require the X-API-Key header on the data routes (/orders, /stats, /report). /health stays public."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------
variable "alert_emails" {
  description = "Email addresses that receive alert notifications. Leave empty to create the alerts without notifications."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every alert email must be a valid email address."
  }
}

variable "error_threshold_count" {
  description = "Number of API server errors (HTTP 5xx) in 5 minutes that raises an alert."
  type        = number
  default     = 5

  validation {
    condition     = var.error_threshold_count >= 1
    error_message = "error_threshold_count must be at least 1."
  }
}

variable "latency_threshold_ms" {
  description = "95th percentile API latency (milliseconds) that raises an alert."
  type        = number
  default     = 1500

  validation {
    condition     = var.latency_threshold_ms > 0
    error_message = "latency_threshold_ms must be greater than 0."
  }
}

variable "backlog_age_seconds" {
  description = "Age (seconds) of the oldest unprocessed order message that raises an alert."
  type        = number
  default     = 600

  validation {
    condition     = var.backlog_age_seconds >= 60
    error_message = "backlog_age_seconds must be at least 60."
  }
}

variable "extra_labels" {
  description = "Additional labels applied to every resource that supports labels."
  type        = map(string)
  default     = {}
}
