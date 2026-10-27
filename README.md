# Ente Fail-Safe Self-Hosted Installer

> An automated, production-hardened installer and management suite for **Ente Photos & Auth**.  
> Designed to eliminate every known initialization race condition, mobile S3 upload loop, and port collision by design.

---

### Installer Metadata
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-Passing-brightgreen.svg)]()
[![Platform: Linux | WSL2](https://img.shields.io/badge/Platform-Linux%20%7C%20WSL2-orange.svg)]()
[![Docker Compose: >= 2.28](https://img.shields.io/badge/Docker%20Compose-%3E%3D%20v2.28-2496ED?logo=docker&logoColor=white)]()
[![GitHub Stars](https://img.shields.io/github/stars/theinfinox/ente-installer?style=flat&color=yellow)](https://github.com/theinfinox/ente-installer/stargazers)

### Upstream Ente Trust & Compatibility
[![Upstream Project](https://img.shields.io/badge/Upstream-ente%2Fente-10B981?logo=github)](https://github.com/ente/ente)
[![Official Images](https://img.shields.io/badge/Images-Official%20Ente%20GHCR-8A2BE2)]()
[![Encryption: Zero-Knowledge](https://img.shields.io/badge/Security-Zero--Knowledge%20E2EE-success)]()
[![Core License](https://img.shields.io/badge/Core%20License-AGPL--3.0-lightgrey)](https://github.com/ente/ente/blob/main/LICENSE)

---

## What is Ente?

[Ente](https://github.com/ente/ente) is an open-source, end-to-end encrypted (E2EE) cloud storage platform designed as an uncompromised, zero-knowledge alternative to Google Photos and Apple Photos:

* **Client-Side Encryption:** Photos, videos, and album metadata are encrypted on your device using libsodium / XChaCha20-Poly1305 before transmission. The server only stores ciphertext and never sees unencrypted media or master keys.
* **Native Cross-Platform Apps:** Polished client applications for iOS and Android, desktop clients for Linux, macOS, and Windows, and a modern web gallery.
* **Zero-Knowledge 2FA Authenticator:** Ente Auth provides end-to-end encrypted two-factor authentication backups across all your devices.

---

## Independent Community Project Notice

> [!NOTE]
> This repository (`theinfinox/ente-installer`) is an **independent, community-maintained open-source tool** and is **not** officially affiliated with, maintained by, or endorsed by Ente Technologies Inc.

### Relationship to Upstream Ente:
1. **100% Unmodified Upstream Images:** This installer does not compile, modify, or fork Ente's core application code. It pulls and deploys official, signed container images directly from Ente's GitHub Container Registry (`ghcr.io/ente/server`, `ghcr.io/ente/web`, `pgsty/silo`).
2. **Infrastructure Hardening Only:** This installer manages the host runtime environment: pre-flight checks, Docker networking, PostgreSQL healthcheck race condition prevention, port collision avoidance, and direct S3 upload routing.
3. **Upstream First:** Core bug fixes and configuration improvements discovered during development are submitted upstream to [ente/ente](https://github.com/ente/ente) via public pull requests and discussions.

---

## Table of Contents
* [⚡ Quickest Path: The One-Command Installer (`install.sh`)](#-quickest-path-the-one-command-installer-installsh)
* [Security & Privacy Statement](#security--privacy-statement)
* [Safety Guarantees & Safe Execution Model](#safety-guarantees--safe-execution-model)
* [Architecture & How Ente Works](#architecture--how-ente-works)
* [🛠️ Manual Step-by-Step Deployment (Alternative to `install.sh`)](#️-manual-step-by-step-deployment-alternative-to-installsh)
  * [Step 1: Pre-Flight Verification](#step-1-pre-flight-verification)
  * [Step 2: Directory Setup](#step-2-directory-setup)
  * [Step 3: Automated Secret Generation](#step-3-automated-secret-generation)
  * [Step 4: Configuration Files (`museum.yaml` & `compose.yaml`)](#step-4-configuration-files-museumyaml--composeyaml)
  * [Step 5: Launching & Verifying the Stack](#step-5-launching--verifying-the-stack)
  * [Step 6: Account Creation & OTP Retrieval](#step-6-account-creation--otp-retrieval)
  * [Step 7: Safe Storage Quota Sizing & Host Drive Protection](#step-7-safe-storage-quota-sizing--host-drive-protection)
* [Remote Access & Mobile Apps (Photos & Auth)](#remote-access--mobile-apps-photos--auth)
  * [Method A: Cloudflare Zero Trust Tunnel](#method-a-cloudflare-zero-trust-tunnel-easiest-zero-port-forwarding)
  * [Method B: Caddy Reverse Proxy](#method-b-caddy-reverse-proxy-automatic-lets-encrypt-ssl)
  * [How to Connect Mobile & Desktop Apps](#how-to-connect-mobile--desktop-apps)
* [Troubleshooting & Emergency Recovery Matrix](#troubleshooting--emergency-recovery-matrix)
* [Backup, Disaster Recovery & Maintenance Playbook](#backup-disaster-recovery--maintenance-playbook)
* [Production Security Hardening & LTS Best Practices](#production-security-hardening--lts-best-practices)
* [Disclaimers, Licensing & Trademark Attribution](#disclaimers-licensing--trademark-attribution)

---

## ⚡ Quickest Path: The One-Command Installer (`install.sh`)

If you want an automated, fail-safe installation that handles all pre-flight checks, port scanning, secrets generation, race condition prevention, and storage quota allocation automatically, use the installer:

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
* **Operating System & Architecture Check:** Strictly verifies Linux (including WSL2 on Windows); cleanly rejects native Windows shells (Git Bash / MSYS) with actionable guidance. Auto-re-executes in `bash` if launched via `sh` or `dash`.
* **Pre-Flight Hardware, Disk & Port Auditing:** Checks architecture, available RAM and disk space (warns if < 3 GB free), auto-installs Docker/Compose if missing (with user approval), and scans ports to avoid collisions (e.g. automatically moving Web UI from contested `:3000` to `:3004`).
* **Container Conflict & Database Desync Prevention:** Detects existing `ente-*` containers and old database folders; audits permissions and prompts to safely clean up or backup to eliminate container name collisions and password desyncs.
* **Self-Healing Migration Watchdog:** Detects and clears interrupted "dirty" migration flags (`schema_migrations.dirty = true`) on the fly, resuming startup automatically.
* **Network & Domain Sanitization:** Warns against using `127.0.0.1` loopback in LAN mode, sanitizes user domain input (stripping schemes, slashes, and whitespace), and detects active host firewalls (UFW).
* **SELinux & Kernel State Awareness:** Dynamically detects SELinux `Enforcing` mode to append `:z` volume contexts on RHEL/Fedora/Rocky/AlmaLinux, and verifies kernel IPv6 status to prevent container boot crashes on IPv6-disabled hosts.
* **Cryptographic Vault:** Generates high-entropy secrets and stores them in `credentials.env` (`chmod 600`).
* **Zero-Lock Database Boot:** Applies the hardened Postgres healthcheck parameters (`start_period: 60s`, `retries: 20`) to eliminate the "dirty migration" lock.
* **Dynamic Safe Storage Quota:** Prompts for percentage of available disk space (defaulting to 60%, rounded up to nearest multiple of 10) to preserve critical OS headroom, with co-operative fallback verification in `./get-otp.sh`.
* **Sudo-Aware Helper Tools:** Creates `./get-otp.sh`, `./set-quota.sh <SIZE>`, and `./reconfigure.sh` in your install directory, automatically detecting Docker permissions.
* **Existing Deployment Safeguard:** If an active Ente instance is detected in the target directory, it warns you explicitly and offers to launch `./reconfigure.sh` instead of overwriting existing credentials.
* **Unattended Automation Support:** Supports `--unattended` (or `-y`), `--dir <PATH>`, `--domain <DOMAIN>`, and `--quota <SIZE|PCT>` for zero-prompt headless setups (Ansible, cloud-init, CI/CD).
* **Reverse Proxy Snippets:** Generates ready-to-use Caddy and Cloudflare Zero Trust configurations if a domain is specified.
* **Full Audit Logging:** Records every command, system metric, and container diagnostic trace to `ente-installer.log` for instant troubleshooting.

---

## Security & Privacy Statement

This installer adheres to strict privacy and operational security standards:

* **Zero-Knowledge Preservation:** The installer never touches, alters, or intercepts Ente's client-side cryptographic functions. All photo encryption, decryption, and key derivation remain strictly client-side.
* **Zero Telemetry / No Phone-Home:** The installer contains zero tracking scripts, telemetry, or third-party analytic pings. The only outbound connections made are to:
  - Official Linux distribution package repositories (if installing Docker with your explicit approval).
  - GitHub Container Registry and Docker Hub (`ghcr.io`, `docker.io`) to download official container images.
* **Cryptographic Vault (`credentials.env`):**
  - Database passwords, MinIO access keys, and JWT secrets are generated locally using `/dev/urandom` and high-entropy byte streams.
  - Secrets are stored in `credentials.env` with strict `chmod 600` permissions (accessible only by your local host user).
* **Safe Local Network Routing:** Local IP detection operates completely offline via Linux kernel routing tables (`ip route` / `hostname -I`) without pinging external "what is my IP" web services.

---

## Safety Guarantees & Safe Execution Model

To protect your system and existing data from accidental corruption:

* **Non-Destructive Pre-Flight:** Verifies Docker Compose v2.28+ and hardware resources (RAM, disk space) before writing configuration files.
* **Container Conflict & Desync Safeguards:** If older `ente-*` containers or existing `./pg_data` volumes are detected, the installer halts and prompts for user confirmation—offering automated timestamped backups (`pg_data_bak_<timestamp>`) to prevent password mismatch desyncs.
* **Existing Instance Protection:** If run inside an already configured Ente directory, the installer warns you and offers to launch `./reconfigure.sh` instead of overwriting credentials.
* **Zero-Risk Dry-Run (`./install.sh --dry-run`):** Allows full simulation of port allocations, secret generation, and environment checks without modifying host state or launching containers.
* **Audit Execution Log (`ente-installer.log`):** Every command, system metric, and container trace is recorded locally for complete transparency.

---

## Architecture & How Ente Works

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

## 🛠️ Manual Step-by-Step Deployment (Alternative to `install.sh`)

> [!NOTE]
> If you deployed using the **One-Command Installer (`./install.sh`)** above, all directories, secrets, configuration files, and initial quotas were already generated automatically! You can skip directly to [Remote Access & Mobile Apps](#remote-access--mobile-apps-photos--auth) or [Troubleshooting](#troubleshooting--emergency-recovery-matrix).
>
> The steps below are provided for users who wish to inspect the architecture or configure their stack manually by hand.

### Step 1: Pre-Flight Verification

Run these checks on your host system before creating files:

#### 1. Verify Docker & Compose Support
Ente requires Docker with Compose v2.28 or newer:
```bash
docker --version && docker compose version
```

#### 2. Check for Port Collisions
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

### Step 2: Directory Setup

Create an isolated directory structure with explicit persistent volume paths:

```bash
mkdir -p ~/ente/data ~/ente/pg_data ~/ente/minio_data
cd ~/ente
```

---

### Step 3: Automated Secret Generation

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

### Step 4: Configuration Files (`museum.yaml` & `compose.yaml`)

#### 1. `museum.yaml`
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

#### 2. `compose.yaml`
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

### Step 5: Launching & Verifying the Stack

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

### Step 6: Account Creation & OTP Retrieval

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

### Step 7: Safe Storage Quota Sizing & Host Drive Protection

By default, Ente initializes accounts with a restricted 10 GB cloud-tier quota in the database. While it is tempting to set an arbitrary limit like 10 TB, doing so on a drive under 10 TB introduces serious operational risks.

#### Why Storage Safety Margins Matter in Self-Hosting
When self-hosting Ente on a home server, NAS, or VM, your physical storage volume is shared between Ente's encrypted files, the PostgreSQL database, and your host operating system:
1. **PostgreSQL WAL Crash Protection**: PostgreSQL writes transaction logs (Write-Ahead Logs / WAL) before committing data. If the disk fills to 100%, PostgreSQL enters an emergency read-only panic mode or shuts down abruptly with dirty locks.
2. **Docker Daemon Integrity**: When host storage is exhausted, Docker cannot write container state or stream logs, leading to daemon crashes and inability to start or stop containers.
3. **Host OS & Co-Located Workload Stability**: Reserving a safety buffer ensures that Ubuntu system updates, systemd journals, SSH access, and co-located services (such as WordPress, MariaDB, or Grafana) never starve for disk space.

#### Dynamic Default: 60% of Available Space (Rounded Up to Multiple of 10)
Both `install.sh` and `reconfigure.sh` inspect the physical volume hosting your Ente data and calculate a safe quota:
$$\text{Allocated\_GB} = \left\lfloor \frac{\text{Raw\_60\%\_GB} + 9}{10} \right\rfloor \times 10$$
*Example:* On a server with 775 GB available disk space:
* $60\% \text{ of } 775\text{ GB} = 465\text{ GB} \rightarrow \mathbf{470\text{ GB}}$ allocated to Ente.
* **305 GB** remains permanently guarded for system stability.

#### How to Check & Reconfigure Your Quota Anytime

You can modify your quota with **zero container downtime** using either companion tool:

1. **Via `reconfigure.sh` (Interactive Menu or Flag)**:
   ```bash
   ./reconfigure.sh --quota
   ```
   Or launch `./reconfigure.sh` and select **Option [3] Storage Quota Allocation**.

2. **Via `set-quota.sh` (CLI Companion Tool)**:
   ```bash
   # Interactive mode (detects available space and recommends 60% rounded up)
   ./set-quota.sh

   # Set to 60% of available space dynamically
   ./set-quota.sh 60%

   # Set to a fixed size
   ./set-quota.sh 500GB
   ```

3. **Direct SQL (Alternative)**:
   ```bash
   docker exec -i ente-postgres psql -U pguser -d ente_db -c \
     "UPDATE subscriptions SET storage = 504658657280 WHERE user_id = (SELECT user_id FROM users LIMIT 1);"
   ```

Refresh your web gallery tab and open **Settings** $\rightarrow$ **Account**: your storage quota will immediately reflect your updated allocation.

---

## Remote Access & Mobile Apps (Photos & Auth)

> [!IMPORTANT]
> The official Ente mobile and desktop apps **strictly require a valid, publicly trusted HTTPS (TLS) certificate**. They reject plain `http://` and self-signed certificates.

> [!TIP]
> **One-Command Migration Utility:** If you already deployed Ente and want to switch from `localhost` to a private LAN IP, or from LAN to a public domain (Cloudflare Tunnel or Caddy), run the reconfiguration helper:
> ```bash
> ./reconfigure.sh
> ```
> It preserves all your passwords, updates endpoints, and reloads Docker automatically with zero data loss.

### Method A: Cloudflare Zero Trust Tunnel (Easiest, Zero Port Forwarding)

Cloudflare Zero Trust Tunnels (`cloudflared`) allow secure public HTTPS access to your home server without opening router ports or exposing your home IP.

#### 1. Ingress Hostname Routing Architecture
In your Cloudflare Zero Trust Dashboard, navigate to **Networks** $\rightarrow$ **Tunnels**, select your tunnel, and configure the following 3 **Public Hostnames**:

| Subdomain Type | Public Hostname (Example) | Service Type | URL / Port | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Web Gallery** | `entephotos.yourdomain.com` | `HTTP` | `localhost:3004` | Web app UI and album viewer |
| **Core API** | `enteapi.yourdomain.com` | `HTTP` | `localhost:8080` | Museum backend API endpoint |
| **S3 Storage** | `entes3.yourdomain.com` | `HTTP` | `localhost:3200` | Direct encrypted chunk uploads |

> [!TIP]
> Both `install.sh` and `reconfigure.sh` offer a choice between **Branded subdomains** (`entephotos`, `enteapi`, `entes3` — recommended to avoid collisions with other services) and **Generic subdomains** (`photos`, `api`, `s3`).

#### 2. Critical Cloudflare Zero Trust Configuration Rules
To ensure seamless photo syncing and avoid upload failures, configure these settings in Cloudflare:

1. **Keep Cloudflare Access (Zero Trust Applications / SSO / PIN) DISABLED on API and S3:**
   * Mobile apps (iOS & Android) and desktop sync daemons communicate directly with `enteapi` and `entes3`. They **cannot** parse browser-based OAuth/email PIN login gates.
   * If you wish to protect the web UI with Cloudflare Access, enable it **only** on `entephotos.yourdomain.com`.
2. **Exempt API and S3 from Bot Fight Mode & Managed WAF Challenges:**
   * High-frequency background chunk uploads from mobile apps can be falsely flagged as automated bots if Bot Fight Mode is set to interactive JavaScript challenge.
   * Create a WAF Skip rule for hostnames `enteapi.yourdomain.com` and `entes3.yourdomain.com`.
3. **Allow 100MB+ Body & Chunked Transfer:**
   * In your Cloudflare Tunnel settings for `entes3.yourdomain.com`, ensure HTTP chunked uploads and payloads up to your maximum photo/video size are permitted.

#### 3. Container IPv6 Fail-Safe (`sysctls: net.ipv6.conf.all.disable_ipv6: 1`)
When public domains are routed through Cloudflare, Cloudflare's edge DNS publishes dual-stack records (both IPv4 `A` and IPv6 `AAAA`).
* Docker bridge networks do not provide an IPv6 default route by default.
* During file uploads, Ente Museum calls S3 `HeadObject` on `entes3.yourdomain.com` to verify object size.
* Without kernel hardening, Go's dual-stack dialer attempts to route via IPv6, resulting in `connect: network is unreachable` and causing uploads to fail at **99%**.
* Both `install.sh` and `reconfigure.sh` automatically inject:
  ```yaml
  services:
    museum:
      sysctls:
        net.ipv6.conf.all.disable_ipv6: 1
  ```
  This guarantees that internal container DNS requests strictly use IPv4, eliminating connection failures.

#### 4. Applying with `reconfigure.sh`
Instead of manually editing YAML files, run the reconfiguration utility:
```bash
./reconfigure.sh
```
Select **[2] Public Domain / Reverse Proxy**, enter your root domain (e.g. `yourdomain.com`), and choose whether your reverse proxy runs directly on the host or inside a Docker bridge container. All endpoints, S3 bucket regions, and sysctls will be updated in place safely.

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

### How to Connect Mobile & Desktop Apps

Both **Ente Photos** and **Ente Auth** share the same unified backend and user account.

#### 1. Connecting Ente Photos (iOS / Android / Desktop)
1. Install **Ente Photos** from the Apple App Store, Google Play Store, or desktop release.
2. Open the app to the initial screen.
3. **The Hidden Developer Menu:** Tap the **Ente logo** at the top **7 times in a row**.
4. A hidden configuration field appears: enter your custom API endpoint:
   ```text
   https://api.yourdomain.com
   ```
5. Log in with your email and master encryption password.

#### 2. Connecting Ente Auth (2FA Authenticator)
1. Install **Ente Auth** on your phone or desktop.
2. Tap the **Ente logo** 7 times (or navigate to **Settings** $\rightarrow$ **Server**).
3. Enter the same API endpoint:
   ```text
   https://api.yourdomain.com
   ```
4. Log in with your credentials. All two-factor authentication tokens sync with zero-knowledge end-to-end encryption to your private server.

---

## Troubleshooting & Emergency Recovery Matrix

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
| **Upload reaches 99% then flips to `Failed 1` (`OBJECT_SIZE_FETCH_FAILED`)** | Cloudflare dual-stack IPv6 DNS resolution inside Docker container lacking an IPv6 gateway (`dial tcp [2606:...]:443: connect: network is unreachable`). | Disable container IPv6 via sysctls: add `sysctls: net.ipv6.conf.all.disable_ipv6: 1` under `museum` in `compose.yaml` (handled automatically by `reconfigure.sh`). |
| **`403 AccessDenied` or `AuthorizationHeaderMalformed` on upload commit** | S3 bucket region in `museum.yaml` does not match MinIO bucket creation region (`eu-central-2`). | Ensure all bucket entries (`b2-eu-cen`, `wasabi-eu-central-2-v3`, `scw-eu-fr-v3`) specify `region: eu-central-2` in `museum.yaml`. |
| **Verification OTP not received in email** | SMTP email server is not configured in `museum.yaml`. | Run `docker logs --tail 50 ente-museum \| grep -i "code"` to read the OTP directly from standard output. |

---

## Backup, Disaster Recovery & Maintenance Playbook

### Backing Up Ente
To create a complete, consistent backup of your entire instance:

1. **Backup Database:**
   ```bash
   docker exec ente-postgres pg_dump -U pguser ente_db > ~/ente-db-backup-$(date +%F).sql
   ```
2. **Backup Encrypted Photos:**
   Copy the `~/ente/minio_data` folder (or use `rclone` to mirror to an offsite location/NAS). Because all files are encrypted client-side with your master key, even unencrypted cloud backups of this folder are zero-knowledge secure.
3. **Backup Configuration Vault:**
   Securely store copies of `credentials.env`, `museum.yaml`, and `compose.yaml`.

---

### Restoring from Backup (Disaster Recovery)
If moving to a new server or recovering from storage failure:

1. Deploy the clean Ente stack using `./install.sh`.
2. Stop the core services before restoring:
   ```bash
   docker compose stop museum web
   ```
3. **Restore Database:**
   ```bash
   docker exec -i ente-postgres psql -U pguser -d ente_db < ~/ente-db-backup.sql
   ```
4. **Restore Photo Storage:**
   Restore your backed-up `minio_data/` folder into `~/ente/minio_data/`.
5. Restart services:
   ```bash
   docker compose start
   ```

---

### Updating Container Images Safely
```bash
cd ~/ente
docker compose pull
docker compose up -d
```
Docker will recreate only the updated containers while preserving all persistent data in `./pg_data` and `./minio_data`.

---

## Production Security Hardening & LTS Best Practices

### 1. File Permission Lockdown (`chmod 600`)
`museum.yaml` and `credentials.env` contain your PostgreSQL database password, MinIO storage keys, encryption keys, and JWT secret. On shared or multi-user Linux machines, lock down these files to prevent unauthorized local reading:

```bash
chmod 600 ~/ente/museum.yaml ~/ente/credentials.env
```
> [!NOTE]
> Docker daemon runs as root and can read `600` bind-mounted files without issue.

---

### 2. Localhost Port Isolation in Domain / Tunnel Mode
When hosting publicly through **Cloudflare Tunnel** or a local **Caddy** reverse proxy running on the same host:
* By default, Docker binds ports to `0.0.0.0` (all interfaces), which can leave raw HTTP ports reachable from the internet if your server has a public IP.
* To ensure your Ente instance is **only** accessible through Cloudflare's WAF / SSL and never directly via raw IP, bind host ports to loopback (`127.0.0.1`) in `compose.yaml`:

```yaml
ports:
  - "127.0.0.1:3004:3000"  # Web UI only bound to localhost
  - "127.0.0.1:8080:8080"  # Core API only bound to localhost
  - "127.0.0.1:3200:3200"  # S3 Storage only bound to localhost
```

---

### 3. Long-Term Support (LTS) & Version Pinning
* **Ente Services (`ghcr.io/ente/museum`, `ghcr.io/ente/web`):**
  By default, `compose.yaml` uses the latest image tags. In critical production homelabs, you can pin specific releases (e.g. `ghcr.io/ente/museum:0.8.x`) in `compose.yaml` to prevent unexpected upstream breaking changes during routine `docker compose pull` commands.
* **PostgreSQL 15 Lifecycle:**
  `compose.yaml` is pinned to `postgres:15`. PostgreSQL 15 receives official community security updates and maintenance through **November 11, 2027**.
* **Docker Compose Requirement:**
  The automated bucket creation hook in `compose.yaml` uses the `post_start` lifecycle feature, which strictly requires **Docker Compose v2.28.0 or newer**. If deploying on an older Linux distribution, ensure your Docker Compose plugin is updated (`docker compose version`).

---

## Disclaimers, Licensing & Trademark Attribution

### Trademarks
"Ente", the Ente logo, and related marks are trademarks of Ente Technologies Inc. This project is an independent community deployment tool intended to facilitate self-hosting of Ente's open-source server software.

### Software Licenses
* **Installer & Automation Scripts:** Released under the [MIT License](LICENSE).
* **Ente Server & Web Applications:** The core Ente software orchestrated by this script is licensed under the [GNU Affero General Public License v3.0 (AGPL-3.0)](https://github.com/ente/ente/blob/main/LICENSE) by Ente Technologies Inc.

### Disclaimer of Warranty
THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
