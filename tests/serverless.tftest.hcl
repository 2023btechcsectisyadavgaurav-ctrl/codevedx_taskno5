# Offline tests: the providers are mocked, so no GCP account or credentials are needed.
# Run with:  terraform init -backend=false && terraform test
# (The application code has its own unit tests: python -I -m unittest discover -s tests/python)

mock_provider "google" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "archive" {}

variables {
  project_id = "test-project"
}

# --- Event-driven architecture ---------------------------------------------------------------------
run "three_functions_one_http_two_event_driven" {
  command = plan

  assert {
    condition     = sort(keys(output.serverless_summary.functions)) == tolist(["api", "processor", "report"])
    error_message = "Expected three functions: api, processor and report."
  }

  assert {
    condition     = !output.serverless_summary.functions["api"].event_driven && output.serverless_summary.functions["processor"].event_driven && output.serverless_summary.functions["report"].event_driven
    error_message = "The API is HTTP-triggered; the processor and report are triggered by Pub/Sub events."
  }

  assert {
    condition     = alltrue([for f in values(output.serverless_summary.functions) : f.runtime == "python312"])
    error_message = "All functions should use the python312 runtime."
  }

  assert {
    condition     = output.serverless_summary.functions["api"].entry_point == "api" && output.serverless_summary.functions["processor"].entry_point == "process_order" && output.serverless_summary.functions["report"].entry_point == "daily_report"
    error_message = "Entry points must match the functions in app/main.py."
  }

  assert {
    condition     = output.serverless_summary.report_schedule == "0 6 * * *"
    error_message = "The report should run on a daily schedule by default."
  }

  assert {
    condition     = output.serverless_summary.database_type == "FIRESTORE_NATIVE"
    error_message = "Orders are stored in Firestore (native mode)."
  }
}

# --- Cost-optimized -----------------------------------------------------------------------------------
run "scales_to_zero_with_a_hard_cap_by_default" {
  command = plan

  assert {
    condition     = alltrue([for f in values(output.serverless_summary.functions) : f.min_instances == 0])
    error_message = "Functions must scale to zero by default (no idle cost)."
  }

  assert {
    condition     = alltrue([for f in values(output.serverless_summary.functions) : f.max_instances == 10])
    error_message = "A maximum instance cap must protect against runaway cost."
  }
}

run "memory_is_right_sized_small" {
  command = plan

  assert {
    condition     = alltrue([for f in values(output.serverless_summary.functions) : f.memory == "256M"])
    error_message = "Functions should default to 256 MB."
  }
}

run "cost_and_scale_can_be_tuned" {
  command = plan

  variables {
    min_instances = 1
    max_instances = 3
    memory_mb     = 512
  }

  assert {
    condition     = alltrue([for f in values(output.serverless_summary.functions) : f.min_instances == 1 && f.max_instances == 3 && f.memory == "512M"])
    error_message = "min_instances, max_instances and memory_mb should flow through to every function."
  }
}

# --- Reliable ---------------------------------------------------------------------------------------
run "event_functions_are_retried" {
  command = plan

  assert {
    condition     = output.serverless_summary.functions["processor"].retries && output.serverless_summary.functions["report"].retries
    error_message = "Event-driven functions must be retried on failure."
  }

  assert {
    condition     = output.serverless_summary.functions["processor"].timeout >= output.serverless_summary.functions["api"].timeout
    error_message = "The worker should be allowed at least as long as an API request."
  }
}

run "monitoring_covers_health_scaling_and_the_queue" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["api_errors", "api_latency", "backlog_age", "memory_pressure", "dead_lettered", "publish_failed", "function_errors"] :
      contains(output.serverless_summary.alert_keys, k)
    ])
    error_message = "An alert policy is missing."
  }

  assert {
    condition     = output.serverless_summary.alert_severities == tolist(["CRITICAL", "ERROR", "WARNING"])
    error_message = "Alerts should use CRITICAL, ERROR and WARNING tiers."
  }

  assert {
    condition     = length(output.serverless_summary.log_metrics) == 3
    error_message = "Three business metrics (received, processed, dead-lettered) should be derived from the logs."
  }

  assert {
    condition = alltrue([
      for t in ["Active instances (0 = scaled to zero)", "Billable instance time (cost driver)", "Messages waiting to be processed", "Orders dead-lettered per minute"] :
      contains(output.serverless_summary.dashboard_widgets, t)
    ])
    error_message = "The dashboard is missing a scaling, cost, queue or dead-letter chart."
  }

  assert {
    condition     = length(output.serverless_summary.dashboard_widgets) >= 13
    error_message = "The dashboard should have a guide panel and at least twelve charts."
  }
}

