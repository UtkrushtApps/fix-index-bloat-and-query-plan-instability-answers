#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " Dispatch DB Task - Cleanup"
echo "=========================================="

# Step 1: Stop and remove containers, volumes, networks
echo "[1/5] Stopping and removing containers..."
docker-compose -f /root/task/docker-compose.yml down --volumes --remove-orphans || true

# Step 2: Remove Docker images
echo "[2/5] Removing Docker images..."
docker rmi -f postgres:15-alpine || true

# Step 3: Prune all dangling Docker resources
echo "[3/5] Pruning dangling Docker resources..."
docker system prune -a --volumes -f

# Step 4: Remove PostgreSQL data directory
echo "[4/5] Removing PostgreSQL data directory..."
rm -rf /root/task/data || true

# Step 5: Remove the entire task folder
echo "[5/5] Deleting /root/task folder..."
rm -rf /root/task || true

echo ""
echo "Cleanup completed successfully! Droplet is now clean."
