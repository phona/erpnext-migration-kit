#!/bin/bash
# ==============================================================================
# Initialize .env from DATA_ROOT
# ==============================================================================
# Usage: ./init-env.sh [DATA_ROOT]
#   DATA_ROOT defaults to ./data if not specified
# ==============================================================================

set -e

DATA_ROOT="${1:-./data}"

# Resolve to absolute path if relative
if [[ "$DATA_ROOT" != /* ]]; then
  DATA_ROOT="$(cd "$(dirname "$DATA_ROOT")" 2>/dev/null && pwd)/$(basename "$DATA_ROOT")"
fi

cat > .env << EOF
# ==============================================================================
# ERPNext Production Environment Variables
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

# ------------------------------------------------------------------------------
# ERPNext Version (Docker image tag)
# ------------------------------------------------------------------------------
ERPNEXT_VERSION=v15.95.2

# ------------------------------------------------------------------------------
# Database
# ------------------------------------------------------------------------------
DB_PASSWORD=change-this-password

# ------------------------------------------------------------------------------
# Data Storage (absolute paths)
# ------------------------------------------------------------------------------
SITES_PATH=${DATA_ROOT}/sites
MARIADB_PATH=${DATA_ROOT}/mariadb
REDIS_QUEUE_PATH=${DATA_ROOT}/redis-queue

# ------------------------------------------------------------------------------
# Frontend
# ------------------------------------------------------------------------------
HTTP_PUBLISH_PORT=9100

# ------------------------------------------------------------------------------
# Site Configuration
# ------------------------------------------------------------------------------
FRAPPE_SITE_NAME_HEADER=
EOF

echo "Created .env with DATA_ROOT=${DATA_ROOT}"
echo ""
echo "Paths:"
echo "  Sites:    ${DATA_ROOT}/sites"
echo "  MariaDB:  ${DATA_ROOT}/mariadb"
echo "  Redis:    ${DATA_ROOT}/redis-queue"
echo ""
echo "Edit .env to set DB_PASSWORD and FRAPPE_SITE_NAME_HEADER"
