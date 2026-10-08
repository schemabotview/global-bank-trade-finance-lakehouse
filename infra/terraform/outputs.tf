output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "storage_account" {
  value = azurerm_storage_account.lake.name
}

output "landing_root" {
  value = "abfss://landing@${azurerm_storage_account.lake.name}.dfs.core.windows.net"
}

output "lakehouse_root" {
  value = "abfss://lakehouse@${azurerm_storage_account.lake.name}.dfs.core.windows.net"
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
  value = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "sql_database" {
  value = azurerm_mssql_database.source.name
}

output "data_factory" {
  value = azurerm_data_factory.this.name
}

output "databricks_workspace_url" {
  value = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "databricks_access_connector_id" {
  description = "Use as the Azure Managed Identity access connector ID when creating the Unity Catalog storage credential."
  value       = azurerm_databricks_access_connector.uc.id
}
