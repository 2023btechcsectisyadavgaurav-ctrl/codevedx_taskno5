# Three Cloud Run functions (2nd generation) built from one source folder:
#   api            HTTP trigger      public REST API
#   processor      Pub/Sub trigger   event-driven worker, one invocation per order message
#   report         Pub/Sub trigger   scheduled report (Cloud Scheduler -> Pub/Sub -> function)

locals {
  functions = {
    # `event_driven` is a static flag on purpose: whether a function has a trigger must be known at plan time,
    # while the topic ID itself only exists after the topic is created.
    api = {
      entry_point  = "api"
      description  = "Public REST API: create and read orders"
      timeout      = var.api_timeout_seconds
      event_driven = false
      topic        = ""
    }
    processor = {
      entry_point  = "process_order"
      description  = "Event-driven worker: processes one order per Pub/Sub message"
      timeout      = var.worker_timeout_seconds
      event_driven = true
      topic        = var.orders_topic_id
    }
    report = {
      entry_point  = "daily_report"
      description  = "Scheduled report: counts orders by status"
      timeout      = var.worker_timeout_seconds
      event_driven = true
      topic        = var.report_topic_id
    }
  }

  common_env = {
    GCP_PROJECT        = var.project_id
    FIRESTORE_DATABASE = var.firestore_database
    ORDERS_TOPIC       = var.orders_topic_name
    DEAD_LETTER_TOPIC  = var.dead_letter_topic_name
    MAX_ATTEMPTS       = tostring(var.max_delivery_attempts)
  }

  runtime_roles = [
    "roles/datastore.user",
    "roles/eventarc.eventReceiver",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]

  build_roles = [
    "roles/artifactregistry.writer",
    "roles/cloudbuild.builds.builder",
    "roles/logging.logWriter",
  ]
}

# ---------------------------------------------------------------------------
# Identities: one for running the code, one for building it (least privilege each)
# ---------------------------------------------------------------------------
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "${var.name}-fn"
  display_name = "Runtime identity of the ${var.name} functions"
}

resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = "${var.name}-build"
  display_name = "Build identity of the ${var.name} functions"
}

resource "google_project_iam_member" "runtime" {
  for_each = toset(local.runtime_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "build" {
  for_each = toset(local.build_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.build.email}"
}

# The runtime identity may publish to exactly two topics, nothing else in Pub/Sub.
resource "google_pubsub_topic_iam_member" "publish_orders" {
  project = var.project_id
  topic   = var.orders_topic_name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_pubsub_topic_iam_member" "publish_dead_letter" {
  project = var.project_id
  topic   = var.dead_letter_topic_name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# ---------------------------------------------------------------------------
# Source code: zip the app folder and store it in a private bucket
# ---------------------------------------------------------------------------
data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/app-source.zip"
  excludes    = ["__pycache__"]
}

resource "google_storage_bucket" "source" {
  project       = var.project_id
  name          = "${var.name}-src-${var.project_id}"
  location      = var.region
  force_destroy = true
  labels        = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Old builds are never needed again: keep storage cost at zero.
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_object" "source" {
  bucket = google_storage_bucket.source.name
  name   = "source/${data.archive_file.source.output_md5}.zip"
  source = data.archive_file.source.output_path
}

resource "google_storage_bucket_iam_member" "build_reads_source" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.build.email}"
}

# IAM changes take a moment to propagate; deploy only after they have.
resource "time_sleep" "iam_ready" {
  create_duration = "45s"

  depends_on = [
    google_project_iam_member.runtime,
    google_project_iam_member.build,
    google_pubsub_topic_iam_member.publish_orders,
    google_pubsub_topic_iam_member.publish_dead_letter,
    google_storage_bucket_iam_member.build_reads_source,
  ]
}

# ---------------------------------------------------------------------------
# The functions
# ---------------------------------------------------------------------------

# Google keeps ONE shared staging bucket per project and region (gcf-v2-sources-<number>-<region>) and creates it
# during the first deployment. Deploying all functions at the same moment makes them race to create it and one
# fails with "409 Could not create bucket". Starting them 30 seconds apart lets the first one create it.
locals {
  deploy_delay = {
    api       = "1s"
    processor = "30s"
    report    = "60s"
  }
}

resource "time_sleep" "stagger" {
  for_each = local.deploy_delay

  create_duration = each.value

  depends_on = [time_sleep.iam_ready]
}

resource "google_cloudfunctions2_function" "this" {
  for_each = local.functions

  project     = var.project_id
  location    = var.region
  name        = "${var.name}-${each.key}"
  description = each.value.description
  # Referencing the stagger delay here makes each function wait for its own timer (see above).
  labels = merge(var.labels, { function = each.key, deploy-delay = time_sleep.stagger[each.key].create_duration })

  build_config {
    runtime         = "python312"
    entry_point     = each.value.entry_point
    service_account = google_service_account.build.id

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    available_memory      = "${var.memory_mb}M"
    timeout_seconds       = each.value.timeout
    min_instance_count    = var.min_instances
    max_instance_count    = var.max_instances
    service_account_email = google_service_account.runtime.email
    ingress_settings      = "ALLOW_ALL"

    all_traffic_on_latest_revision = true

    environment_variables = merge(
      local.common_env,
      { for k, v in { REQUIRE_API_KEY = tostring(var.require_api_key), API_KEY = var.api_key } : k => v if each.key == "api" },
    )
  }

  # Event-driven: a Pub/Sub trigger invokes the function once per message and retries on failure.
  dynamic "event_trigger" {
    for_each = each.value.event_driven ? [each.value.topic] : []

    content {
      trigger_region        = var.region
      event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
      pubsub_topic          = event_trigger.value
      retry_policy          = "RETRY_POLICY_RETRY"
      service_account_email = google_service_account.runtime.email
    }
  }

  depends_on = [time_sleep.iam_ready]
}

# Event delivery runs as the runtime identity, so it may invoke the two event-driven services (and only them).
resource "google_cloud_run_service_iam_member" "event_invoker" {
  for_each = { for k, v in local.functions : k => v if v.event_driven }

  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.this[each.key].service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.runtime.email}"
}

# Public HTTP access to the API URL. The data routes are still protected by the API key.
resource "google_cloud_run_service_iam_member" "public_api" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.this["api"].service_config[0].service
  role     = "roles/run.invoker"
  member   = "allUsers"
}
