output "database_name" {
  description = "Database ID."
  value       = google_firestore_database.orders.name
}

output "database_type" {
  description = "Database mode."
  value       = google_firestore_database.orders.type
}

output "database_location" {
  description = "Database location."
  value       = google_firestore_database.orders.location_id
}
