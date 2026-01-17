# System Infrastructure

A production-ready, reusable infrastructure platform for multi-project Docker servers. Provides centralized logging, reverse proxy, and project isolation out of the box.

## Features

- **Caddy Reverse Proxy**: Automatic HTTPS, HTTP/3 support, per-project subdomains
- **Centralized Logging**: Grafana + Loki + Promtail stack
- **Multi-Project Isolation**: Separate Docker networks per project, shared infrastructure
- **Per-Project Log Access**: Each project gets its own `syslog.<project>.com` subdomain
- **Automatic Container Discovery**: Promtail auto-discovers containers and extracts labels
- **Pre-built Dashboards**: Project logs and cron job monitoring dashboards included

## Architecture

```
Internet
    │
    ▼
┌─────────────┐
│   Caddy     │ ◄── Ports 80/443
│ (Reverse    │
│  Proxy)     │
└─────┬───────┘
      │
      ▼
┌─────────────┐      ┌─────────────┐
│  Grafana    │ ◄──► │    Loki     │
│ (Dashboard) │      │ (Log Store) │
└─────────────┘      └──────┬──────┘
                            │
                            ▲
                     ┌──────┴──────┐
                     │  Promtail   │
                     │(Log Collect)│
                     └──────┬──────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │     Docker Containers       │
              │ (projecta-backend, etc.)       │
              └─────────────────────────────┘
```

## Quick Start

### Prerequisites

- Ubuntu Server (or any Linux with Docker)
- Docker and Docker Compose installed
- Root or sudo access

### Step 1: Run the Initialization Script (REQUIRED)

> **IMPORTANT**: You MUST run `init.sh` before starting services. This script sets up everything automatically.

```bash
cd ~/system-infras

# Make the script executable
chmod +x init.sh

# Run initialization
./init.sh
```

The `init.sh` script will:

