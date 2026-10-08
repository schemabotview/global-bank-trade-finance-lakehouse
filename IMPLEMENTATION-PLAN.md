# Global Bank Trade-Finance Lakehouse — Implementation Plan (MVP)

Source documents (in this repo):

- `Global-bank-trade-finance-lakehouse.pdf` ("Doc B") — proposed LC-based design for the current engagement. **Governing document.**
- `Case_Study_2_Global_bank_Azure.pdf` ("Doc A") — STAR/interview write-up of an earlier project. **Pattern reference only.**

---

## 1. Document review: conflicts and gaps

| # | Topic | Doc A | Doc B | Decision for this build |
|---|---|---|---|---|
| 1 | Gold location | Synapse star via dbt (also says "Gold Delta" read by DS — self-contradictory) | Gold = Delta in Databricks; Synapse/SQL only serves | Gold = Delta (Unity Catalog). No Synapse in MVP |
| 2 | Gold tooling | dbt | PySpark/SQL | Notebooks for MVP; dbt is a later phase |
| 3 | Streaming transport | Event Hubs (Kafka protocol) | "Kafka OR Event Hubs" unresolved | Out of MVP; Event Hubs when streaming is added |
| 4 | Stream sink | Separate real-time zone + Cosmos DB | Stream → Bronze Delta → same Silver/Gold | Out of MVP; follow B later |
| 5 | Orchestration | Airflow + ADF | "ADF / Airflow" ambiguous | ADF (ingest) + Databricks Workflow (transform) in MVP |
| 6 | Schema evolution | Azure Function + Purview | `schema_registry` control table | Control-table approach, post-MVP |
| 7 | Fabric | Used for reconciliation | Absent | Out of scope |
| 8 | Bronze retention | 90 days then archive | "preserve raw history" + 7-yr regulatory audit | Open: retention policy to be confirmed |
| 9 | Bronze audit columns | `ingested_at, source_system, pipeline_run_id` | `source_record_id, source_updated_at, operation, ingested_at, batch_id` | B's set, plus `batch_id` from run id |
| 10 | Fact model | `FACT_TRADES`, `FACT_CREDIT_EXPOSURE` | 7 conformed facts | One fact from B's galaxy (see §2) |
| 11 | SCD2 key timing | Key fixed at processing time | Version effective at event/snapshot time | Snapshot (as-of) time |
| 12 | Counterparty hierarchy | Input | No parent key on `PARTY` | Gap — post-MVP |
| 13 | RWA / PD / LGD / EAD | Computed on fact | Supplied by approved engines | Not computed in MVP |
| 14 | Sample data | Dated 2026 for a role ending Oct 2025; same counterparty with 75 % and 80 % risk weight | — | Doc A figures not used |

Technical corrections to carry forward: Event Hubs replication factor is not user-configurable; "KMS" → Key Vault CMK on Azure; Power BI does not use JDBC; Structured Streaming into Delta is effectively-once (idempotent), not exactly-once.

---

## 2. MVP scope — one outcome, one star

**Outcome:** *"What is each counterparty's outstanding LC exposure, per day, in USD, with the counterparty's risk rating as it stood on that day?"*

Credit-limit comparison (`FACILITY_USAGE` / `CREDIT_FACILITY`) is deliberately **phase 2** — it is a separate fact in Doc B's galaxy.

### Star schema (Gold, Delta)

| Table | Grain / notes |
|---|---|
| `fact_exposure_snapshot` | LC × exposure_type × as_of_date. `outstanding_exposure_local`, `outstanding_exposure_usd`, `lc_amount_current_local`. Snapshot measure — never sum across dates |
| `dim_counterparty` | SCD2 on `risk_rating`, `country`. Fact stores the version effective at `as_of_date` |
| `dim_lc` | LC number, status, issue/expiry date, payment terms |
| `dim_bank` | Issuing bank (BIC, name, country) |
| `dim_currency` | Currency + USD rate |
| `dim_date` | Calendar |

Surrogate keys are deterministic (`xxhash64` of business key [+ effective start]) so dimensions can be rebuilt without breaking fact FKs.

### Source (Azure SQL DB, synthetic) — 7 tables from Doc B's 24

| Table | Load pattern | Purpose |
|---|---|---|
| `BANK` | Full refresh | Issuing banks |
| `CURRENCY_FX` | Full refresh | Currency + USD rate |
| `PARTY` | Incremental (watermark `updated_at`) | Counterparties; ratings change (SCD2 test) |
| `LETTER_OF_CREDIT` | Incremental | LC header (MVP simplification: carries `issuing_bank_id`; B uses `LC_BANK_ROLE`) |
| `LC_PARTY_ROLE` | Incremental | Applicant / beneficiary |
| `LC_AMENDMENT` | Incremental | Amount / expiry changes |
| `LC_EXPOSURE_EVENT` | Append (watermark `event_id`) | Exposure movements |

