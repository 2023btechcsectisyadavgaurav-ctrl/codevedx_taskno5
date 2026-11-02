# Serverless document database: no servers, scales automatically, free tier included.
# A named database (not "(default)") with a random suffix, because Firestore database IDs cannot be re-used
# for a while after deletion, which would break a quick destroy-and-redeploy.
resource "google_firestore_database" "orders" {
  project     = var.project_id
  name        = var.name
  location_id = var.location
  type        = "FIRESTORE_NATIVE"

  delete_protection_state = "DELETE_PROTECTION_DISABLED"
  deletion_policy         = "DELETE"
}