# Google rejects any alert or chart filter that does not name a resource type (this broke a real deployment once).
run "every_filter_names_a_resource_type" {
  command = plan

  assert {
    condition     = alltrue([for f in output.serverless_summary.all_filters : strcontains(f, "resource.type=")])
    error_message = "Every alert and dashboard filter must contain a resource.type restriction."
  }

  assert {
    condition     = length(output.serverless_summary.all_filters) >= 19
    error_message = "Expected the filters of all 7 alerts and all 12 dashboard charts."
  }
}

# Google rejects starts_with() in log-alert filters ("Right-hand side functions are currently not supported").
run "log_alert_filters_use_no_functions" {
  command = plan

  assert {
    condition     = alltrue([for f in output.serverless_summary.log_alert_filters : !strcontains(f, "starts_with(")])
    error_message = "Log-alert filters must not use starts_with(); list the service names explicitly."
  }

  assert {
    condition     = length(output.serverless_summary.log_alert_filters) == 3
    error_message = "Expected three log-based alerts."
  }
}

run "notification_channels_follow_the_email_list" {
  command = plan

  variables {
    alert_emails = ["ops@example.com", "oncall@example.com"]
  }

  assert {
    condition     = output.notification_channels == 2
    error_message = "One notification channel is expected per alert email."
  }
}

# --- Secure -------------------------------------------------------------------------------------------
run "least_privilege_identities" {
  command = plan

  assert {
    condition     = !anytrue([for r in concat(output.serverless_summary.runtime_roles, output.serverless_summary.build_roles) : contains(["roles/owner", "roles/editor", "roles/viewer"], r)])
    error_message = "No primitive role may be granted to the function identities."
  }

  assert {
    condition     = tolist(output.serverless_summary.runtime_roles) == tolist(["roles/datastore.user", "roles/eventarc.eventReceiver", "roles/logging.logWriter", "roles/monitoring.metricWriter"])
    error_message = "The runtime identity should only be able to use Firestore, receive events and write logs and metrics."
  }

  assert {
    condition     = output.serverless_summary.source_bucket_public == "enforced"
    error_message = "The source-code bucket must be private."
  }
}

run "api_is_public_by_default_but_can_be_closed" {
  command = plan

  assert {
    condition     = output.serverless_summary.public_api
    error_message = "The API URL is reachable by default (the API key protects the data)."
  }
}

run "api_can_require_google_identity" {
  command = plan

  variables {
    allow_unauthenticated = false
  }

  assert {
    condition     = !output.serverless_summary.public_api
    error_message = "With allow_unauthenticated = false no public invoker binding should exist."
  }
}

# --- Input validation ---------------------------------------------------------------------------------
run "rejects_max_below_min" {
  command = plan

  variables {
    min_instances = 3
    max_instances = 2
  }

  expect_failures = [var.max_instances]
}

run "rejects_too_many_warm_instances" {
  command = plan

  variables {
    min_instances = 6
  }

  expect_failures = [var.min_instances]
}

run "rejects_unsupported_memory" {
  command = plan

  variables {
    memory_mb = 300
  }

  expect_failures = [var.memory_mb]
}

run "rejects_invalid_cron" {
  command = plan

  variables {
    report_schedule = "daily"
  }

  expect_failures = [var.report_schedule]
}

run "rejects_zero_delivery_attempts" {
  command = plan

  variables {
    max_delivery_attempts = 0
  }

  expect_failures = [var.max_delivery_attempts]
}

run "rejects_invalid_email" {
  command = plan

  variables {
    alert_emails = ["not-an-email"]
  }

  expect_failures = [var.alert_emails]
}

run "rejects_bad_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}
