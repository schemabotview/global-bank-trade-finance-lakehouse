#!/usr/bin/env bash
# Creates the source + control tables and loads synthetic data into Azure SQL.
# usage: scripts/load_source.sh <day: 1|2>   (SQL_PASSWORD must be exported; requires sqlcmd + pyodbc)
set -euo pipefail
DAY=${1:?day 1 or 2}
TF=infra/terraform
SERVER=$(terraform -chdir=$TF output -raw sql_server_fqdn)
DB=$(terraform -chdir=$TF output -raw sql_database)
USER_NAME=${SQL_USER:-sqladmin}

if [ "$DAY" = "1" ]; then
  for f in sql/01_source_ddl.sql sql/02_control_tables.sql; do
    sqlcmd -S "$SERVER" -d "$DB" -U "$USER_NAME" -P "$SQL_PASSWORD" -C -b -i "$f"
  done
fi
python3 generator/generate_data.py --day "$DAY" --target sql --server "$SERVER" --database "$DB" --user "$USER_NAME"
