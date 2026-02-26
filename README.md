# System Infrastructure

A production-ready, reusable infrastructure platform for multi-project Docker servers. Provides centralized logging, reverse proxy, and project isolation out of the box.

## Features

- **Caddy Reverse Proxy**: Automatic HTTPS, HTTP/3 support, per-project subdomains
- **Centralized Logging**: Seq + Vector stack
- **Multi-Project Isolation**: Separate Docker networks per project, shared infrastructure
- **Per-Project Log Access**: Each project gets its own `syslog.<project>.com` subdomain
- **Automatic Container Discovery**: Vector auto-discovers containers and extracts labels
- **Powerful Log Querying**: Seq provides a modern UI for searching and analyzing logs

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
┌─────────────┐
│    Seq      │ ◄── Port 80 (Log Server & UI)
│ (Log Store  │
│  + Query UI)│
└──────┬──────┘
       │
       ▲
┌──────┴──────┐
│   Vector    │
│(Log Collect)│
└──────┬──────┘
       │
       ▼
┌─────────────────────────────┐
│     Docker Containers       │
│ (projecta-backend, etc.)     │
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
2. **Generate secure passwords** - Create strong 32-character passwords for Seq and Caddy
3. **Generate bcrypt hash** - Create the password hash for Caddy basic auth
4. **Create .env file** - Configure all environment variables automatically
5. **Create config/projects.json** - Set up your project list
6. **Create directories** - Set up all required directories with correct ownership
7. **Display credentials** - Show generated passwords (save them securely!)

After running, you'll see output like:

```
==============================================================================
                        IMPORTANT - SAVE THESE CREDENTIALS
==============================================================================

Seq:
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

    reverse_proxy system-seq:80 {
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
| Generate Seq password | `openssl rand -base64 32` |
| Generate Caddy password | `openssl rand -base64 32` |
| Generate bcrypt hash | `docker run --rm caddy:2-alpine caddy hash-password` |
| Create .env | `cp .env.example .env && nano .env` |
| Create config/projects.json | `cp config/projects.example.json config/projects.json && nano config/projects.json` |
| Create directories | `mkdir -p caddy/data caddy/config logging/seq/data` |

---

## Adding a New Project

### Step 1: Update config/projects.json

```bash
# Edit projects.json
nano config/projects.json

# Add your new project
{
  "projects": ["projecta", "projectb", "newproject"]
}
```

### Step 2: Add Caddyfile Block

Add to `Caddyfile`:

```caddyfile
syslog.newproject.com {
    import basic_auth

    header_up X-Project "newproject"

    reverse_proxy system-seq:80 {
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

Vector extracts:
- `project`: Everything before the first hyphen
- `service`: Everything after the first hyphen
- `container`: Full container name

---

## Accessing Logs

### Via Seq UI

1. Go to `https://syslog.<project>.com`
2. Enter basic auth credentials
3. Use the search bar to query logs

### Query Examples

```
# All logs for a project
project=projecta

# Errors only
project=projecta AND level=error

# Specific service
project=projecta AND service=backend

# Search content
project=projecta AND "error"

# Time range filter
project=projecta AND @t > -24h
```

---

## Password Management

### Rotate Seq Password

```bash
# Update .env
nano .env  # Change SEQ_ADMIN_PASSWORD

# Restart Seq
docker compose restart seq
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

# Seq
curl -s http://localhost:80/health

# Vector
docker exec system-vector vector validate --no-environment
```

### Check Logs are Flowing

```bash
# Check Vector logs
docker logs system-vector

# Check Seq is receiving logs
# Visit https://syslog.<project>.com and check for incoming logs
```

---

## Troubleshooting

### Logs Not Appearing

1. **Check container naming**:
   ```bash
   docker ps --format "{{.Names}}"
   # Should show: projectname-servicename
   ```

2. **Check Vector**:
   ```bash
   docker logs system-vector
   ```

3. **Check Seq**:
   ```bash
   docker logs system-seq
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
# Check Seq data size
du -sh logging/seq/data

# Configure retention in Seq settings UI
```

---

## Configuration Reference

### Environment Variables (.env)

| Variable | Description | Default |
|----------|-------------|---------|
| `SEQ_ADMIN_PASSWORD` | Seq admin password | Generated by init.sh |
| `SEQ_API_KEY` | API key for remote log ingestion | (empty) |
| `CADDY_BASIC_AUTH_HASH` | Bcrypt hash for basic auth | Generated by init.sh |

### config/projects.json

| Field | Description | Example |
|-------|-------------|---------|
| `projects` | Array of project names | `["projecta", "projectb"]` |

### Ports

| Service | Internal Port | Exposed Port |
|---------|---------------|--------------|
| Caddy | 80, 443 | 80, 443 |
| Seq | 80 | Not exposed |
| Vector | 9000 | Not exposed |

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
├── config/
│   ├── settings.json       # System settings (gitignored)
│   ├── settings.example.json
│   ├── projects.json       # Project list (gitignored)
│   └── projects.example.json
├── Caddyfile               # Caddy configuration
├── caddy/
│   ├── data/               # Certificates (gitignored)
│   └── config/             # Caddy config (gitignored)
├── caddy-projects/         # Per-project Caddy configs
├── logging/
│   ├── seq/
│   │   └── data/           # Seq data (gitignored)
│   └── vector/
│       └── vector.toml     # Vector configuration
```

---

## Security Considerations

1. **Never commit `.env`, `config/projects.json`, or `.credentials`** - Contains secrets
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
# Backup Seq data
tar -czf seq-backup.tar.gz logging/seq/data
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
