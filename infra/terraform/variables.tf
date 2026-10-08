variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "uksouth"
}

variable "project" {
  description = "Short project name used in resource names (lowercase letters/digits)."
  type        = string
  default     = "tradefin"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "sql_admin_login" {
  description = "Azure SQL administrator login."
  type        = string
  default     = "sqladmin"
}

variable "sql_database_sku" {
  description = "Azure SQL DB SKU. GP_S_Gen5_1 is serverless (auto-pause) and cheap for dev."
  type        = string
  default     = "GP_S_Gen5_1"
}

variable "client_ip_addresses" {
  description = "Public IPs allowed through the SQL firewall (your machine, for running the generator)."
  type        = list(string)
  default     = []
}

variable "databricks_sku" {
  description = "Databricks workspace SKU. Unity Catalog needs premium."
  type        = string
  default     = "premium"
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
