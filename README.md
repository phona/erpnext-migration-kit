# ERPNext Production Migration Kit

Self-contained kit for deploying and migrating ERPNext with bind mounts.

## Quick Start

```bash
# 1. Copy .env.example to .env and edit
cp .env.example .env
vim .env

# 2. Initialize sites directory
mkdir -p data/sites
ls -1 frappe_docker/apps > data/sites/apps.txt 2>/dev/null || echo -e "frappe\nerpnext" > data/sites/apps.txt
cat > data/sites/common_site_config.json << 'EOF'
{
 "db_host": "db",
 "db_port": 3306,
 "redis_cache": "redis://redis-cache:6379",
 "redis_queue": "redis://redis-queue:6379",
 "redis_socketio": "redis://redis-queue:6379",
 "socketio_port": 9000
}
EOF

# 3. Set permissions
chown -R 1000:1000 data/sites
chown -R 999:999 data/mariadb 2>/dev/null || true

# 4. Start containers
docker compose \
  -f frappe_docker/compose.yaml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.prod.yaml \
  up -d

# 5. Create site
docker exec backend bench new-site YOUR_SITE \
  --admin-password admin \
  --db-root-password YOUR_DB_PASSWORD \
  --install-app erpnext
```

## Restore from Backup

```bash
# Copy backup to backups directory
cp -r /path/to/backup backups/20260317

# Run restore
SITE_NAME=your_site_name \
PUBLIC_DOMAIN=erpnext.example.com \
DB_ROOT_PASSWORD=your_password \
BACKUP_HOST_PATH=$(pwd)/backups/20260317 \
BACKEND_CONTAINER=backend \
FRONTEND_CONTAINER=frontend \
RESET_ADMIN_PASSWORD=1 \
ADMIN_PASSWORD=admin \
bash scripts/restore-erpnext-site.sh
```

## Directory Structure

```
erpnext-migration-kit/
├── .env                      # Your configuration (from .env.example)
├── .env.example              # Configuration template
├── frappe_docker/            # frappe_docker repo (submodule, v2.1.1)
│   ├── compose.yaml
│   └── overrides/
├── overrides/
│   └── compose.prod.yaml     # Production bind mounts
├── scripts/
│   └── restore-erpnext-site.sh
├── backups/                  # Backup storage
└── data/
    ├── sites/                # Site files
    ├── mariadb/              # Database
    └── redis-queue/          # Redis data
```

## Version Info

| Component | Version |
|-----------|---------|
| frappe_docker | v2.1.1 |
| ERPNext Image | Set via `ERPNEXT_VERSION` in .env |

## Common Commands

```bash
# Start
docker compose -f frappe_docker/compose.yaml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.prod.yaml \
  up -d

# Stop
docker compose -f frappe_docker/compose.yaml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.prod.yaml \
  down

# Logs
docker compose logs -f backend

# Bench commands
docker exec backend bench --site SITE_NAME clear-cache
docker exec backend bench --site SITE_NAME migrate
docker exec backend bench --site SITE_NAME enable-scheduler
```

## Backup

```bash
# Simple backup with bind mounts
tar czf erpnext-backup-$(date +%Y%m%d).tar.gz data/
```

## Clone This Kit for New Server

```bash
# Clone with submodule
git clone --recurse-submodules \
  https://github.com/yourorg/erpnext-migration-kit.git

# Or if already cloned:
git submodule update --init --recursive
```
