#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ERPNext Site Restore Script
# ==============================================================================
# Usage:
#   SITE_NAME=wallace-t_s_frappe_cloud \
#   PUBLIC_DOMAIN=erpnext.hitosea.site \
#   DB_ROOT_PASSWORD='admin123' \
#   BACKUP_HOST_PATH=/root/frappe_docker/20260221_000101 \
#   bash ./restore-erpnext-site.sh
# ==============================================================================

# Required
SITE_NAME="${SITE_NAME:?set SITE_NAME to the internal ERPNext site name}"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:?set PUBLIC_DOMAIN to the public ERP domain}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD}"

# Backup source (one of these required)
BACKUP_HOST_PATH="${BACKUP_HOST_PATH:-}"           # Host path to backup dir
BACKUP_MOUNT_PATH="${BACKUP_MOUNT_PATH:-}"         # Already-mounted path in container

# Internal paths
SITES_PATH="${SITES_PATH:-/home/frappe/frappe-bench/sites}"
BACKEND_CONTAINER="${BACKEND_CONTAINER:-frappe_docker-backend-1}"
FRONTEND_CONTAINER="${FRONTEND_CONTAINER:-frappe_docker-frontend-1}"

# Options
RUN_MIGRATE="${RUN_MIGRATE:-1}"
ENABLE_SCHEDULER="${ENABLE_SCHEDULER:-1}"
RESET_ADMIN_PASSWORD="${RESET_ADMIN_PASSWORD:-0}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
CLEANUP_BACKUP="${CLEANUP_BACKUP:-1}"

# Ingress (optional)
INGRESS_CONFIG="${INGRESS_CONFIG:-}"
INGRESS_RESTART_CMD="${INGRESS_RESTART_CMD:-}"

# ==============================================================================

# Determine backup path
if [[ -n "$BACKUP_HOST_PATH" ]]; then
  BACKUP_MOUNT_PATH="${BACKUP_MOUNT_PATH:-/tmp/erpnext-backup}"
  BACKUP_WAS_COPIED=1
elif [[ -z "$BACKUP_MOUNT_PATH" ]]; then
  echo "Error: Set either BACKUP_HOST_PATH or BACKUP_MOUNT_PATH"
  exit 1
fi

echo "=============================================="
echo "ERPNext Site Restore"
echo "=============================================="
echo "Site Name:      $SITE_NAME"
echo "Public Domain:  $PUBLIC_DOMAIN"
echo "Backend:        $BACKEND_CONTAINER"
echo "Frontend:       $FRONTEND_CONTAINER"
echo "Backup Path:    ${BACKUP_HOST_PATH:-$BACKUP_MOUNT_PATH}"
echo "=============================================="
echo

# [0/9] Copy backup to container if needed
if [[ "${BACKUP_WAS_COPIED:-0}" == "1" ]]; then
  echo "[0/9] Copy backup to container"
  docker exec "$BACKEND_CONTAINER" mkdir -p "$BACKUP_MOUNT_PATH"
  docker cp "$BACKUP_HOST_PATH/." "$BACKEND_CONTAINER:$BACKUP_MOUNT_PATH"
  docker exec -u root "$BACKEND_CONTAINER" chown -R frappe:frappe "$BACKUP_MOUNT_PATH"
fi

# [1/9] Sanity check
echo "[1/9] Sanity check backup path and target site directory"
docker exec "$BACKEND_CONTAINER" test -d "$BACKUP_MOUNT_PATH"
docker exec "$BACKEND_CONTAINER" test -d "$SITES_PATH"
docker exec "$FRONTEND_CONTAINER" test -d "$SITES_PATH"
docker exec "$BACKEND_CONTAINER" test -d "$SITES_PATH/$SITE_NAME" || {
  echo "Site directory $SITES_PATH/$SITE_NAME does not exist. Create it first with:"
  echo "  docker exec $BACKEND_CONTAINER bench new-site $SITE_NAME --admin-password admin --db-root-password \$DB_ROOT_PASSWORD"
  exit 1
}

