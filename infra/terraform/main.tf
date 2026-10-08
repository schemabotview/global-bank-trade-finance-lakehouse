data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# Only needed when this module provisions its own Azure SQL server.
resource "random_password" "sql_admin" {
  count            = local.create_sql ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_"
}

locals {
  base   = "${var.project}-${var.environment}"
  flat   = "${var.project}${var.environment}"
  suffix = random_string.suffix.result

  # Governed subscriptions commonly vend resources to app teams rather than granting
  # subscription-scope write. Every `*_name` variable below follows the same contract:
  # empty => this module creates the resource; set => it adopts the existing one.
  create_rg  = var.resource_group_name == ""
  create_sa  = var.storage_account_name == ""
  create_sql = var.sql_server_name == ""
  create_dbx = var.databricks_workspace_name == ""

  tags = merge({
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }, var.tags)
}

# ---------------------------------------------------------------- Resource group
resource "azurerm_resource_group" "this" {
  count    = local.create_rg ? 1 : 0
  name     = "rg-${local.base}"
  location = var.location
  tags     = local.tags
}

data "azurerm_resource_group" "existing" {
  count = local.create_rg ? 0 : 1
  name  = var.resource_group_name
}

locals {
  rg_name     = local.create_rg ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
  rg_location = local.create_rg ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.existing[0].location
}

# ---------------------------------------------------------------- ADLS Gen2
resource "azurerm_storage_account" "lake" {
  count                           = local.create_sa ? 1 : 0
  name                            = substr("st${local.flat}${local.suffix}", 0, 24)
  resource_group_name             = local.rg_name
  location                        = local.rg_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

data "azurerm_storage_account" "existing" {
  count               = local.create_sa ? 0 : 1
  name                = var.storage_account_name
  resource_group_name = local.rg_name
}

# landing = raw Parquet written by ADF; lakehouse = Unity Catalog managed storage.
# Only managed here when this module owns the account — an adopted account is expected
# to already carry both containers (and the Unity Catalog storage credential over them).
resource "azurerm_storage_data_lake_gen2_filesystem" "landing" {
  count              = local.create_sa ? 1 : 0
  name               = "landing"
  storage_account_id = azurerm_storage_account.lake[0].id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "lakehouse" {
  count              = local.create_sa ? 1 : 0
  name               = "lakehouse"
  storage_account_id = azurerm_storage_account.lake[0].id
}

locals {
  sa_name = local.create_sa ? azurerm_storage_account.lake[0].name : data.azurerm_storage_account.existing[0].name
  sa_id   = local.create_sa ? azurerm_storage_account.lake[0].id : data.azurerm_storage_account.existing[0].id
}

# ---------------------------------------------------------------- Key Vault
resource "azurerm_key_vault" "this" {
  name                       = substr("kv-${local.base}-${local.suffix}", 0, 24)
  resource_group_name        = local.rg_name
  location                   = local.rg_location
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

# ---------------------------------------------------------------- Azure SQL (synthetic source)
resource "azurerm_mssql_server" "this" {
  count                        = local.create_sql ? 1 : 0
  name                         = "sql-${local.base}-${local.suffix}"
  resource_group_name          = local.rg_name
  location                     = local.rg_location
  version                      = "12.0"
  administrator_login          = var.sql_admin_login
  administrator_login_password = random_password.sql_admin[0].result
  minimum_tls_version          = "1.2"
  tags                         = local.tags
}

data "azurerm_mssql_server" "existing" {
  count               = local.create_sql ? 0 : 1
  name                = var.sql_server_name
  resource_group_name = local.rg_name
}

resource "azurerm_mssql_database" "source" {
  count                       = local.create_sql ? 1 : 0
  name                        = var.sql_database_name
  server_id                   = azurerm_mssql_server.this[0].id
  sku_name                    = var.sql_database_sku
  max_size_gb                 = 5
  min_capacity                = startswith(var.sql_database_sku, "GP_S") ? 0.5 : null
  auto_pause_delay_in_minutes = startswith(var.sql_database_sku, "GP_S") ? 60 : null
  zone_redundant              = false
  tags                        = local.tags
}

# Firewall is only managed on a server this module owns — an adopted (often shared)
# server's rules belong to whoever owns it.
resource "azurerm_mssql_firewall_rule" "azure_services" {
  count            = local.create_sql ? 1 : 0
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.this[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_firewall_rule" "clients" {
  count            = local.create_sql ? length(var.client_ip_addresses) : 0
  name             = "client-${count.index}"
  server_id        = azurerm_mssql_server.this[0].id
  start_ip_address = var.client_ip_addresses[count.index]
  end_ip_address   = var.client_ip_addresses[count.index]
}

locals {
  sql_fqdn     = local.create_sql ? azurerm_mssql_server.this[0].fully_qualified_domain_name : data.azurerm_mssql_server.existing[0].fully_qualified_domain_name
  sql_db       = local.create_sql ? azurerm_mssql_database.source[0].name : var.sql_database_name
  sql_password = local.create_sql ? random_password.sql_admin[0].result : var.sql_admin_password

  sql_connection_string = "Server=tcp:${local.sql_fqdn},1433;Database=${local.sql_db};User ID=${var.sql_admin_login};Password=${local.sql_password};Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;"
  sql_jdbc_url          = "jdbc:sqlserver://${local.sql_fqdn}:1433;database=${local.sql_db};encrypt=true;trustServerCertificate=false"
}

# ---------------------------------------------------------------- Key Vault secrets
resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password"
  value        = local.sql_password
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "sql_connection_string" {
  name         = "sql-connection-string"
  value        = local.sql_connection_string
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "sql_admin_login" {
  name         = "sql-admin-login"
  value        = var.sql_admin_login
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "sql_jdbc_url" {
  name         = "sql-jdbc-url"
  value        = local.sql_jdbc_url
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_deployer]
}

# ---------------------------------------------------------------- Data Factory
resource "azurerm_data_factory" "this" {
  name                = "adf-${local.base}-${local.suffix}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "adf_storage" {
  scope                = local.sa_id
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
  count               = local.create_dbx ? 1 : 0
  name                = "dbw-${local.base}-${local.suffix}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  sku                 = var.databricks_sku
  tags                = local.tags
}

data "azurerm_databricks_workspace" "existing" {
  count               = local.create_dbx ? 0 : 1
  name                = var.databricks_workspace_name
  resource_group_name = local.rg_name
}

# Identity Unity Catalog uses (as a storage credential) to reach ADLS. Only created
# alongside a workspace this module owns; an adopted workspace brings its own.
resource "azurerm_databricks_access_connector" "uc" {
  count               = local.create_dbx ? 1 : 0
  name                = "dbac-${local.base}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "uc_storage" {
  count                = local.create_dbx ? 1 : 0
  scope                = local.sa_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.uc[0].identity[0].principal_id
}
