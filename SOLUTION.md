# Solution Steps

1. Enable PostgreSQL instrumentation needed for real plan analysis by preloading `pg_stat_statements` and turning on I/O timing in the container configuration.

2. Treat `courier_assignments` as a high-churn table: lower its `fillfactor` and set aggressive per-table autovacuum/analyze thresholds so dead tuples are cleaned long before the default 20% scale factor is reached.

3. Remove the indexing pattern that causes write amplification and plan instability: the wide `(city_id, state, updated_at)` index, the low-value `state` index, the standalone `scheduled_for` index, and the non-covering `courier_id` index.

4. Create a small partial covering index for the hot dashboard query: index `(city_id, scheduled_for)` with `INCLUDE (id, courier_id, order_id)` and predicate `WHERE state = 'searching'` so the planner can use an ordered index scan for `city_id + state + scheduled_for <= now()`.

5. Add targeted partial indexes for the secondary workload paths: one on recent completed assignments and one on recent cancelled assignments, each keyed by the timestamp used in the filter and restricted to the relevant state.

6. Replace the old courier lookup index with a covering history index on `(courier_id, id)` and add the missing `assignment_events (assignment_id, recorded_at DESC)` index so history/reporting joins stop scanning the entire events table.

7. Improve planner estimate stability by increasing statistics targets on the hot filter columns and creating extended statistics on `(city_id, state)` for `courier_assignments`.

8. Apply the index migration in a production-safe way: build new indexes with `CREATE INDEX CONCURRENTLY`, drop obsolete indexes with `DROP INDEX CONCURRENTLY`, and rebuild the churned primary key with `REINDEX INDEX CONCURRENTLY` so writes are not blocked.

9. Run `VACUUM (ANALYZE)` after the migration so dead tuples are cleared, visibility maps are refreshed, and the planner has up-to-date row-count/selectivity data.

10. Validate the result with `EXPLAIN (ANALYZE, BUFFERS)` on the sample queries, confirm the hot dashboard query uses the new partial index consistently, and inspect `pg_stat_user_tables`, `pg_stat_user_indexes`, and `pg_stat_statements` to confirm lower bloat and better execution times.

