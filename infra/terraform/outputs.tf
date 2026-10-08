output "resource_group" {
  value = local.rg_name
}

output "storage_account" {
  value = local.sa_name
}

output "landing_root" {
  value = "abfss://landing@${local.sa_name}.dfs.core.windows.net"
}

output "lakehouse_root" {
  value = "abfss://lakehouse@${local.sa_name}.dfs.core.windows.net"
}

output "key_vault" {
  value = azurerm_key_vault.this.name
}

output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "sql_server_fqdn" {
  value = local.sql_fqdn
}

output "sql_database" {
  value = local.sql_db
}

output "data_factory" {
  value = azurerm_data_factory.this.name
}

output "databricks_workspace_url" {
  value = local.create_dbx ? "https://${azurerm_databricks_workspace.this[0].workspace_url}" : "https://${data.azurerm_databricks_workspace.existing[0].workspace_url}"
}

output "databricks_access_connector_id" {
  description = "Use as the Azure Managed Identity access connector ID when creating the Unity Catalog storage credential. Null when an existing workspace was adopted (it brings its own)."
  value       = local.create_dbx ? azurerm_databricks_access_connector.uc[0].id : null
}
