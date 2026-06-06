-- =============================================================
-- Validation queries for the optimized dispatch schema.
-- Run with EXPLAIN (ANALYZE, BUFFERS) and verify that the planner
-- prefers the new targeted indexes consistently.
-- =============================================================

-- ------------------------------------------------------------
-- QUERY 1: Hot ops dashboard query
-- Expected after optimization:
--   * stable Index Scan or Index Only Scan on
--     idx_assignments_searching_city_schedule
--   * no full-table Sequential Scan flip after churn
--   * typically well under 100ms on this dataset
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    ca.id,
    ca.courier_id,
    ca.order_id,
    ca.city_id,
    ca.scheduled_for,
    c.name   AS courier_name,
    c.phone  AS courier_phone
FROM courier_assignments ca
JOIN couriers c ON c.id = ca.courier_id
WHERE ca.city_id = 3
  AND ca.state = 'searching'
  AND ca.scheduled_for <= now()
ORDER BY ca.scheduled_for
LIMIT 200;

-- ------------------------------------------------------------
-- QUERY 2: City-level completion reporting (last 7 days)
-- Expected after optimization:
--   * uses idx_assignments_completed_recent
--   * avoids scanning the full courier_assignments table
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    ci.name                                                         AS city_name,
    COUNT(*)                                                        AS total_completed,
    AVG(EXTRACT(EPOCH FROM (ca.completed_at - ca.created_at))/60)   AS avg_duration_min,
    SUM(ca.earnings)                                                AS total_earnings
FROM courier_assignments ca
JOIN cities ci ON ci.id = ca.city_id
WHERE ca.state = 'completed'
  AND ca.completed_at >= now() - interval '7 days'
GROUP BY ci.name
ORDER BY total_completed DESC;

-- ------------------------------------------------------------
-- QUERY 3: Courier-level assignment history with events
-- Expected after optimization:
--   * courier_assignments uses idx_assignments_courier_history
--   * assignment_events uses idx_assignment_events_assignment_recorded
--   * no 400k-row sequential scan on assignment_events
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    ca.id            AS assignment_id,
    ca.state,
    ca.scheduled_for,
    ca.completed_at,
    ae.event_type,
    ae.from_state,
    ae.to_state,
    ae.recorded_at
FROM courier_assignments ca
JOIN assignment_events ae ON ae.assignment_id = ca.id
WHERE ca.courier_id = 500
ORDER BY ae.recorded_at DESC
LIMIT 50;

-- ------------------------------------------------------------
-- QUERY 4: Ops cancellation summary (last 24 hours)
-- Expected after optimization:
--   * uses idx_assignments_cancelled_recent
--   * avoids low-selectivity state-only scans
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    ca.city_id,
    ca.cancel_reason,
    COUNT(*) AS cancellation_count
FROM courier_assignments ca
WHERE ca.state = 'cancelled'
  AND ca.cancelled_at >= now() - interval '24 hours'
GROUP BY ca.city_id, ca.cancel_reason
ORDER BY cancellation_count DESC;

-- ------------------------------------------------------------
-- CHECK: Current index sizes and usage statistics
-- Run after exercising the sample queries to confirm that scans land
-- on the new purpose-built indexes rather than redundant ones.
-- ------------------------------------------------------------
SELECT
    i.relname AS index_name,
    pg_size_pretty(pg_relation_size(ix.indexrelid)) AS index_size,
    ix.idx_scan AS scans,
    ix.idx_tup_read AS tuples_read,
    ix.idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes ix
JOIN pg_class i ON i.oid = ix.indexrelid
WHERE ix.relname IN ('courier_assignments', 'assignment_events')
ORDER BY pg_relation_size(ix.indexrelid) DESC;

-- ------------------------------------------------------------
-- CHECK: Dead tuple accumulation and autovacuum effectiveness
-- ------------------------------------------------------------
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 2) AS dead_pct,
    last_autovacuum,
    last_autoanalyze,
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count
FROM pg_stat_user_tables
WHERE relname IN ('courier_assignments', 'assignment_events')
ORDER BY n_dead_tup DESC;

-- ------------------------------------------------------------
-- CHECK: Table reloptions and extended statistics used to stabilize
-- cardinality estimates on the hot query path.
-- ------------------------------------------------------------
SELECT
    c.relname,
    COALESCE(array_to_string(c.reloptions, ', '), 'default') AS reloptions
FROM pg_class c
WHERE c.relname IN ('courier_assignments', 'assignment_events')
ORDER BY c.relname;

SELECT
    stxname,
    pg_get_statisticsobjdef(oid) AS definition
FROM pg_statistic_ext
WHERE stxrelid = 'courier_assignments'::regclass;

-- ------------------------------------------------------------
-- OPTIONAL: Query-level telemetry from pg_stat_statements
-- ------------------------------------------------------------
SELECT
    query,
    calls,
    ROUND(total_exec_time::numeric, 2) AS total_exec_ms,
    ROUND(mean_exec_time::numeric, 2)  AS mean_exec_ms,
    rows
FROM pg_stat_statements
WHERE query ILIKE '%courier_assignments%'
ORDER BY total_exec_time DESC
LIMIT 10;
