# ERPNext Production Migration Kit

Self-contained kit for deploying and migrating ERPNext with bind mounts.

## Quick Start

### One-Line Deploy & Restore

```bash
./scripts/deploy-and-restore.sh \
  --data-root /opt/erpnext/data \
  --backup-path /path/to/backup \
  --site-name your_site_name \
  --domain erpnext.example.com \
  --db-password your_password \
  --admin-password admin
```

### Step-by-Step

```bash
# 1. Initialize .env with data root
./scripts/init-env.sh /opt/erpnext/data

# 2. Edit .env (set DB_PASSWORD, etc.)
vim .env

# 3. Start containers
docker compose \
  -f frappe_docker/compose.yaml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.prod.yaml \
  up -d

# 4. Create site
docker exec backend bench new-site SITE_NAME \
  --admin-password admin \
  --db-root-password DB_PASSWORD \
  --install-app erpnext

# 5. Restore backup
./scripts/restore-erpnext-site.sh
```

## Directory Structure

```
erpnext-migration-kit/
├── scripts/
│   ├── deploy-and-restore.sh   # One-line deploy + restore
│   ├── init-env.sh             # Initialize .env from DATA_ROOT
│   └── restore-erpnext-site.sh # Restore backup only
├── overrides/
│   └── compose.prod.yaml       # Production bind mounts
├── frappe_docker/              # Submodule (v2.1.1)
├── .env.example                # Configuration template
└── README.md
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `deploy-and-restore.sh` | Complete deploy + restore in one command |
| `init-env.sh` | Generate `.env` from `DATA_ROOT` |
| `restore-erpnext-site.sh` | Restore backup to existing site |

## deploy-and-restore.sh Options

| Flag | Description | Required |
|------|-------------|----------|
| `--data-root` | Data storage path | ✅ |
| `--backup-path` | Backup directory | ✅ |
| `--site-name` | Site name from backup | ✅ |
| `--domain` | Public domain | ✅ |
| `--db-password` | MariaDB root password | ✅ |
| `--admin-password` | ERPNext admin password | ❌ (default: admin) |
| `--erpnext-version` | Docker image tag | ❌ (default: v15.95.2) |
| `--http-port` | HTTP port | ❌ (default: 9100) |

## Data Storage

```
DATA_ROOT/
├── sites/           # Site files, configs
├── mariadb/         # Database
└── redis-queue/     # Redis data
```

## Backup

```bash
# Simple backup with bind mounts
tar czf erpnext-backup-$(date +%Y%m%d).tar.gz /opt/erpnext/data/
```

## Clone This Kit

```bash
git clone --recurse-submodules \
  git@github.com:phona/erpnext-migration-kit.git
```

## Common Commands

```bash
# Start
docker compose -f frappe_docker/compose.yaml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.prod.yaml up -d

# Stop
docker compose down

# Logs
docker compose logs -f backend

# Bench commands
docker exec backend bench --site SITE_NAME clear-cache
docker exec backend bench --site SITE_NAME migrate
docker exec backend bench --site SITE_NAME enable-scheduler
```

## Version Info

| Component | Version |
|-----------|---------|
| frappe_docker | v2.1.1 (submodule) |
| ERPNext Image | v15.95.2 |
