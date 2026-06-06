-- =============================================================
-- Dispatch DB - Optimized Schema and Seed Data
-- Goal:
--   * Stabilize the hot ops dashboard plan
--   * Eliminate recurring index bloat on courier_assignments
--   * Reduce write amplification on a high-churn table
--   * Keep maintenance safe for production by using concurrent DDL
-- =============================================================

-- -------------------------
-- Extensions
-- -------------------------
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- -------------------------
-- Session-level maintenance settings
-- -------------------------
SET statement_timeout = 0;
SET lock_timeout = '5s';
SET maintenance_work_mem = '256MB';

-- -------------------------
-- Lookup: Cities
-- -------------------------
CREATE TABLE cities (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    country     VARCHAR(60)  NOT NULL,
    timezone    VARCHAR(60)  NOT NULL DEFAULT 'UTC',
    active      BOOLEAN      NOT NULL DEFAULT TRUE
);

INSERT INTO cities (name, country, timezone) VALUES
  ('New York',     'US', 'America/New_York'),
  ('Los Angeles',  'US', 'America/Los_Angeles'),
  ('Chicago',      'US', 'America/Chicago'),
  ('Houston',      'US', 'America/Chicago'),
  ('Phoenix',      'US', 'America/Phoenix'),
  ('Philadelphia', 'US', 'America/New_York'),
  ('San Antonio',  'US', 'America/Chicago'),
  ('San Diego',    'US', 'America/Los_Angeles'),
  ('Dallas',       'US', 'America/Chicago'),
  ('San Jose',     'US', 'America/Los_Angeles');