1. **Check system requirements** - Verify Docker is installed and running
2. **Generate secure passwords** - Create strong 32-character passwords for Grafana and Caddy
3. **Generate bcrypt hash** - Create the password hash for Caddy basic auth
4. **Create .env file** - Configure all environment variables automatically
5. **Create projects.env** - Set up your project list (you'll be prompted to enter project names)
6. **Create directories** - Set up all required directories with correct ownership
7. **Display credentials** - Show generated passwords (save them securely!)

After running, you'll see output like:

```
==============================================================================
                        IMPORTANT - SAVE THESE CREDENTIALS
==============================================================================

Grafana:
  URL:      https://syslog.example.com
  Username: admin
  Password: <generated-password>

Caddy Basic Auth:
  Username: admin
  Password: <generated-password>

Credentials also saved to: .credentials
DELETE .credentials after saving passwords elsewhere!
==============================================================================
```

### Step 2: Update DNS

Point your syslog subdomains to your server's IP address:

```
syslog.projecta.com      -> <your-server-ip>
syslog.projectb.com   -> <your-server-ip>
```

### Step 3: Review Caddyfile (Optional)

The default Caddyfile includes blocks for `projecta` and `projectb`. Update if needed:

```bash
nano Caddyfile
```

For each project, ensure there's a block like:

```caddyfile
syslog.yourproject.com {
    import basic_auth

    header_up X-Project "yourproject"

    reverse_proxy system-grafana:3000 {
        header_up X-Project "yourproject"
    }

    log {
        output file /data/logs/access-yourproject.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
```

### Step 4: Start Services

```bash
# Start the infrastructure
docker compose up -d

# Run bootstrap to create project networks and connect Caddy
./bootstrap.sh
```

### Step 5: Verify

```bash
# Check all services are healthy
docker compose ps

# Check logs
docker compose logs -f

# Test access (after DNS propagation)
curl -I https://syslog.yourproject.com
```

### Step 6: Secure Credentials

```bash
# After saving credentials somewhere safe, delete the credentials file
rm .credentials
```

---

## What init.sh Does (Detailed)

| Task | Manual Equivalent |
|------|-------------------|
| Check Docker | `docker info` |
| Generate Grafana password | `openssl rand -base64 32` |
| Generate Caddy password | `openssl rand -base64 32` |
| Generate bcrypt hash | `docker run --rm caddy:2-alpine caddy hash-password` |
| Create .env | `cp .env.example .env && nano .env` |
| Create projects.env | `cp projects.env.example projects.env && nano projects.env` |
| Create directories | `mkdir -p caddy/data caddy/config logging/grafana/data logging/loki/data` |
| Set Grafana ownership | `sudo chown -R 472:472 logging/grafana/data` |
| Set Loki ownership | `sudo chown -R 10001:10001 logging/loki/data` |

---

## Adding a New Project

### Step 1: Update projects.env

```bash
# Edit projects.env
nano projects.env

# Add your new project
PROJECTS="projecta projectb newproject"
```

### Step 2: Add Caddyfile Block

Add to `Caddyfile`:

```caddyfile
syslog.newproject.com {
    import basic_auth

    header_up X-Project "newproject"

    reverse_proxy system-grafana:3000 {
        header_up X-Project "newproject"
    }

    log {
        output file /data/logs/access-newproject.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
```

### Step 3: Run Bootstrap

```bash
./bootstrap.sh
```

### Step 4: Configure Your Project

In your project's `docker-compose.yml`:

```yaml
services:
  backend:
    container_name: newproject-backend
    labels:
      - "logging=true"
    networks:
      - newproject-net

  cron-worker:
    container_name: newproject-cron-worker
    labels:
      - "logging=true"
    networks:
      - newproject-net

networks:
  newproject-net:
    external: true
```

### Step 5: Set Up DNS

Point `syslog.newproject.com` to your server's IP address.

---

## Container Naming Convention

All containers must follow this naming pattern:

```
{project}-{service}
```

Examples:
- `projecta-backend`
- `projecta-cron-fetch`
- `projectb-api`
- `projectb-worker`

Promtail extracts:
- `project`: Everything before the first hyphen
- `service`: Everything after the first hyphen
- `container`: Full container name

---

## Accessing Logs

### Via Grafana Dashboard

1. Go to `https://syslog.<project>.com`
2. Enter basic auth credentials
3. Navigate to **Dashboards > System > Project Logs**
4. Use the Project/Service/Level dropdowns to filter

### Via Grafana Explore

1. Go to `https://syslog.<project>.com/explore`
2. Select **Loki** datasource
3. Use LogQL queries:

```logql
# All logs for a project
{project="projecta"}

# Errors only
{project="projecta"} | level="error"

# Specific service
{project="projecta", service="backend"}

# Search content
{project="projecta"} |= "error"

# Regex search
{project="projecta"} |~ "user_id=[0-9]+"
```

---

## Password Management

### Rotate Grafana Password

```bash
# Update .env
nano .env  # Change GRAFANA_ADMIN_PASSWORD

# Restart Grafana
docker compose restart grafana
```

### Rotate Caddy Basic Auth Password

```bash
# Generate new hash
docker run --rm caddy:2-alpine caddy hash-password --plaintext 'new-password'

# Update .env
nano .env  # Change CADDY_BASIC_AUTH_HASH

# Reload Caddy
docker exec system-caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Health Checks

### Check All Services

```bash
docker compose ps

# Expected output: All services should show "healthy"
```

### Check Individual Services

```bash
# Caddy
docker exec system-caddy caddy version

# Grafana
curl -s http://localhost:3000/api/health

# Loki
curl -s http://localhost:3100/ready

# Promtail
curl -s http://localhost:9080/ready
```

### Check Logs are Flowing

```bash
# Query Loki directly
curl -s "http://localhost:3100/loki/api/v1/labels" | jq

# Check for recent logs
curl -s "http://localhost:3100/loki/api/v1/query?query={job=~\".+\"}" | jq
```

---

## Troubleshooting

### Logs Not Appearing

1. **Check container naming**:
   ```bash
   docker ps --format "{{.Names}}"
   # Should show: projectname-servicename
   ```

2. **Check logging label**:
   ```bash
   docker inspect <container> | jq '.[0].Config.Labels'
   # Should include: "logging": "true"
   ```

3. **Check Promtail**:
   ```bash
   docker logs system-promtail
   ```

4. **Check Loki**:
   ```bash
   docker logs system-loki
   ```

### Caddy Certificate Issues

```bash
# Check Caddy logs
docker logs system-caddy

# Validate Caddyfile
docker exec system-caddy caddy validate --config /etc/caddy/Caddyfile

# Force certificate renewal
docker exec system-caddy caddy reload --config /etc/caddy/Caddyfile
```

### Grafana Won't Start

```bash
# Check permissions
ls -la logging/grafana/data

# Fix ownership (Grafana runs as UID 472)
sudo chown -R 472:472 logging/grafana/data
```

### Loki Won't Start

```bash
# Check permissions
ls -la logging/loki/data

# Fix ownership (Loki runs as UID 10001)
sudo chown -R 10001:10001 logging/loki/data
```

### Network Issues

```bash
# List all networks
docker network ls

# Inspect network
docker network inspect projecta-net

# Check Caddy networks
docker inspect system-caddy --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}'
```

### High Disk Usage

```bash
# Check Loki data size
du -sh logging/loki/data

