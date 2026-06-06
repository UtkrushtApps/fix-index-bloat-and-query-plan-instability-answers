#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " Dispatch DB Task - Environment Setup"
echo "=========================================="

# Step 1: Start containers
echo "[1/4] Starting Docker containers..."
docker-compose -f /root/task/docker-compose.yml up -d

# Step 2: Wait for PostgreSQL to be ready
echo "[2/4] Waiting for PostgreSQL to be ready..."
MAX_RETRIES=30
RETRY_COUNT=0
until docker exec dispatch_postgres pg_isready -U dispatch_user -d dispatch_db -q 2>/dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: PostgreSQL did not become ready after $MAX_RETRIES attempts. Exiting."
    docker-compose -f /root/task/docker-compose.yml logs postgres
    exit 1
  fi
  echo "  Waiting... (attempt $RETRY_COUNT/$MAX_RETRIES)"
  sleep 3
done

echo "  PostgreSQL is ready."

# Step 3: Validate database is accessible and initialized
echo "[3/4] Validating database initialization..."
TABLE_COUNT=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';")

if [ "$TABLE_COUNT" -lt "5" ]; then
  echo "ERROR: Expected at least 5 tables in public schema, found $TABLE_COUNT. Initialization may have failed."
  docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -c "\\dt"
  exit 1
fi

ROW_COUNT=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*) FROM courier_assignments;")

OPTIMIZED_ASSIGNMENT_INDEXES=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*)
   FROM pg_indexes
   WHERE schemaname = 'public'
     AND tablename = 'courier_assignments'
     AND indexname IN (
       'idx_assignments_searching_city_schedule',
       'idx_assignments_completed_recent',
       'idx_assignments_courier_history',
       'idx_assignments_cancelled_recent'
     );")

EVENT_INDEXES=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*)
   FROM pg_indexes
   WHERE schemaname = 'public'
     AND tablename = 'assignment_events'
     AND indexname = 'idx_assignment_events_assignment_recorded';")

if [ "$OPTIMIZED_ASSIGNMENT_INDEXES" -lt "4" ] || [ "$EVENT_INDEXES" -lt "1" ]; then
  echo "ERROR: Expected optimized indexes were not created successfully."
  docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -c "SELECT schemaname, tablename, indexname FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename, indexname;"
  exit 1
fi

REL_OPTIONS=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COALESCE(array_to_string(reloptions, ', '), 'default')
   FROM pg_class
   WHERE relname = 'courier_assignments';")

PRELOAD_LIBS=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc "SHOW shared_preload_libraries;")

echo "  Tables found: $TABLE_COUNT"
echo "  Courier assignments rows: $ROW_COUNT"
echo "  Optimized courier_assignments indexes: $OPTIMIZED_ASSIGNMENT_INDEXES"
echo "  assignment_events join indexes: $EVENT_INDEXES"
echo "  courier_assignments reloptions: $REL_OPTIONS"
echo "  shared_preload_libraries: $PRELOAD_LIBS"

# Step 4: Print connection summary
echo "[4/4] Environment ready."
echo ""
echo "------------------------------------------"
echo " Database Connection Details"
echo "------------------------------------------"
echo " Host     : <DROPLET_IP>"
echo " Port     : 5432"
echo " Database : dispatch_db"
echo " Username : dispatch_user"
echo " Password : dispatch_pass"
echo "------------------------------------------"
echo " Connect via psql:"
echo "   psql -h <DROPLET_IP> -p 5432 -U dispatch_user -d dispatch_db"
echo "------------------------------------------"
echo ""
echo "Setup complete. Good luck!"
