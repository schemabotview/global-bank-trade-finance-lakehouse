variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into. Leave empty to create rg-<project>-<environment> (needs subscription-scope write)."
  type        = string
  default     = ""
}

variable "storage_account_name" {
  description = "Existing ADLS Gen2 account (HNS enabled) to use for landing + lakehouse. Leave empty to create one. An adopted account must already have both containers and a Unity Catalog storage credential over them."
  type        = string
  default     = ""
}

variable "sql_server_name" {
  description = "Existing Azure SQL server holding the synthetic source. Leave empty to create one; when set, sql_admin_password is required."
  type        = string
  default     = ""
}

variable "sql_database_name" {
  description = "Database on the SQL server that holds the tf.* / ctl.* schemas."
  type        = string
  default     = "tradefin_source"
}

variable "sql_admin_password" {
  description = "Administrator password for an ADOPTED SQL server. Ignored when this module creates the server (a random password is generated and stored in Key Vault instead)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "databricks_workspace_name" {
  description = "Existing Databricks workspace (premium, Unity Catalog enabled). Leave empty to create one, which provisions a managed resource group at subscription scope."
  type        = string
  default     = ""
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