# Retention is set to 14 days by default
# To force compaction, restart Loki
docker compose restart loki
```

---

## Configuration Reference

### Environment Variables (.env)

| Variable | Description | Default |
|----------|-------------|---------|
| `GRAFANA_ADMIN_USER` | Grafana admin username | `admin` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password | Generated by init.sh |
| `GRAFANA_ROOT_URL` | Public URL for Grafana | `https://syslog.<domain>` |
| `CADDY_BASIC_AUTH_HASH` | Bcrypt hash for basic auth | Generated by init.sh |
| `LOKI_RETENTION_HOURS` | Log retention in hours | `336` (14 days) |

### projects.env

| Variable | Description | Example |
|----------|-------------|---------|
| `PROJECTS` | Space-separated list of project names | `"projecta projectb"` |

### Ports

| Service | Internal Port | Exposed Port |
|---------|---------------|--------------|
| Caddy | 80, 443 | 80, 443 |
| Grafana | 3000 | Not exposed |
| Loki | 3100 | Not exposed |
| Promtail | 9080 | Not exposed |

---

## Directory Structure

```
system-infras/
├── docker-compose.yml      # Main compose file
├── init.sh                 # Initialization script (run first!)
├── bootstrap.sh            # Network setup script
├── .env                    # Environment variables (gitignored)
├── .env.example            # Environment template
├── .credentials            # Generated credentials (DELETE after saving!)
├── projects.env            # Project list (gitignored)
├── projects.env.example    # Projects template
├── Caddyfile               # Caddy configuration
├── caddy/
│   ├── data/               # Certificates (gitignored)
│   └── config/             # Caddy config (gitignored)
└── logging/
    ├── loki/
    │   ├── config.yml      # Loki configuration
    │   └── data/           # Loki data (gitignored)
    ├── promtail/
    │   └── config.yml      # Promtail configuration
    └── grafana/
        ├── data/           # Grafana data (gitignored)
        └── provisioning/
            ├── datasources/
            │   └── loki.yml
            └── dashboards/
                ├── default.yml
                └── json/
                    ├── project-logs.json
                    └── cron-monitoring.json
```

---

## Security Considerations

1. **Never commit `.env`, `projects.env`, or `.credentials`** - Contains secrets
2. **Delete `.credentials` after saving passwords** - Don't leave it on the server
3. **Use strong passwords** - init.sh generates 32-character passwords automatically
4. **Rotate credentials regularly** - At least quarterly
5. **Restrict network access** - Only Caddy should be publicly accessible
6. **Keep images updated** - Regularly pull latest images
7. **Monitor for anomalies** - Set up alerting for unusual patterns

---

## Maintenance

### Update Images

```bash
docker compose pull
docker compose up -d
```

### Backup

```bash
# Backup Grafana dashboards and settings
tar -czf grafana-backup.tar.gz logging/grafana/data

# Backup Loki data (if needed)
tar -czf loki-backup.tar.gz logging/loki/data
```

### View Disk Usage

```bash
du -sh logging/*/data caddy/data
```

### Re-run Initialization

If you need to regenerate passwords or fix configuration:

```bash
./init.sh
# It will ask before overwriting existing files
```

---

## License

MIT
