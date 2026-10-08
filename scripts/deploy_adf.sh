#!/usr/bin/env bash
# Deploys linked services, datasets and the pipeline in adf/ to the Data Factory created by Terraform.
# Requires: az login, `az extension add --name datafactory`, jq. Run from the repo root.
set -euo pipefail

TF=infra/terraform
RG=$(terraform -chdir=$TF output -raw resource_group)
ADF=$(terraform -chdir=$TF output -raw data_factory)
KV=$(terraform -chdir=$TF output -raw key_vault)
SA=$(terraform -chdir=$TF output -raw storage_account)

# The payload flag differs per object type: linked-service and dataset take --properties,
# pipeline takes --pipeline. Passing the wrong one fails with "arguments are required".
deploy() { # kind file [payload-flag, default --properties]
  local kind=$1 file=$2 flag=${3:---properties} name props
  name=$(jq -r .name "$file")
  props=$(mktemp)
  jq .properties "$file" | sed "s/__KEY_VAULT_NAME__/$KV/g; s/__STORAGE_ACCOUNT__/$SA/g" > "$props"
  echo "-> $kind $name"
  az datafactory "$kind" create --resource-group "$RG" --factory-name "$ADF" --name "$name" "$flag" "@$props" >/dev/null
  rm -f "$props"
}

for f in adf/linkedService/ls_keyvault.json adf/linkedService/ls_sqldb.json adf/linkedService/ls_adls.json; do deploy linked-service "$f"; done
for f in adf/dataset/*.json; do deploy dataset "$f"; done
deploy pipeline adf/pipeline/pl_ingest_sqldb_to_landing.json --pipeline
echo "Deployed. The daily trigger (adf/trigger_daily.json) is intentionally not deployed; create it when ready."
