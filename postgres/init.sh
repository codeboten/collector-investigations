#!/bin/bash
# Runs once on first start (docker-entrypoint-initdb.d): monitoring role for both collectors.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
CREATE ROLE ${PG_MONITOR_USER} WITH LOGIN PASSWORD '${PG_MONITOR_PASSWORD}';
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
GRANT pg_monitor TO ${PG_MONITOR_USER};
SQL
