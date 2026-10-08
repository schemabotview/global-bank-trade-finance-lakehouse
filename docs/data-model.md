# Data model (MVP)

## Gold star — `fact_exposure_snapshot`

Grain: LC × exposure type × `as_of_date` (only open exposure, amount > 0). Snapshot measure: do not sum across dates.

| Column | Notes |
|---|---|
| `exposure_sk` | `xxhash64(lc_id, exposure_type, as_of_date)` |
| `as_of_date_sk` | yyyymmdd, partition and `replaceWhere` key |
| `lc_sk`, `counterparty_sk`, `bank_sk`, `currency_sk` | `-1` = unknown member (counterparty, bank, currency) |
| `outstanding_exposure_local / _usd` | latest event as of end of day; USD uses static MVP FX |
| `lc_amount_current_local` | original amount + approved amendments to the date |

`dim_counterparty` is SCD2 (`eff_start_date` inclusive, `eff_end_date` exclusive, `9999-12-31` = current).
The fact joins the version where `eff_start_date <= as_of_date < eff_end_date`, so a downgrade on D+1 never changes D.

View `gold.v_counterparty_exposure_daily` answers the outcome: USD exposure per counterparty per day with the rating at that day.

## Data-quality rules

Defined in `databricks/notebooks/_common.ipynb` (`get_rules`). Failing rows go to `silver.quarantine`
with the failed rule names. Gate checks (`60_dq_reconcile`) are stored in `gold.dq_results`.

| Source | Rules |
|---|---|
| PARTY | id present, name present, rating in scale, country length 2 |
| LETTER_OF_CREDIT | amount > 0, currency known, expiry ≥ issue, status valid |
| LC_EXPOSURE_EVENT | amount ≥ 0, currency known, type valid, `source_event_ref` present, no duplicate `source_event_ref` |
| Children | orphan LC / party keys quarantined |

## Known MVP simplifications

Static FX; `issuing_bank_id` on LC instead of `LC_BANK_ROLE`; SCD2 rebuilt in full each run; no hard-delete handling;
no credit-limit comparison (phase 2).