Synthetic data is seeded and reproducible: day 1 = initial load, day 2 = changes (rating downgrades, new LCs, amendments, new exposure events, replayed events) plus deliberately dirty rows (bad currency, negative amount, null name, replayed `source_event_ref`).

---

## 3. Architecture

```
Azure SQL DB (synthetic)
   │  ADF: Lookup(ingestion_config) → ForEach → Copy (full / watermark / append)
   ▼
ADLS Gen2  container `landing`     Parquet: sqldb/<table>/ingest_date=…/batch_id=…/
   │  Databricks Workflow (notebooks)
   ▼
Bronze (Delta, UC)  →  Silver (Delta, UC)  →  Gold star (Delta, UC)
                          └─ quarantine           └─ DQ + reconciliation gate
```

- **Platform:** Terraform provisions resource group, ADLS Gen2, Key Vault, Azure SQL, Data Factory, Databricks workspace and access connector.
- **Secrets:** Key Vault only; ADF uses a managed identity; Databricks reads through a Key Vault-backed secret scope.
- **Unity Catalog:** catalog `tradefin`, schemas `bronze`, `silver`, `gold`; managed storage in container `lakehouse`.
- **Orchestration:** ADF pipeline for ingestion; Databricks Workflow for transformation. Failure at any task stops downstream and leaves previous Gold unchanged.

### Databricks notebooks (`.ipynb`)

| Notebook | Layer | Work |
|---|---|---|
| `_common` | — | Config, table metadata, DQ rule definitions, helpers |
| `00_setup` | Setup | Catalog, schemas, quarantine table |
| `10_bronze_load` | Bronze | Landing Parquet → Delta append, new batches only, audit columns |
| `20_silver_clean` | Silver | Typing, DQ rules → quarantine, dedup, Delta MERGE |
| `30_silver_scd2_party` | Silver | Rebuild party history (valid-from/to, is_current) from Bronze versions |
| `40_gold_dims` | Gold | Dimensions with deterministic surrogate keys |
| `50_gold_fact_exposure` | Gold | Daily snapshot; point-in-time join to `dim_counterparty`; idempotent per `as_of_date` |
| `60_dq_reconcile` | Gate | Uniqueness, nulls, RI, row-count and control-total reconciliation |

---

## 4. Repo layout

```
IMPLEMENTATION-PLAN.md
README.md                      # runbook
infra/terraform/               # all Azure infrastructure
sql/                           # source DDL + control tables + procs
generator/                     # synthetic data generator
adf/                           # linked services, datasets, pipeline (JSON)
databricks/notebooks/          # .ipynb notebooks
databricks/workflows/          # job definition
scripts/                       # deploy helpers
docs/                          # data model, DQ rules
```

---

## 5. Build order

| Step | Deliverable | Done when |
|---|---|---|
| 1 | Terraform apply (dev) | All resources exist, secrets in Key Vault |
| 2 | Run `sql/` DDL + generator `--day 1` | Source tables populated |
| 3 | Deploy ADF, run pipeline | Parquet under `landing/`, watermarks advance |
| 4 | UC storage credential / external location + secret scope | Notebooks can read `landing` and write `lakehouse` |
| 5 | Run Bronze → Silver → SCD2 | Dirty rows in quarantine, silver tables populated |
| 6 | Run Gold dims + fact for day 1 | `fact_exposure_snapshot` for D1 |
| 7 | Generator `--day 2`, re-run ADF + workflow | Only changed rows ingested; SCD2 shows rating history; fact for D2; DQ gate green |
| 8 | Outcome queries + docs | Exposure by counterparty/day reconciles to source |

## 6. Out of scope for MVP (planned later)

Streaming (Event Hubs), CDC connectors, remaining six facts, dbt, Purview, Airflow, Power BI, FX feed, PD/LGD/EAD, counterparty hierarchy, hard-delete handling, incremental SCD2 MERGE, CI/CD pipelines.

## 7. Open items

1. Bronze / audit retention period (7-year regulatory vs 90-day archive).
2. Confirmation that the LC-only scope is correct (vs trade-wide Basel/FRTB in Doc A).
3. Source for credit limits (needed for phase 2).
4. Counterparty hierarchy source.
5. Sprint length, ceremonies, release cadence (Doc B: "to confirm").
