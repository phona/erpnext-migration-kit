#!/bin/bash
# ==============================================================================
# One-Line ERPNext Deploy & Restore
# ==============================================================================
# Usage:
#   ./deploy-and-restore.sh \
#     --data-root /opt/erpnext/data \
#     --backup-path /backups/20260317 \
#     --site-name your_site \
#     --domain erpnext.example.com \
#     --db-password yourpassword \
#     --admin-password admin
#
# Or with environment file:
#   ./deploy-and-restore.sh --env-file /path/to/.env --backup-path /backups/20260317
# ==============================================================================

set -euo pipefail

# Defaults
DATA_ROOT=""
BACKUP_PATH=""
SITE_NAME=""
PUBLIC_DOMAIN=""
DB_PASSWORD=""
ADMIN_PASSWORD="admin"
ERPNEXT_VERSION="v15.95.2"
HTTP_PORT="9100"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --data-root) DATA_ROOT="$2"; shift 2 ;;
    --backup-path) BACKUP_PATH="$2"; shift 2 ;;
    --site-name) SITE_NAME="$2"; shift 2 ;;
    --domain) PUBLIC_DOMAIN="$2"; shift 2 ;;
    --db-password) DB_PASSWORD="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --erpnext-version) ERPNEXT_VERSION="$2"; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Required:"
      echo "  --data-root PATH        Data storage directory"
      echo "  --backup-path PATH      Backup directory to restore"
      echo "  --site-name NAME        Site name (from backup)"
      echo "  --domain DOMAIN         Public domain"
      echo "  --db-password PASS      Database root password"
      echo ""
      echo "Optional:"
      echo "  --admin-password PASS   Admin password (default: admin)"
      echo "  --erpnext-version VER   ERPNext version (default: v15.95.2)"
      echo "  --http-port PORT        HTTP port (default: 9100)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required args
for var in DATA_ROOT BACKUP_PATH SITE_NAME PUBLIC_DOMAIN DB_PASSWORD; do
  if [[ -z "${!var}" ]]; then
    echo "Error: --${var//_/-} is required"
    exit 1
  fi
done

# Resolve paths
DATA_ROOT="$(cd "$(dirname "$DATA_ROOT")" 2>/dev/null && pwd)/$(basename "$DATA_ROOT")" 2>/dev/null || DATA_ROOT="$DATA_ROOT"
BACKUP_PATH="$(cd "$(dirname "$BACKUP_PATH")" 2>/dev/null && pwd)/$(basename "$BACKUP_PATH")" 2>/dev/null || BACKUP_PATH="$BACKUP_PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"  # Parent of scripts/

echo "=============================================="
echo "ERPNext Deploy & Restore"
echo "=============================================="
echo "Data Root:      $DATA_ROOT"
echo "Backup Path:    $BACKUP_PATH"
echo "Site Name:      $SITE_NAME"
echo "Domain:         $PUBLIC_DOMAIN"
echo "ERPNext:        $ERPNEXT_VERSION"
echo "HTTP Port:      $HTTP_PORT"
echo "=============================================="

# [1/6] Create directory structure
echo "[1/6] Creating directories..."
mkdir -p "$DATA_ROOT"/{sites,mariadb,redis-queue}
mkdir -p "$DATA_ROOT"/sites/assets

# [2/6] Create .env
echo "[2/6] Creating .env..."
cat > "$SCRIPT_DIR/.env" << EOF
ERPNEXT_VERSION=$ERPNEXT_VERSION
DB_PASSWORD=$DB_PASSWORD
SITES_PATH=$DATA_ROOT/sites
MARIADB_PATH=$DATA_ROOT/mariadb
REDIS_QUEUE_PATH=$DATA_ROOT/redis-queue
HTTP_PUBLISH_PORT=$HTTP_PORT
FRAPPE_SITE_NAME_HEADER=$PUBLIC_DOMAIN
EOF

# [3/6] Initialize sites directory
echo "[3/6] Initializing sites..."
echo -e "frappe\nerpnext" > "$DATA_ROOT/sites/apps.txt"
cat > "$DATA_ROOT/sites/common_site_config.json" << 'EOF'
{
 "db_host": "db",
 "db_port": 3306,
 "redis_cache": "redis://redis-cache:6379",
 "redis_queue": "redis://redis-queue:6379",
 "redis_socketio": "redis://redis-queue:6379",
 "socketio_port": 9000
}
EOF

# Set permissions
chown -R 1000:1000 "$DATA_ROOT/sites"
chown -R 999:999 "$DATA_ROOT/mariadb" 2>/dev/null || true
chown -R 1000:1000 "$DATA_ROOT/redis-queue" 2>/dev/null || true

# [4/6] Start containers
echo "[4/6] Starting containers..."
cd "$SCRIPT_DIR"
docker compose \
  -f frappe_docker/compose.yaml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.prod.yaml \
  up -d

# Wait for db
echo "Waiting for database..."
sleep 10
until docker exec db mariadb -uroot -p"$DB_PASSWORD" -e "SELECT 1" &>/dev/null; do
  echo -n "."
  sleep 2
done
echo " OK"

# Wait for configurator
echo "Waiting for configurator..."
sleep 5
until docker compose logs configurator 2>&1 | grep -q "exited with code"; do
  sleep 2
done

# Restart to apply
docker compose restart backend frontend websocket scheduler queue-short queue-long

# [5/6] Create site
echo "[5/6] Creating site..."
docker exec backend bench new-site "$SITE_NAME" \
  --admin-password "$ADMIN_PASSWORD" \
  --db-root-password "$DB_PASSWORD" \
  --install-app erpnext \
  --mariadb-user-host-login-scope='%' \
  2>&1 | tail -5

# [6/6] Restore backup
echo "[6/6] Restoring backup..."
cd "$SCRIPT_DIR"
SITE_NAME="$SITE_NAME" \
PUBLIC_DOMAIN="$PUBLIC_DOMAIN" \
DB_ROOT_PASSWORD="$DB_PASSWORD" \
BACKUP_HOST_PATH="$BACKUP_PATH" \
BACKEND_CONTAINER=backend \
FRONTEND_CONTAINER=frontend \
RESET_ADMIN_PASSWORD=1 \
ADMIN_PASSWORD="$ADMIN_PASSWORD" \
bash scripts/restore-erpnext-site.sh 2>&1 | tail -30

echo ""
echo "=============================================="
echo "Deploy & Restore Complete!"
echo "=============================================="
echo "URL:      http://$PUBLIC_DOMAIN:$HTTP_PORT"
echo "Username: Administrator"
echo "Password: $ADMIN_PASSWORD"
echo "=============================================="
