variable "project_id" {
  description = "Project that owns the database."
  type        = string
}

variable "name" {
  description = "Database ID (4-63 chars, lowercase letters, digits, hyphens)."
  type        = string
}

variable "location" {
  description = "Firestore location."
  type        = string
}
