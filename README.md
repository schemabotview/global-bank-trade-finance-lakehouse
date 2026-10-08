# Global Bank Trade-Finance Lakehouse (Azure MVP)

Synthetic LC data in Azure SQL → ADF → ADLS Gen2 → Databricks (Bronze → Silver → Gold) producing one star schema:
**daily outstanding LC exposure per counterparty**. Full design and scope: [IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md),
model and DQ rules: [docs/data-model.md](docs/data-model.md).

> Status: scaffold, not deployed. Terraform, ADF JSON and the deploy scripts have never been run (no Terraform/Azure access
> where this was written). The generator and the day-1 notebook chain were run on local Spark + Delta; that run caught a
> surrogate-key mismatch (fixed with the `sk()` helper) and the fixed version was **not** re-run, nor was day 2.

```
infra/terraform/      Azure resources (RG, ADLS Gen2, Key Vault, Azure SQL, ADF, Databricks, access connector)
sql/                  source DDL (tf.*) and ADF control tables (ctl.*)
generator/            synthetic data (day 1 initial load, day 2 changes + dirty rows)
adf/                  linked services, datasets, metadata-driven ingestion pipeline
databricks/notebooks/ _common, 00_setup … 60_dq_reconcile (.ipynb)
databricks/workflows/ job definition (task graph)
scripts/              deploy / load helpers
```

## Runbook

Prerequisites: `az` (logged in), `terraform` ≥ 1.6, `jq`, `sqlcmd`, Python 3.10+ with `pyodbc` + ODBC Driver 18, Databricks CLI.

1. **Infra** — `cd infra/terraform && cp terraform.tfvars.example terraform.tfvars` (set subscription and your public IP), then `terraform init && terraform apply`.
2. **Source data (day 1)** — `export SQL_PASSWORD=$(az keyvault secret show --vault-name <kv> -n sql-admin-password --query value -o tsv)` then `scripts/load_source.sh 1`.
   Dry run without a database: `python generator/generate_data.py --day 1 --target csv`.
3. **ADF** — `az extension add --name datafactory`, then `scripts/deploy_adf.sh`, then run `pl_ingest_sqldb_to_landing` in the ADF portal. Expect Parquet under `landing/sqldb/<TABLE>/ingest_date=…/batch_id=…/` and rows in `ctl.batch_audit`.
4. **Unity Catalog (one-off, metastore admin)** — in the Databricks workspace, create a *storage credential* from the Terraform output `databricks_access_connector_id`, and an *external location* covering the `landing` and `lakehouse` containers.
5. **Secret scope (optional, enables source reconciliation)** — create a Key Vault-backed scope named `tradefin` on the vault from Terraform (needs `sql-jdbc-url`, `sql-admin-login`, `sql-admin-password`, already created by Terraform). Without it the check reports SKIPPED.
6. **Databricks** — `scripts/deploy_databricks.sh`, then run job `tradefin-exposure-pipeline` with `as_of_date=2025-06-30`.
7. **Day 2** — `scripts/load_source.sh 2`, re-run the ADF pipeline (only changed rows move), run the job with `as_of_date=2025-07-01`.
   Expect: rating history in `silver.party_history`, a second snapshot in the fact, replayed events in `silver.quarantine`, DQ gate green.
8. **Query the outcome** — `SELECT * FROM tradefin.gold.v_counterparty_exposure_daily ORDER BY as_of_date, outstanding_exposure_usd DESC;`

## Notes

- Re-running a notebook or the job for the same date is safe: Bronze skips loaded batches, Silver MERGEs, Gold replaces only its `as_of_date`.
- `terraform.tfvars`, state files and generator output are git-ignored. Secrets live only in Key Vault.
- Not in the MVP: streaming, CDC, remaining facts, dbt, Purview, Airflow, Power BI, CI/CD (see the plan, section 6).
