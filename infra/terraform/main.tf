data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "random_password" "sql_admin" {
  length           = 24
  special          = true
  override_special = "!#%*-_"
}

locals {
  base   = "${var.project}-${var.environment}"
  flat   = "${var.project}${var.environment}"
  suffix = random_string.suffix.result

  tags = merge({
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }, var.tags)

  sql_connection_string = "Server=tcp:${azurerm_mssql_server.this.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.source.name};User ID=${var.sql_admin_login};Password=${random_password.sql_admin.result};Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.base}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------- ADLS Gen2
resource "azurerm_storage_account" "lake" {
  name                            = substr("st${local.flat}${local.suffix}", 0, 24)
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

# landing = raw Parquet written by ADF; lakehouse = Unity Catalog managed storage (bronze/silver/gold Delta)
resource "azurerm_storage_data_lake_gen2_filesystem" "landing" {
  name               = "landing"
  storage_account_id = azurerm_storage_account.lake.id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "lakehouse" {
  name               = "lakehouse"
  storage_account_id = azurerm_storage_account.lake.id
}

# ---------------------------------------------------------------- Key Vault
resource "azurerm_key_vault" "this" {
  name                       = substr("kv-${local.base}-${local.suffix}", 0, 24)
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

resource "azurerm_role_assignment" "kv_deployer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password"
  value        = random_password.sql_admin.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "sql_connection_string" {
  name         = "sql-connection-string"
  value        = local.sql_connection_string
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}

# ---------------------------------------------------------------- Azure SQL (synthetic source)
resource "azurerm_mssql_server" "this" {
  name                         = "sql-${local.base}-${local.suffix}"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = azurerm_resource_group.this.location
  version                      = "12.0"
  administrator_login          = var.sql_admin_login
  administrator_login_password = random_password.sql_admin.result
  minimum_tls_version          = "1.2"
  tags                         = local.tags
}

resource "azurerm_mssql_database" "source" {
  name                        = "tradefin_source"
  server_id                   = azurerm_mssql_server.this.id
  sku_name                    = var.sql_database_sku
  max_size_gb                 = 5
  min_capacity                = startswith(var.sql_database_sku, "GP_S") ? 0.5 : null
  auto_pause_delay_in_minutes = startswith(var.sql_database_sku, "GP_S") ? 60 : null
  zone_redundant              = false
  tags                        = local.tags
}

# Allows ADF / Azure services (0.0.0.0). Tighten with private endpoints for non-dev.
resource "azurerm_mssql_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_firewall_rule" "clients" {
  count            = length(var.client_ip_addresses)
  name             = "client-${count.index}"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = var.client_ip_addresses[count.index]
  end_ip_address   = var.client_ip_addresses[count.index]
}

# ---------------------------------------------------------------- Data Factory
resource "azurerm_data_factory" "this" {
  name                = "adf-${local.base}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "adf_storage" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "adf_keyvault" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
}

# ---------------------------------------------------------------- Databricks
resource "azurerm_databricks_workspace" "this" {
  name                = "dbw-${local.base}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.databricks_sku
  tags                = local.tags
}

# Identity that Unity Catalog uses (as a storage credential) to reach ADLS.
resource "azurerm_databricks_access_connector" "uc" {
  name                = "dbac-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "uc_storage" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.uc.identity[0].principal_id
}

# Secrets read by Databricks (via a Key Vault-backed secret scope) for source reconciliation.
resource "azurerm_key_vault_secret" "sql_admin_login" {
  name         = "sql-admin-login"
  value        = var.sql_admin_login
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "sql_jdbc_url" {
  name         = "sql-jdbc-url"
  value        = "jdbc:sqlserver://${azurerm_mssql_server.this.fully_qualified_domain_name}:1433;database=${azurerm_mssql_database.source.name};encrypt=true;trustServerCertificate=false"
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}