# Find backup files
DB_DUMP_BASENAME="$(docker exec "$BACKEND_CONTAINER" bash -lc "find '$BACKUP_MOUNT_PATH' -maxdepth 1 -type f -name '*-database.sql.gz' | head -n1 | xargs -r basename")"
PUBLIC_TAR_BASENAME="$(docker exec "$BACKEND_CONTAINER" bash -lc "find '$BACKUP_MOUNT_PATH' -maxdepth 1 -type f -name '*-files.tar' ! -name '*-private-files.tar' | head -n1 | xargs -r basename")"
PRIVATE_TAR_BASENAME="$(docker exec "$BACKEND_CONTAINER" bash -lc "find '$BACKUP_MOUNT_PATH' -maxdepth 1 -type f -name '*-private-files.tar' | head -n1 | xargs -r basename")"
SITE_CONFIG_BASENAME="$(docker exec "$BACKEND_CONTAINER" bash -lc "find '$BACKUP_MOUNT_PATH' -maxdepth 1 -type f -name '*-site_config_backup.json' | head -n1 | xargs -r basename")"

for f in "$DB_DUMP_BASENAME" "$PUBLIC_TAR_BASENAME" "$PRIVATE_TAR_BASENAME" "$SITE_CONFIG_BASENAME"; do
  [[ -n "$f" ]] || { echo "Missing expected backup artifact under BACKUP_MOUNT_PATH"; exit 1; }
done

echo "  Found: $DB_DUMP_BASENAME"
echo "  Found: $PUBLIC_TAR_BASENAME"
echo "  Found: $PRIVATE_TAR_BASENAME"
echo "  Found: $SITE_CONFIG_BASENAME"

# Extract encryption key
ENCRYPTION_KEY="$(
  docker exec \
    -e BACKUP_MOUNT_PATH="$BACKUP_MOUNT_PATH" \
    -e SITE_CONFIG_BASENAME="$SITE_CONFIG_BASENAME" \
    "$BACKEND_CONTAINER" \
    python3 -c 'import json, os; backup_path=os.environ["BACKUP_MOUNT_PATH"]; config_name=os.environ["SITE_CONFIG_BASENAME"]; p=backup_path+"/"+config_name; print(json.load(open(p)).get("encryption_key",""))'
)"
[[ -n "$ENCRYPTION_KEY" ]] || { echo "Missing encryption_key in site_config backup"; exit 1; }
echo "  Found encryption key: ${ENCRYPTION_KEY:0:8}..."

# [2/9] Restore database and files
echo "[2/9] Restore database and files"
docker exec \
  -e SITE_NAME="$SITE_NAME" \
  -e DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
  -e BACKUP_MOUNT_PATH="$BACKUP_MOUNT_PATH" \
  -e DB_DUMP_BASENAME="$DB_DUMP_BASENAME" \
  -e PUBLIC_TAR_BASENAME="$PUBLIC_TAR_BASENAME" \
  -e PRIVATE_TAR_BASENAME="$PRIVATE_TAR_BASENAME" \
  "$BACKEND_CONTAINER" \
  bash -lc '
    bench --site "$SITE_NAME" restore \
      "$BACKUP_MOUNT_PATH/$DB_DUMP_BASENAME" \
      --with-private-files "$BACKUP_MOUNT_PATH/$PRIVATE_TAR_BASENAME" \
      --with-public-files "$BACKUP_MOUNT_PATH/$PUBLIC_TAR_BASENAME" \
      --db-root-password "$DB_ROOT_PASSWORD"
  '

# [3/9] Restore encryption key
echo "[3/9] Restore encryption key into site_config.json"
docker exec \
  -e SITE_NAME="$SITE_NAME" \
  -e SITES_PATH="$SITES_PATH" \
  -e ENCRYPTION_KEY="$ENCRYPTION_KEY" \
  "$BACKEND_CONTAINER" \
  bash -lc '
    python3 - <<PY
import json, os, pathlib
path = pathlib.Path(os.environ["SITES_PATH"]+"/"+os.environ["SITE_NAME"]+"/site_config.json")
data = json.loads(path.read_text())
data["encryption_key"] = os.environ["ENCRYPTION_KEY"]
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
print(f"Encryption key restored to {path}")
PY
  '

# Verify encryption key
RESTORED_KEY=$(docker exec "$BACKEND_CONTAINER" python3 -c "import json; print(json.load(open('$SITES_PATH/$SITE_NAME/site_config.json')).get('encryption_key',''))")
[[ "$RESTORED_KEY" == "$ENCRYPTION_KEY" ]] || { echo "Failed to restore encryption_key"; exit 1; }
echo "  Encryption key verified"

# [4/9] Post-restore maintenance
echo "[4/9] Post-restore maintenance"
if [[ "$RUN_MIGRATE" == "1" ]]; then
  echo "  Running migrate..."
  docker exec "$BACKEND_CONTAINER" bench --site "$SITE_NAME" migrate