-- -------------------------
-- Lookup: Restaurants
-- -------------------------
CREATE TABLE restaurants (
    id          SERIAL PRIMARY KEY,
    city_id     INT          NOT NULL REFERENCES cities(id),
    name        VARCHAR(150) NOT NULL,
    address     TEXT         NOT NULL,
    cuisine     VARCHAR(60),
    active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

INSERT INTO restaurants (city_id, name, address, cuisine)
SELECT
    (i % 10) + 1,
    'Restaurant_' || i,
    i || ' Main Street',
    (ARRAY['Italian','Mexican','Chinese','American','Japanese','Indian','Thai','Mediterranean'])[(i % 8) + 1]
FROM generate_series(1, 200) AS s(i);

-- -------------------------
-- Lookup: Couriers
-- -------------------------
CREATE TABLE couriers (
    id              SERIAL PRIMARY KEY,
    city_id         INT          NOT NULL REFERENCES cities(id),
    name            VARCHAR(120) NOT NULL,
    phone           VARCHAR(20)  NOT NULL,
    vehicle_type    VARCHAR(30)  NOT NULL DEFAULT 'bike',
    rating          NUMERIC(3,2) NOT NULL DEFAULT 4.50,
    active          BOOLEAN      NOT NULL DEFAULT TRUE,
    joined_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

INSERT INTO couriers (city_id, name, phone, vehicle_type, rating)
SELECT
    (i % 10) + 1,
    'Courier_' || i,
    '+1-555-' || LPAD(i::text, 7, '0'),
    (ARRAY['bike','scooter','car','bicycle'])[(i % 4) + 1],
    3.50 + ROUND((RANDOM() * 1.50)::numeric, 2)
FROM generate_series(1, 2000) AS s(i);

-- -------------------------
-- Lookup: Orders
-- -------------------------
CREATE TABLE orders (
    id               SERIAL PRIMARY KEY,
    city_id          INT           NOT NULL REFERENCES cities(id),
    restaurant_id    INT           NOT NULL REFERENCES restaurants(id),
    customer_name    VARCHAR(120)  NOT NULL,
    customer_phone   VARCHAR(20)   NOT NULL,
    total_amount     NUMERIC(10,2) NOT NULL,
    status           VARCHAR(30)   NOT NULL DEFAULT 'placed',
    placed_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    delivered_at     TIMESTAMPTZ
);

INSERT INTO orders (city_id, restaurant_id, customer_name, customer_phone, total_amount, status, placed_at, delivered_at)
SELECT
    (i % 10) + 1,
    (i % 200) + 1,
    'Customer_' || i,
    '+1-555-' || LPAD((i + 10000)::text, 7, '0'),
    5.00 + ROUND((RANDOM() * 95.00)::numeric, 2),
    CASE (i % 5)
        WHEN 0 THEN 'placed'
        WHEN 1 THEN 'confirmed'
        WHEN 2 THEN 'in_transit'
        WHEN 3 THEN 'delivered'
        ELSE 'cancelled'
    END,
    now() - (RANDOM() * interval '30 days'),
    CASE WHEN (i % 5) = 3 THEN now() - (RANDOM() * interval '25 days') ELSE NULL END
FROM generate_series(1, 50000) AS s(i);

-- -------------------------
-- Main table: courier_assignments
-- Optimizations applied:
--   * lower fillfactor to preserve HOT-update headroom
--   * aggressive autovacuum/analyze thresholds for churn
--   * secondary indexes created after bulk load/churn so they start lean
-- -------------------------
CREATE TABLE courier_assignments (
    id              BIGSERIAL     PRIMARY KEY,
    order_id        INT           NOT NULL REFERENCES orders(id),
    courier_id      INT           NOT NULL REFERENCES couriers(id),
    city_id         INT           NOT NULL REFERENCES cities(id),
    state           VARCHAR(20)   NOT NULL DEFAULT 'searching',
    scheduled_for   TIMESTAMPTZ   NOT NULL,
    accepted_at     TIMESTAMPTZ,
    picked_up_at    TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    cancel_reason   VARCHAR(200),
    distance_km     NUMERIC(6,2),
    earnings        NUMERIC(8,2),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
) WITH (
    fillfactor = 80,
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_analyze_scale_factor = 0.01,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_threshold = 500,
    autovacuum_vacuum_insert_scale_factor = 0.05,
    autovacuum_vacuum_cost_limit = 2000
);

-- ---------------------------------------------------------------
-- Seed courier_assignments with ~200,000 rows.
-- Distribution:
--   ~5% searching  (hot minority subset)
--   ~10% offered
--   ~15% accepted
--   ~60% completed
--   ~10% cancelled
-- ---------------------------------------------------------------
INSERT INTO courier_assignments (
    order_id, courier_id, city_id, state,
    scheduled_for, accepted_at, picked_up_at, completed_at,
    cancelled_at, cancel_reason, distance_km, earnings,
    created_at, updated_at
)
SELECT
    (i % 50000) + 1                                                         AS order_id,
    (i % 2000)  + 1                                                         AS courier_id,
    ((i % 10)   + 1)                                                        AS city_id,
    CASE
        WHEN i % 20 IN (0,1)        THEN 'searching'
        WHEN i % 20 IN (2,3,4)      THEN 'offered'
        WHEN i % 20 IN (5,6,7,8)    THEN 'accepted'
        WHEN i % 20 = 9             THEN 'cancelled'
        ELSE                             'completed'
    END                                                                     AS state,
    now() - (RANDOM() * interval '14 days') + (RANDOM() * interval '2 days') AS scheduled_for,
    CASE WHEN i % 20 NOT IN (0,1,2,3,4,9) THEN now() - (RANDOM() * interval '12 days') ELSE NULL END,
    CASE WHEN i % 20 NOT IN (0,1,2,3,4,5,9) THEN now() - (RANDOM() * interval '10 days') ELSE NULL END,
    CASE WHEN i % 20 NOT IN (0,1,2,3,4,5,6,7,8,9) THEN now() - (RANDOM() * interval '8 days') ELSE NULL END,
    CASE WHEN i % 20 = 9 THEN now() - (RANDOM() * interval '5 days') ELSE NULL END,
    CASE WHEN i % 20 = 9 THEN (ARRAY['customer_cancelled','restaurant_closed','courier_unavailable'])[(i % 3) + 1] ELSE NULL END,
    1.0 + ROUND((RANDOM() * 19.0)::numeric, 2),
    2.00 + ROUND((RANDOM() * 18.00)::numeric, 2),
    now() - (RANDOM() * interval '14 days'),
    now() - (RANDOM() * interval '7 days')
FROM generate_series(1, 200000) AS s(i);

-- ---------------------------------------------------------------
-- Simulate churn on the hot table.
-- With the optimized storage parameters, distance-only updates can stay HOT,
-- and the table is then vacuumed/analyzed after maintenance DDL.
-- ---------------------------------------------------------------
UPDATE courier_assignments
SET state = 'offered', updated_at = now()
WHERE state = 'searching'
  AND id % 3 = 0;

UPDATE courier_assignments
SET state = 'accepted', accepted_at = now(), updated_at = now()
WHERE state = 'offered'
  AND id % 4 = 0;

UPDATE courier_assignments
SET state = 'completed', completed_at = now(), updated_at = now()
WHERE state = 'accepted'
  AND id % 5 = 0;

UPDATE courier_assignments
SET state = 'cancelled', cancelled_at = now(),
    cancel_reason = 'timeout', updated_at = now()
WHERE state = 'offered'
  AND id % 7 = 0;

UPDATE courier_assignments
SET distance_km = distance_km + 0.1, updated_at = now()
WHERE id % 2 = 0;

-- -------------------------
-- Supporting table: assignment_events
-- -------------------------
CREATE TABLE assignment_events (
    id              BIGSERIAL    PRIMARY KEY,
    assignment_id   BIGINT       NOT NULL,
    event_type      VARCHAR(40)  NOT NULL,
    from_state      VARCHAR(20),
    to_state        VARCHAR(20),
    recorded_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    metadata        JSONB
) WITH (
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_vacuum_insert_scale_factor = 0.05
);

INSERT INTO assignment_events (assignment_id, event_type, from_state, to_state, recorded_at, metadata)
SELECT
    (i % 200000) + 1,
    (ARRAY['state_change','location_update','eta_update','cancellation'])[(i % 4) + 1],
    CASE i % 4
        WHEN 0 THEN 'searching'
        WHEN 1 THEN 'offered'
        WHEN 2 THEN 'accepted'
        ELSE NULL
    END,
    CASE i % 4
        WHEN 0 THEN 'offered'
        WHEN 1 THEN 'accepted'
        WHEN 2 THEN 'completed'
        ELSE 'cancelled'
    END,
    now() - (RANDOM() * interval '14 days'),
    jsonb_build_object('source', 'system', 'version', (i % 3) + 1)
FROM generate_series(1, 400000) AS s(i);

-- =============================================================
-- Optimizer/statistics tuning
-- =============================================================
ALTER TABLE courier_assignments ALTER COLUMN state SET STATISTICS 1000;
ALTER TABLE courier_assignments ALTER COLUMN city_id SET STATISTICS 1000;
ALTER TABLE courier_assignments ALTER COLUMN scheduled_for SET STATISTICS 500;
ALTER TABLE courier_assignments ALTER COLUMN completed_at SET STATISTICS 500;
ALTER TABLE courier_assignments ALTER COLUMN cancelled_at SET STATISTICS 500;

CREATE STATISTICS IF NOT EXISTS st_courier_assignments_city_state
    (dependencies, mcv)
    ON city_id, state
    FROM courier_assignments;

-- =============================================================
-- Concurrent, production-safe index maintenance strategy
-- =============================================================

-- Hot ops query:
--   WHERE city_id = ?
--     AND state = 'searching'
--     AND scheduled_for <= now()
--   ORDER BY scheduled_for
-- Partial index keeps only the hot minority subset and preserves order.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_assignments_searching_city_schedule
    ON courier_assignments (city_id, scheduled_for)
    INCLUDE (id, courier_id, order_id)
    WHERE state = 'searching';

-- Reporting query on recently completed work.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_assignments_completed_recent
    ON courier_assignments (completed_at DESC, city_id)
    INCLUDE (created_at, earnings)
    WHERE state = 'completed' AND completed_at IS NOT NULL;

-- Courier history lookup, replacing the old single-column courier_id index
-- with a covering index that reduces heap fetches.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_assignments_courier_history
    ON courier_assignments (courier_id, id)
    INCLUDE (state, scheduled_for, completed_at);

-- Ops cancellation summary over recent time windows.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_assignments_cancelled_recent
    ON courier_assignments (cancelled_at DESC, city_id, cancel_reason)
    WHERE state = 'cancelled' AND cancelled_at IS NOT NULL;

-- Missing join index for assignment history / event reporting.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_assignment_events_assignment_recorded
    ON assignment_events (assignment_id, recorded_at DESC)
    INCLUDE (event_type, from_state, to_state);

-- Defensive cleanup for older, write-amplifying indexes if they exist.
DROP INDEX CONCURRENTLY IF EXISTS idx_assignments_city_state_updated;
DROP INDEX CONCURRENTLY IF EXISTS idx_assignments_state;
DROP INDEX CONCURRENTLY IF EXISTS idx_assignments_courier_id;
DROP INDEX CONCURRENTLY IF EXISTS idx_assignments_scheduled_for;

-- Rebuild the primary key index safely to remove any residual bloat caused by
-- churn before autovacuum/vacuum has a chance to recycle dead tuples.
REINDEX INDEX CONCURRENTLY courier_assignments_pkey;

-- =============================================================
-- Final vacuum/analyze pass
-- =============================================================
VACUUM (ANALYZE) courier_assignments;
VACUUM (ANALYZE) assignment_events;
ANALYZE orders;
ANALYZE couriers;
ANALYZE cities;
ANALYZE restaurants;

-- =============================================================
-- End state:
--   * No redundant low-value indexes on courier_assignments
--   * Hot query served by a small partial ordered index
--   * Safer autovacuum thresholds for a high-churn table
--   * Missing event join index added
-- =============================================================
