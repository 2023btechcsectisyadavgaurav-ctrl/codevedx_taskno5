output "api_url" {
  description = "HTTPS URL of the API function."
  value       = google_cloudfunctions2_function.this["api"].service_config[0].uri
}

output "service_names" {
  description = "Cloud Run service name of each function."
  value       = { for k, f in google_cloudfunctions2_function.this : k => f.name }
}

output "runtime_service_account" {
  description = "Identity the functions run as."
  value       = google_service_account.runtime.email
}

output "runtime_roles" {
  description = "Project roles of the runtime identity."
  value       = sort(local.runtime_roles)
}

output "build_roles" {
  description = "Project roles of the build identity."
  value       = sort(local.build_roles)
}

output "config" {
  description = "Serverless configuration of each function (scaling, memory, timeout, runtime, trigger)."
  value = {
    for k, v in local.functions : k => {
      runtime       = google_cloudfunctions2_function.this[k].build_config[0].runtime
      entry_point   = v.entry_point
      memory        = google_cloudfunctions2_function.this[k].service_config[0].available_memory
      timeout       = google_cloudfunctions2_function.this[k].service_config[0].timeout_seconds
      min_instances = google_cloudfunctions2_function.this[k].service_config[0].min_instance_count
      max_instances = google_cloudfunctions2_function.this[k].service_config[0].max_instance_count
      event_driven  = v.event_driven
      retries       = v.event_driven
    }
  }
}

output "source_bucket_public_access" {
  description = "Public access prevention on the source bucket."
  value       = google_storage_bucket.source.public_access_prevention
}

output "public_api" {
  description = "Whether the API URL accepts unauthenticated calls."
  value       = length(google_cloud_run_service_iam_member.public_api) > 0
}