fi
echo "  Clearing cache..."
docker exec "$BACKEND_CONTAINER" bench --site "$SITE_NAME" clear-cache
if [[ "$ENABLE_SCHEDULER" == "1" ]]; then
  echo "  Enabling scheduler..."
  docker exec "$BACKEND_CONTAINER" bench --site "$SITE_NAME" enable-scheduler
fi

# [5/9] Set current site and domain routing
echo "[5/9] Set current site and domain routing"
docker exec "$BACKEND_CONTAINER" bash -lc "printf '%s\n' '$SITE_NAME' > '$SITES_PATH/currentsite.txt'"
docker exec "$FRONTEND_CONTAINER" bash -lc "printf '%s\n' '$SITE_NAME' > '$SITES_PATH/currentsite.txt'"
echo "  Set default site: $SITE_NAME"

if [[ "$PUBLIC_DOMAIN" != "$SITE_NAME" ]]; then
  docker exec "$BACKEND_CONTAINER" ln -sfn "$SITE_NAME" "$SITES_PATH/$PUBLIC_DOMAIN"
  docker exec "$FRONTEND_CONTAINER" ln -sfn "$SITE_NAME" "$SITES_PATH/$PUBLIC_DOMAIN"
  echo "  Created symlink: $SITES_PATH/$PUBLIC_DOMAIN -> $SITE_NAME"
fi

# [6/9] Reset Administrator password
echo "[6/9] Administrator password"
if [[ "$RESET_ADMIN_PASSWORD" == "1" ]]; then
  [[ -n "$ADMIN_PASSWORD" ]] || { echo "ADMIN_PASSWORD is required when RESET_ADMIN_PASSWORD=1"; exit 1; }
  docker exec "$BACKEND_CONTAINER" bench --site "$SITE_NAME" set-admin-password "$ADMIN_PASSWORD"
  echo "  Password reset to: $ADMIN_PASSWORD"
else
  echo "  Skipped (use RESET_ADMIN_PASSWORD=1 and ADMIN_PASSWORD=... to reset)"
fi

# [7/9] Update ingress Host header
echo "[7/9] Ingress configuration"
if [[ -n "$INGRESS_CONFIG" ]]; then
  cp "$INGRESS_CONFIG" "${INGRESS_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

  # Portable sed (Linux + macOS)
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -E -i '' "s#proxy_set_header Host [^;]+;#proxy_set_header Host ${PUBLIC_DOMAIN};#" "$INGRESS_CONFIG"
  else
    sed -E -i "s#proxy_set_header Host [^;]+;#proxy_set_header Host ${PUBLIC_DOMAIN};#" "$INGRESS_CONFIG"
  fi

  echo "  Updated $INGRESS_CONFIG with Host: $PUBLIC_DOMAIN"

  if [[ -n "$INGRESS_RESTART_CMD" ]]; then
    bash -lc "$INGRESS_RESTART_CMD"
    echo "  Ingress restarted"
  else
    echo "  Ingress config updated. Restart/reload your ingress manually."
  fi
else
  echo "  Skipped (set INGRESS_CONFIG to update nginx)"
fi

# [8/9] Cleanup
echo "[8/9] Cleanup"
if [[ "${CLEANUP_BACKUP:-0}" == "1" && "${BACKUP_WAS_COPIED:-0}" == "1" ]]; then
  docker exec "$BACKEND_CONTAINER" rm -rf "$BACKUP_MOUNT_PATH"
  echo "  Removed backup from container: $BACKUP_MOUNT_PATH"
else
  echo "  Skipped (backup was pre-mounted or CLEANUP_BACKUP=0)"
fi

# [9/9] Summary
echo
echo "=============================================="
echo "Restore complete!"
echo "=============================================="
echo "URL:      http://$PUBLIC_DOMAIN"
echo "Username: Administrator"
if [[ "$RESET_ADMIN_PASSWORD" == "1" ]]; then
  echo "Password: $ADMIN_PASSWORD"
fi
echo
echo "Validation checklist:"
echo "  [ ] Site opens on http://$PUBLIC_DOMAIN"
echo "  [ ] Administrator login works"
echo "  [ ] Key business data is present"
echo "  [ ] Scheduler is enabled (check with: bench --site $SITE_NAME list-scheduled-jobs)"
echo "  [ ] Proxy forwards Host: $PUBLIC_DOMAIN"
echo "=============================================="
