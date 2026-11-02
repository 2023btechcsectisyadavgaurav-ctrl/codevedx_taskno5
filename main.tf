provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  name = "${var.name_prefix}-${var.environment}"

  labels = merge(
    {
      project     = "serverless-application"
      environment = var.environment
      managed-by  = "terraform"
    },
    var.extra_labels,
  )

  firestore_location = var.firestore_location != "" ? var.firestore_location : var.region

  required_apis = [
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "eventarc.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Newly enabled APIs (and the service accounts behind them) need a moment before they can be used.
resource "time_sleep" "apis_ready" {
  create_duration = "60s"

  depends_on = [google_project_service.apis]
}

resource "random_id" "suffix" {
  byte_length = 2
}

# Shared secret for the data routes of the API.
resource "random_password" "api_key" {
  length  = 32
  special = false
}

# ---------------------------------------------------------------------------
# Messaging: topics, dead-letter queue, scheduled trigger
# ---------------------------------------------------------------------------
module "messaging" {
  source = "./modules/messaging"

  project_id      = var.project_id
  name            = local.name
  region          = var.region
  report_schedule = var.report_schedule
  report_timezone = var.report_time_zone
  labels          = local.labels

  depends_on = [time_sleep.apis_ready]
}

# ---------------------------------------------------------------------------
# Data: serverless Firestore database
# ---------------------------------------------------------------------------
module "data" {
  source = "./modules/data"

  project_id = var.project_id
  name       = "${local.name}-${random_id.suffix.hex}"
  location   = local.firestore_location

  depends_on = [time_sleep.apis_ready]
}

# ---------------------------------------------------------------------------
# Compute: three Cloud Run functions from one source folder
# ---------------------------------------------------------------------------
module "functions" {
  source = "./modules/functions"

  project_id             = var.project_id
  name                   = local.name
  region                 = var.region
  source_dir             = "${path.root}/app"
  labels                 = local.labels
  firestore_database     = module.data.database_name
  orders_topic_id        = module.messaging.orders_topic_id
  orders_topic_name      = module.messaging.orders_topic_name
  dead_letter_topic_name = module.messaging.dead_letter_topic_name
  report_topic_id        = module.messaging.report_topic_id
  min_instances          = var.min_instances
  max_instances          = var.max_instances
  memory_mb              = var.memory_mb
  api_timeout_seconds    = var.api_timeout_seconds
  worker_timeout_seconds = var.worker_timeout_seconds
  max_delivery_attempts  = var.max_delivery_attempts
  allow_unauthenticated  = var.allow_unauthenticated
  require_api_key        = var.require_api_key
  api_key                = random_password.api_key.result

  depends_on = [time_sleep.apis_ready, module.messaging, module.data]
}

# ---------------------------------------------------------------------------
# Monitoring: log-based metrics, alert policies, dashboard
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  project_id            = var.project_id
  name                  = local.name
  api_service           = module.functions.service_names["api"]
  processor_service     = module.functions.service_names["processor"]
  report_service        = module.functions.service_names["report"]
  alert_emails          = var.alert_emails
  error_threshold_count = var.error_threshold_count
  latency_threshold_ms  = var.latency_threshold_ms
  backlog_age_seconds   = var.backlog_age_seconds

  depends_on = [time_sleep.apis_ready]
}
