#!/usr/bin/env bash
# Imports the notebooks and creates the workflow job. Requires the Databricks CLI (v0.2xx+) authenticated to the workspace.
set -euo pipefail

TF=infra/terraform
LANDING=$(terraform -chdir=$TF output -raw landing_root)
LAKEHOUSE=$(terraform -chdir=$TF output -raw lakehouse_root)
NB_ROOT=${NB_ROOT:-/Shared/tradefin}

databricks workspace mkdirs "$NB_ROOT"
for nb in databricks/notebooks/*.ipynb; do
  name=$(basename "$nb" .ipynb)
  databricks workspace import "$NB_ROOT/$name" --file "$nb" --format JUPYTER --language PYTHON --overwrite
done

job=$(mktemp)
sed "s#__NOTEBOOK_ROOT__#$NB_ROOT#g; s#__LANDING_ROOT__#$LANDING#g; s#__LAKEHOUSE_ROOT__#$LAKEHOUSE#g" \
  databricks/workflows/exposure_pipeline_job.json > "$job"
databricks jobs create --json "@$job"
rm -f "$job"
