# PostgreSQL

Compares the metrics three OpenTelemetry Collector pipelines produce from the
same PostgreSQL 17 server (with `pg_stat_statements`).

## Run it

```sh
docker compose up -d
```

| # | Pipeline | What it is | Metrics |
|---|---|---|---|
| 1 | `otelcol-postgresql` | Collector Contrib, `postgresql` receiver (every metric in the receiver's `documentation.md` enabled) | http://localhost:8889/metrics (`postgresql_*`) |
| 2 | `otelcol-prometheus` | `opentelemetry-collector-prometheus` distribution, embedded `postgres_exporter` receiver | http://localhost:8890/metrics (`pg_*`) |
| 3 | `otelcol-postgresql-pgnames` | Same receiver as #1, with metric and label names translated to postgres_exporter's | http://localhost:8891/metrics (`pg_*`) |

Each pipeline sends OTLP to `local-collector`, which re-exposes it on its own
Prometheus port. Nothing is sent outside your machine. Credentials are demo
values defined in `docker-compose.yml` (override with `POSTGRES_PASSWORD`,
`PG_MONITOR_USER`, `PG_MONITOR_PASSWORD`).

Generate some load so the counters move:

```sh
docker compose exec postgres sh -c 'pgbench -i -U postgres postgres && pgbench -c 2 -T 60 -U postgres postgres'
```

Compare:

```sh
for p in 8889 8890 8891; do echo "$p: $(curl -s localhost:$p/metrics | grep -c '^# TYPE') families"; done
curl -s localhost:8890/metrics | grep '^pg_stat_database_xact_commit'
curl -s localhost:8891/metrics | grep '^pg_stat_database_xact_commit'
docker compose down -v   # clean up
```

## Layout

- `otelcol-postgresql/config.yaml`: pipeline 1.
- `otelcol-prometheus/config.yaml`: pipeline 2.
- `otelcol-postgresql-pgnames/config.yaml`: pipeline 3 (see [the translation](#translating-the-receiver-to-postgres_exporter-names)).
- `local-collector/config.yaml`: one OTLP receiver and Prometheus exporter per pipeline (plus a filter that drops template databases from pipeline 2).
- `init.sh`: creates the `pg_monitor` role the collectors connect as.

## Findings

Observed with a light `pgbench` load, scraped every 15s.

| | 1. `postgresql` receiver | 2. `postgres_exporter` receiver | 3. `postgresql` + translation |
|---|---|---|---|
| Families | 33 `postgresql_*` | 349 `pg_*` | 41 `pg_*` |
| Series | ~120 | ~505 | ~95 |
| Naming | OTel semantic names (`postgresql_commits_total`) | postgres_exporter names, `_total` on counters | postgres_exporter names, `_total` on counters |
| Style | Curated metrics with dimensions (`operation`, `source`, `state`) | Raw `pg_stat_*` columns, 1:1 with the catalog views | Pipeline 1's data under pipeline 2's names |
| Labels | `postgresql_database_name`, `postgresql_table_name` | `datname`, `schemaname`, `relname`, `datid`, `server` | `datname`, `schemaname`, `relname` |
| Databases covered | every non-template database (`databases: []`) | every non-template database (see note) | every non-template database |

Pipeline 2's 349 families include **274 `pg_settings_*`** (every server setting
as a metric) and a few exporter self-metrics; about 73 are real statistics.

### Pipeline 1: `postgresql` receiver

33 families: 22 default plus 16 optional metrics observed (all 43 documented
metrics are enabled). Enabling the rest changes nothing here, because these
are not emitted in this environment:

| Metric | Why absent |
|---|---|
| `postgresql.replication.data_delay`, `wal.age`, `wal.lag`, `wal.delay` | need a streaming replica |
| `postgresql.function.calls` | needs `track_functions` set (default `none`) and function calls |
| `postgresql.vector.*` (5) | need the pgvector extension; stock `postgres:17` lacks it |

### Pipeline 2: `postgres_exporter` receiver

**Which databases:** all three pipelines cover every non-template database. The
`postgresql` receiver does this with `databases: []` (it discovers databases
each scrape and skips templates). The exporter uses `auto_discover_databases`
with `exclude_databases: [template0, template1]`, but its `pg_stat_database`
collector ignores that list and always reports the templates, so
`local-collector` drops `template0`/`template1` data points from this pipeline.
Remove the `filter/templates` processor there to see the raw exporter output.

The prometheus-community exporter run as a collector receiver, so it is
equivalent to what a standalone `postgres_exporter` expose, and existing
dashboards and alerts built on `pg_*` names work with it. Counters keep
their Prometheus type.

### Pipeline 3: translating the receiver to `postgres_exporter` names

Pipeline 3 runs the same `postgresql` receiver, then `transform/pgnames` ->
`metricstransform/pgnames` -> `filter/pgnames`:

1. **transform**: `postgresql.database.name` and `postgresql.table.name` are
   *resource* attributes on this receiver, and `metricstransform` only sees
   data point labels, so they are copied down to `datname`, `schemaname` and
   `relname` (splitting the receiver's `schema.table` on `.`) and then removed
   from the resource. Lock `mode` is lowercased.
2. **metricstransform** `insert`s a renamed copy of each mapped metric. Metrics
   the receiver folds into one name with a discriminator label are split with
   `experimental_match_labels`, and the discriminator is dropped with
   `aggregate_labels`.
3. **filter** drops the remaining `postgresql.*` metrics.

| receiver metric | -> postgres_exporter metric |
|---|---|
| `postgresql.backends` | `pg_stat_database_numbackends` |
| `postgresql.commits` / `rollbacks` / `deadlocks` | `pg_stat_database_xact_commit` / `_xact_rollback` / `_deadlocks` |
| `postgresql.blks_hit` / `blks_read` | `pg_stat_database_blks_hit` / `_blks_read` |
| `postgresql.tup_{fetched,inserted,returned,updated,deleted}` | `pg_stat_database_tup_*` |
| `postgresql.temp_files` / `temp.io` | `pg_stat_database_temp_files` / `_temp_bytes` |
| `postgresql.query.conflicts{conflict.type}` | `pg_stat_database_conflicts_confl_{bufferpin,deadlock,lock,snapshot,tablespace}` |
| `postgresql.db_size` | `pg_database_size_bytes` |
| `postgresql.connection.max` | `pg_settings_max_connections` |
| `postgresql.bgwriter.buffers.allocated` | `pg_stat_bgwriter_buffers_alloc` |
| `postgresql.bgwriter.buffers.writes{source=bgwriter}` | `pg_stat_bgwriter_buffers_clean` |
| `postgresql.bgwriter.maxwritten` | `pg_stat_bgwriter_maxwritten_clean` |
| `postgresql.blocks_read{source=heap/idx/toast/tidx_hit/read}` | `pg_statio_user_tables_{heap,idx,toast,tidx}_blocks_{hit,read}` |
| `postgresql.operations{operation=ins/upd/del/hot_upd}` | `pg_stat_user_tables_n_tup_{ins,upd,del,hot_upd}` |
| `postgresql.rows{state=live/dead}` | `pg_stat_user_tables_n_{live,dead}_tup` |
| `postgresql.sequential_scans` | `pg_stat_user_tables_seq_scan` |
| `postgresql.table.vacuum.count` | `pg_stat_user_tables_vacuum_count` |
| `postgresql.table.size` | `pg_stat_user_tables_table_size_bytes` (see below) |
| `postgresql.database.locks` | `pg_locks_count{datname,mode}` (summed over lock_type/relation) |
