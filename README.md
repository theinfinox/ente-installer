# The Fail-Safe Guide to Self-Hosting Ente (Photos & Auth)

> **Goal:** A complete, production-hardened guide to self-hosting **Ente** (an end-to-end encrypted, zero-knowledge alternative to Google Photos and Apple Photos).  
> Designed to be **100% fail-safe**: every known race condition, database migration lock, CORS issue, S3 endpoint mismatch, and port collision is prevented by design.

---

## Table of Contents
0. [⚡ Quickest Path: The One-Command Installer (`install.sh`)](#-quickest-path-the-one-command-installer-installsh)
1. [Architecture & How Ente Works](#1-architecture--how-ente-works)
2. [Pre-Flight Verification](#2-pre-flight-verification)
3. [Step 1: Directory Setup](#step-1-directory-setup)
4. [Step 2: Automated Secret Generation](#step-2-automated-secret-generation)
5. [Step 3: Configuration Files (`museum.yaml` & `compose.yaml`)](#step-3-configuration-files)
6. [Step 4: Launching & Verifying the Stack](#step-4-launching--verifying-the-stack)
7. [Step 5: Account Creation & OTP Retrieval](#step-5-account-creation--otp-retrieval)
8. [Step 6: Unlocking 10 TB / Unlimited Storage](#step-6-unlocking-10-tb--unlimited-storage)
9. [Step 7: Remote Access & Mobile Apps (iOS / Android)](#step-7-remote-access--mobile-apps-ios--android)
10. [Troubleshooting & Emergency Recovery Matrix](#10-troubleshooting--emergency-recovery-matrix)
11. [Backup & Maintenance Playbook](#11-backup--maintenance-playbook)

---

## ⚡ Quickest Path: The One-Command Installer (`install.sh`)

If you want an automated, fail-safe installation that handles all pre-flight checks, port scanning, secrets generation, race condition prevention, and 10 TB quota allocation automatically, use the bundled installer:

```bash
chmod +x install.sh
./install.sh
```

> [!TIP]
> **Zero-Risk Dry-Run:** You can test pre-flight checks, port scanning, and configuration generation without pulling any Docker images or starting containers:
> ```bash
> ./install.sh --dry-run
> ```

### What `install.sh` Does Automatically:
* **Operating System & Architecture Check:** Strictly verifies Linux (including WSL2 on Windows); cleanly rejects native Windows shells (Git Bash / MSYS) with actionable guidance.
* **Pre-Flight Hardware, Disk & Port Auditing:** Checks architecture, available RAM and disk space (warns if < 3 GB free), auto-installs Docker/Compose if missing (with user approval), and scans ports to avoid collisions (e.g. automatically moving Web UI from contested `:3000` to `:3004`).
* **Container Conflict & Database Desync Prevention:** Detects existing `ente-*` containers and old database folders; prompts to safely clean up or backup to eliminate container name collisions and password desyncs.
* **Self-Healing Migration Watchdog:** Detects and clears interrupted "dirty" migration flags (`schema_migrations.dirty = true`) on the fly, resuming startup automatically.
* **Network & Domain Sanitization:** Warns against using `127.0.0.1` loopback in LAN mode, sanitizes user domain input (stripping schemes, slashes, and whitespace), and detects active host firewalls (UFW).
* **Cryptographic Vault:** Generates high-entropy secrets and stores them in `credentials.env` (`chmod 600`).
* **Zero-Lock Database Boot:** Applies the hardened Postgres healthcheck parameters (`start_period: 60s`, `retries: 20`) to eliminate the "dirty migration" lock.
* **Storage Auto-Upgrade (1-Hour Window):** Launches a background watcher that automatically boosts your account to **10 TB** upon signup.
* **Sudo-Aware Helper Tools:** Creates `./get-otp.sh`, `./set-quota.sh <SIZE>`, and `./reconfigure.sh` in your install directory, automatically detecting Docker permissions.
* **Existing Deployment Safeguard:** If an active Ente instance is detected in the target directory, it warns you explicitly and offers to launch `./reconfigure.sh` instead of overwriting existing credentials.
* **Reverse Proxy Snippets:** Generates ready-to-use Caddy and Cloudflare Zero Trust configurations if a domain is specified.
* **Full Execution Timeline Logging (`ente-installer.log`):** Records every command, system spec, port allocation, Docker pull/up stdout/stderr, and container diagnostic trace to `ente-installer.log` for instant auditing and troubleshooting.

---

## 1. Architecture & How Ente Works

Ente is not a simple monolithic container. Understanding the data flow prevents 99% of user configuration errors:

```text
[ Client Device ] (Phone / PC Browser)
       │
       │ 1. End-to-End Encryption happens locally on device
       │ 2. Authenticates & requests presigned upload URL
       ▼
 [ Museum API ] (:8080) ────────────> [ PostgreSQL 15 ] (Metadata & Accounts)
       │
       │ 3. Returns presigned S3 URL (:3200) pointing to MinIO
       ▼
[ MinIO / Silo ] (:3200) <─── (Client directly uploads encrypted blobs here)
       ▲
       │
 [ Socat Bridge ] (Enables internal Docker routing between Museum and MinIO)
```

### Critical Architecture Rules:
1. **Direct-to-S3 Uploads:** The client browser/phone talks to the Museum API (`:8080`) only for metadata and authentication, but **streams encrypted photo files directly to MinIO (`:3200`)**.
2. **End-to-End Encryption (E2EE):** All thumbnail generation, facial recognition, and encryption occur on your client device. The server only stores encrypted ciphertexts and never sees unencrypted photos.

---

## 2. Pre-Flight Verification

Run these checks on your host system before creating files:

### 1. Verify Docker & Compose Support
Ente requires Docker with Compose v2.28 or newer:
```bash
docker --version && docker compose version
```

### 2. Check for Port Collisions
Ente uses the following ports by default. Run this command to check if any are already occupied:
```bash
# Linux / macOS:
sudo ss -tulpn | grep -E ':(3000|3002|3004|3200|8080)\b'
# Or:
sudo lsof -i :3000,3002,3004,3200,8080
```
* **Port `3000`:** Often occupied by Grafana, AdGuard, Gitea, or Node.js apps. In this guide, we remap the web UI to **`3004`** to prevent collisions.
* **Port `8080`:** Used by the Museum API. If occupied, remap the host port (e.g., `8088:8080`).
* **Port `3200`:** MinIO S3 API. Must be reachable by clients.

---

## Step 1: Directory Setup

Create an isolated directory structure with explicit persistent volume paths:

```bash
mkdir -p ~/ente/data ~/ente/pg_data ~/ente/minio_data
cd ~/ente
```

---

## Step 2: Automated Secret Generation

Ente requires high-entropy cryptographic keys for database passwords, JWT tokens, and internal envelope encryption. 

Run this command directly in your terminal to output clean, pre-formatted credentials:

```bash
cat <<EOF
--- COPY AND SAVE THESE VALUES ---
PG_PASS=$(head -c 21 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
MINIO_USER=minio-user-$(head -c 6 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
MINIO_PASS=$(head -c 21 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
KEY_ENC=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
KEY_HASH=$(head -c 64 /dev/urandom | base64 | tr -d '\n')
JWT_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_')
-----------------------------------
EOF
```

---

## Step 3: Configuration Files

### 1. `museum.yaml`
Create `~/ente/museum.yaml` with your generated keys:

> [!CAUTION]
> **The #1 Gotcha:** Replace `<SERVER_ADDRESS>` below with either:
> - Your server's local network IP (e.g., `192.168.1.100`), **OR**
> - Your external domain name (e.g., `s3.yourdomain.com`).
> **Never set `endpoint` to `localhost:3200`** if accessing from a phone or another computer, or photo uploads will fail with a connection error.

```yaml
db:
  host: postgres
  port: 5432
  name: ente_db
  user: pguser
  password: "YOUR_PG_PASS"

s3:
  are_local_buckets: true
  use_path_style_urls: true
  b2-eu-cen:
    key: "YOUR_MINIO_USER"
    secret: "YOUR_MINIO_PASS"
    endpoint: "<SERVER_ADDRESS>:3200"
    region: "eu-central-2"
    bucket: "b2-eu-cen"
  wasabi-eu-central-2-v3:
    key: "YOUR_MINIO_USER"
    secret: "YOUR_MINIO_PASS"
    endpoint: "<SERVER_ADDRESS>:3200"
    region: "eu-central-2"
    bucket: "wasabi-eu-central-2-v3"
    compliance: false
  scw-eu-fr-v3:
    key: "YOUR_MINIO_USER"
    secret: "YOUR_MINIO_PASS"
    endpoint: "<SERVER_ADDRESS>:3200"
    region: "eu-central-2"
    bucket: "scw-eu-fr-v3"

apps:
  public-albums: http://<SERVER_ADDRESS>:3002
  cast: http://<SERVER_ADDRESS>:3004
  accounts: http://<SERVER_ADDRESS>:3001

key:
  encryption: "YOUR_KEY_ENC"
  hash: "YOUR_KEY_HASH"

jwt:
  secret: "YOUR_JWT_SECRET"
```

---

### 2. `compose.yaml`
Create `~/ente/compose.yaml`. This file incorporates a **hardened PostgreSQL healthcheck** that eliminates the fatal database migration lock:

```yaml
services:
  museum:
    image: ghcr.io/ente/server
    container_name: ente-museum
    restart: unless-stopped
    ports:
      - "8080:8080" # Core API
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./museum.yaml:/museum.yaml:ro
      - ./data:/data:ro
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/ping"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

  socat:
    image: alpine/socat
    container_name: ente-socat
    restart: unless-stopped
    network_mode: service:museum
    depends_on:
      - museum
    command: "TCP-LISTEN:3200,fork,reuseaddr TCP:minio:3200"

  web:
    image: ghcr.io/ente/web
    container_name: ente-web
    restart: unless-stopped
    ports:
      - "3004:3000" # Remapped from :3000 to prevent host port collisions
      - "3002:3002" # Public shared albums
    environment:
      # Tell the web frontend where to reach the backend API
      ENTE_API_ORIGIN: http://<SERVER_ADDRESS>:8080
      ENTE_ALBUMS_ORIGIN: http://<SERVER_ADDRESS>:3002

  postgres:
    image: postgres:15
    container_name: ente-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: pguser
      POSTGRES_PASSWORD: "YOUR_PG_PASS"
      POSTGRES_DB: ente_db
    # FAIL-SAFE: 60s start_period prevents Docker from killing Postgres during initdb
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -q -d ente_db -U pguser"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 60s
    volumes:
      - ./pg_data:/var/lib/postgresql/data

  minio:
    image: pgsty/silo
    container_name: ente-minio
    restart: unless-stopped
    ports:
      - "3200:3200" # S3 API endpoint
    environment:
      MINIO_ROOT_USER: "YOUR_MINIO_USER"
      MINIO_ROOT_PASSWORD: "YOUR_MINIO_PASS"
    command: server /data --address ":3200" --console-address ":3201"
    volumes:
      - ./minio_data:/data
    # Automatically provisions the 3 storage buckets Ente requires
    post_start:
      - command: |
          sh -c '
          while ! mc alias set h0 http://minio:3200 YOUR_MINIO_USER YOUR_MINIO_PASS 2>/dev/null
          do
            echo "Waiting for storage engine..."
            sleep 0.5
          done

          cd /data
          mc mb -p b2-eu-cen
          mc mb -p wasabi-eu-central-2-v3
          mc mb -p scw-eu-fr-v3
          '
```

---

## Step 4: Launching & Verifying the Stack

1. **Start the containers:**
   ```bash
   docker compose up -d
   ```

2. **Verify PostgreSQL initializes and passes health checks:**
   ```bash
   docker ps --filter name=ente-postgres
   # Output should say: Up ... (healthy)
   ```

3. **Follow Museum migration logs:**
   On initial boot, Museum applies ~151 database migrations (takes ~30–60 seconds). Stream the logs:
   ```bash
   docker logs -f ente-museum
   ```
   Wait until you see:
   ```text
   INFO[...] We have lift-off. 🚀
   INFO[...] starting server on port 8080
   ```
   Press `Ctrl+C` to exit logs.

4. **Test the API response:**
   ```bash
   curl -i http://localhost:8080/ping
   # Should return: {"message":"pong"}
   ```

---

## Step 5: Account Creation & OTP Retrieval

1. In your browser, navigate to:
   ```text
   http://<SERVER_ADDRESS>:3004
   ```
2. Click **Get Started** and enter your email address.
3. Because external SMTP is unconfigured by default, Ente writes the verification code directly to the container logs. Retrieve it with:
   ```bash
   docker logs --tail 50 ente-museum | grep -i "code"
   ```
4. Enter the 6-digit code in the browser and choose your master password.
5. **Download / Record your Recovery Key.** Ente is zero-knowledge encrypted: if you lose both your master password and recovery key, data recovery is mathematically impossible.
6. When presented with the **"Choose your plan / 10 GB free forever"** screen:
   * **Click "Continue with free plan"**.
   * *Why this appears:* The open-source web image shares the cloud onboarding screen. Since billing is disabled on self-hosted instances, clicking this simply finishes your account creation without any cost or subscription.

---

## Step 6: Unlocking 10 TB / Unlimited Storage

By default, Ente initializes accounts with a 10 GB quota in the database. Because this is your own server, you can expand this limit to whatever capacity you need (e.g., 10 TB = `10995116277760` bytes).

Run this single SQL command directly on your server:

```bash
docker exec -i ente-postgres psql -U pguser -d ente_db -c \
  "UPDATE subscriptions SET storage = 10995116277760 WHERE user_id = (SELECT user_id FROM users LIMIT 1);"
```

Refresh your web gallery tab and open **Settings** $\rightarrow$ **Account**: your storage quota will now show **10 TB**.

---

## Step 7: Remote Access & Mobile Apps (iOS / Android)

> [!IMPORTANT]
> The official Ente mobile apps (iOS & Android) **strictly require a valid, publicly trusted HTTPS (TLS) certificate**. They reject plain `http://` and self-signed certificates.

> [!TIP]
> **One-Command Migration Utility:** If you already deployed Ente and want to switch from `localhost` to a private LAN IP, or from LAN to a public domain (Cloudflare Tunnel or Caddy), run the reconfiguration helper:
> ```bash
> ./reconfigure.sh
> ```
> It preserves all your passwords, updates endpoints, and reloads Docker automatically with zero data loss.

### Method A: Cloudflare Zero Trust Tunnel (Easiest, Zero Port Forwarding)
If you already use Cloudflare:
1. In your Cloudflare Zero Trust Dashboard, navigate to **Networks** $\rightarrow$ **Tunnels**.
2. Add the following **Public Hostnames**:
   * `photos.yourdomain.com` $\rightarrow$ Service: `HTTP://localhost:3004`
   * `api.yourdomain.com` $\rightarrow$ Service: `HTTP://localhost:8080`
   * `s3.yourdomain.com` $\rightarrow$ Service: `HTTP://localhost:3200`
3. Update `compose.yaml`:
   ```yaml
   environment:
     ENTE_API_ORIGIN: https://api.yourdomain.com
   ```
4. Update `museum.yaml`:
   ```yaml
   s3:
     are_local_buckets: true
     b2-eu-cen:
       endpoint: "s3.yourdomain.com"
   ```
5. Restart: `docker compose up -d`

---

### Method B: Caddy Reverse Proxy (Automatic Let's Encrypt SSL)
If using a standard reverse proxy with ports 80/443 forwarded to your server, add this to your `Caddyfile`:

```caddy
photos.yourdomain.com {
    reverse_proxy localhost:3004
}

api.yourdomain.com {
    reverse_proxy localhost:8080
}

s3.yourdomain.com {
    reverse_proxy localhost:3200
}
```

---

### How to Connect the Mobile App
1. Install **Ente Photos** from the Apple App Store or Google Play Store.
2. Open the app to the initial screen.
3. **The Hidden Developer Menu:** Tap the **Ente logo** at the top **7 times in a row**.
4. A hidden configuration field appears: enter your custom API endpoint:
   ```text
   https://api.yourdomain.com
   ```
5. Log in with your email and master encryption password.

---

## 10. Troubleshooting & Emergency Recovery Matrix

> [!TIP]
> **Automated Execution Timeline:** If you deployed via `install.sh` and encountered an error or unexpected behavior, inspect the installer log:
> ```bash
> cat ~/ente/ente-installer.log
> # Or follow live:
> tail -f ~/ente/ente-installer.log
> ```
> It contains chronological timestamps, port scans, Docker pull and startup outputs, and container logs dumped automatically upon failure.

| Symptom / Error | Root Cause | Fail-Safe Fix |
| :--- | :--- | :--- |
| **`Conflict. The container name "/ente-*" is already in use`** | Containers from an earlier setup attempt exist (running or stopped). | Remove conflicting containers: `docker rm -f ente-museum ente-web ente-postgres ente-minio ente-socat`. |
| **`password authentication failed for user "pguser"`** | `./pg_data` already existed with an old database initialized under a different password. | Back up old data (`mv ~/ente/pg_data ~/ente/pg_data_bak`) so PostgreSQL can run `initdb` with your new `credentials.env` password. |
| **`Upload failed` on photo uploads** | `endpoint` in `museum.yaml` is set to `localhost:3200`. The client browser is trying to upload to its own machine. | Change `endpoint: "<SERVER_IP_OR_DOMAIN>:3200"` in `museum.yaml` and run `docker restart ente-museum`. |
| **`container ente-postgres is unhealthy`** | Postgres took longer than 30s to initialize `initdb`. | Set `start_period: 60s` and `retries: 20` under `postgres.healthcheck` in `compose.yaml`. |
| **Museum restarts in a loop or hangs** | An interrupted migration left a "dirty" database lock (`version: X, dirty: t`). | Check lock: `docker exec -i ente-postgres psql -U pguser -d ente_db -c "SELECT version, dirty FROM schema_migrations;"`. If dirty, clear it: `docker exec -i ente-postgres psql -U pguser -d ente_db -c "UPDATE schema_migrations SET dirty = false;"` or recreate empty DB if no photos exist yet. |
| **Web UI shows "Network Error" on login** | `ENTE_API_ORIGIN` in `compose.yaml` is misconfigured or unreachable from the client browser. | Ensure `ENTE_API_ORIGIN` points to `http://<SERVER_IP>:8080` (or `https://api.yourdomain.com`). Run `docker compose up -d web`. |
| **Mobile app refuses to connect** | Plain HTTP or self-signed certificate used. Mobile client requires public CA TLS. | Put Cloudflare Tunnel or Caddy/Nginx with a valid Let's Encrypt certificate in front of the API. |
| **Verification OTP not received in email** | SMTP email server is not configured in `museum.yaml`. | Run `docker logs --tail 50 ente-museum \| grep -i "code"` to read the OTP directly from standard output. |

---

## 11. Backup & Maintenance Playbook

### Backing Up Ente
To create a complete, consistent backup of your entire instance:

1. **Backup Database:**
   ```bash
   docker exec ente-postgres pg_dump -U pguser ente_db > ~/ente-db-backup-$(date +%F).sql
   ```
2. **Backup Encrypted Photos:**
   Copy the `~/ente/minio_data` folder (or use `rclone` to mirror to an offsite location/NAS). Because all files are encrypted client-side with your master key, even unencrypted cloud backups of this folder are zero-knowledge secure.
3. **Backup Configuration Keys:**
   Securely store copies of `museum.yaml` and `compose.yaml`.

### Updating Container Images Safely
```bash
cd ~/ente
docker compose pull
docker compose up -d
```
Docker will recreate only the updated containers while preserving all persistent data in `./pg_data` and `./minio_data`.
