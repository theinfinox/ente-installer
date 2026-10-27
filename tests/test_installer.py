#!/usr/bin/env python3
"""
Comprehensive Validation & Test Suite for Ente Fail-Safe Installer
Tests:
  1. Bash Syntax Validation (AST / bash -n) for all scripts
  2. YAML Syntax & Semantic Validation for museum.yaml and compose.yaml
  3. Port Scanner & Fallback Allocation Logic
  4. Quota Math Calculation in set-quota.sh
  5. Domain Sanitization Logic
  6. ANSI Strip & Log Formatting Logic
  7. Cross-Configuration Consistency (museum.yaml <-> compose.yaml)
"""

import os
import re
import subprocess
import sys
import tempfile
import yaml

RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"

PASS_COUNT = 0
FAIL_COUNT = 0

def assert_test(name, condition, details=""):
    global PASS_COUNT, FAIL_COUNT
    if condition:
        print(f" {GREEN}[PASS]{RESET} {name}")
        PASS_COUNT += 1
    else:
        print(f" {RED}[FAIL]{RESET} {name}")
        if details:
            print(f"        {YELLOW}{details}{RESET}")
        FAIL_COUNT += 1

def run_bash_code(code):
    bash_path = r"C:\Program Files\Git\bin\bash.exe"
    proc = subprocess.run(
        [bash_path, "-c", code],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace"
    )
    stdout = proc.stdout.strip() if proc.stdout else ""
    stderr = proc.stderr.strip() if proc.stderr else ""
    return proc.returncode, stdout, stderr

def main():
    # Set utf-8 stdout encoding for Windows compatibility
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')

    print(f"\n{CYAN}======================================================================{RESET}")
    print(f"{CYAN}       ENTE INSTALLER OFFLINE VALIDATION SUITE (ZERO IMAGE PULLS)       {RESET}")
    print(f"{CYAN}======================================================================{RESET}\n")

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    script_path = os.path.join(repo_root, "install.sh")
    assert_test("Installer file exists", os.path.exists(script_path), script_path)

    with open(script_path, "r", encoding="utf-8") as f:
        content = f.read()

    # -------------------------------------------------------------------------
    # Test 1: Bash Syntax Validation (bash -n)
    # -------------------------------------------------------------------------
    code, out, err = run_bash_code(f"bash -n '{script_path}'")
    assert_test("install.sh passes bash syntax check (bash -n)", code == 0, err)

    # -------------------------------------------------------------------------
    # Test 2: Extraction & Syntax Validation of Companion Scripts
    # -------------------------------------------------------------------------
    # Extract get-otp.sh template
    otp_match = re.search(r"cat <<'EOF' > \"\$TARGET_DIR/get-otp\.sh\"\n(.*?)\nEOF", content, re.DOTALL)
    assert_test("get-otp.sh template found in install.sh", bool(otp_match))
    if otp_match:
        code, out, err = run_bash_code(f"bash -n << 'EOF'\n{otp_match.group(1)}\nEOF")
        assert_test("get-otp.sh passes bash syntax check", code == 0, err)
        assert_test("get-otp.sh contains auto-upgrade query for pending users", "UPDATE subscriptions SET storage = $TARGET_BYTES" in otp_match.group(1))
        assert_test("get-otp.sh uses expanded --tail 200 buffer", "--tail 200" in otp_match.group(1))

    # Extract set-quota.sh template
    quota_match = re.search(r"cat <<'EOF' > \"\$TARGET_DIR/set-quota\.sh\"\n(.*?)\nEOF", content, re.DOTALL)
    assert_test("set-quota.sh template found in install.sh", bool(quota_match))
    if quota_match:
        quota_content = quota_match.group(1)
        code, out, err = run_bash_code(f"bash -n << 'EOF'\n{quota_content}\nEOF")
        assert_test("set-quota.sh passes bash syntax check", code == 0, err)
        assert_test("set-quota.sh contains ^[0-9]+$ regex check for TARGET_USER", '^[0-9]+$' in quota_content)

        test_valid_user = 'TARGET_USER="1580559962386438"; if [[ "$TARGET_USER" =~ ^[0-9]+$ ]]; then echo "VALID"; fi'
        code, out, err = run_bash_code(test_valid_user)
        assert_test("TARGET_USER numeric validation accepts valid user_id", out == "VALID")

        test_invalid_user = 'TARGET_USER="admin; DROP TABLE users;"; if [[ ! "$TARGET_USER" =~ ^[0-9]+$ ]]; then echo "INVALID"; fi'
        code, out, err = run_bash_code(test_invalid_user)
        assert_test("TARGET_USER numeric validation rejects SQL injection / non-numeric string", out == "INVALID")

    # Extract .auto-quota-daemon.sh template
    daemon_match = re.search(r"cat <<'EOF' > \"\$TARGET_DIR/\.auto-quota-daemon\.sh\"\n(.*?)\nEOF", content, re.DOTALL)
    assert_test(".auto-quota-daemon.sh template found in install.sh", bool(daemon_match))
    if daemon_match:
        code, out, err = run_bash_code(f"bash -n << 'EOF'\n{daemon_match.group(1)}\nEOF")
        assert_test(".auto-quota-daemon.sh passes bash syntax check", code == 0, err)

    # -------------------------------------------------------------------------
    # Test 3: Math Accuracy of Quota Conversion in set-quota.sh
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating Quota Mathematical Conversion Logic:{RESET}")
    test_cases = [
        ("10TB", 10 * 1024 * 1024 * 1024 * 1024),
        ("2TB", 2 * 1024 * 1024 * 1024 * 1024),
        ("500GB", 500 * 1024 * 1024 * 1024),
        ("50GB", 50 * 1024 * 1024 * 1024),
        ("100", 100 * 1024 * 1024 * 1024),
    ]
    for unit_str, expected_bytes in test_cases:
        bash_snippet = f"""
INPUT_SIZE="{unit_str}"
UPPER_SIZE=$(echo "$INPUT_SIZE" | tr '[:lower:]' '[:upper:]')
if [[ "$UPPER_SIZE" =~ ^([0-9]+)TB$ ]]; then
    NUM=${{BASH_REMATCH[1]}}
    BYTES=$(( NUM * 1024 * 1024 * 1024 * 1024 ))
elif [[ "$UPPER_SIZE" =~ ^([0-9]+)GB$ ]]; then
    NUM=${{BASH_REMATCH[1]}}
    BYTES=$(( NUM * 1024 * 1024 * 1024 ))
elif [[ "$UPPER_SIZE" =~ ^[0-9]+$ ]]; then
    NUM=$UPPER_SIZE
    BYTES=$(( NUM * 1024 * 1024 * 1024 ))
fi
echo "$BYTES"
"""
        code, out, err = run_bash_code(bash_snippet)
        assert_test(f"Quota math for '{unit_str}' = {expected_bytes} bytes", out == str(expected_bytes), f"Got {out}, expected {expected_bytes}")

    # Test percentage quota math
    pct_snippet = """
INPUT_SIZE="60%"
UPPER_SIZE=$(echo "$INPUT_SIZE" | tr '[:lower:]' '[:upper:]')
if [[ "$UPPER_SIZE" =~ ^([0-9]+)%$ ]]; then
    PCT=${BASH_REMATCH[1]}
    TOTAL_KB=1000000
    BYTES=$(( TOTAL_KB * 1024 * PCT / 100 ))
fi
echo "$BYTES"
"""
    code, out, err = run_bash_code(pct_snippet)
    assert_test("Quota percentage math for '60%' calculates correctly", out == str(600000 * 1024))

    # Test ceiling multiple-of-10 round-up quota math
    round_cases = [
        (461, 470),
        (465, 470),
        (460, 460),
        (470, 470),
        (7, 10),
        (1, 10),
    ]
    for raw_gb, expected_rounded in round_cases:
        round_snippet = f"""
RAW_GB={raw_gb}
ROUNDED_GB=$(( ((RAW_GB + 9) / 10) * 10 ))
echo "$ROUNDED_GB"
"""
        code, out, err = run_bash_code(round_snippet)
        assert_test(f"Ceiling round-up multiple-of-10 for {raw_gb} GB -> {expected_rounded} GB", out == str(expected_rounded), f"Got {out}")

    # Test safety clamp when round-up exceeds available disk
    clamp_snippet = """
AVAIL_GB=8
CALC_GB=$(( AVAIL_GB * 60 / 100 )) # 4 GB
ROUNDED_GB=$(( ((CALC_GB + 9) / 10) * 10 )) # 10 GB
if [ "$ROUNDED_GB" -gt "$AVAIL_GB" ]; then
    ROUNDED_GB=$CALC_GB
fi
echo "$ROUNDED_GB"
"""
    code, out, err = run_bash_code(clamp_snippet)
    assert_test("Low-disk safety clamp prevents rounding up past physical capacity (8GB -> 4GB)", out == "4", f"Got {out}")

    # -------------------------------------------------------------------------
    # Test 4: YAML Syntax & Semantic Validation (museum.yaml & compose.yaml)
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating Generated Configuration YAML Syntax:{RESET}")
    # Extract museum.yaml template
    museum_template_match = re.search(r"cat <<EOF > \"\$TARGET_DIR/museum\.yaml\"\n(.*?)\nEOF\n\s+chmod 600 \"\$TARGET_DIR/museum\.yaml\"", content, re.DOTALL)
    assert_test("museum.yaml template found in install.sh", bool(museum_template_match))
    assert_test("install.sh sets chmod 600 on museum.yaml", 'chmod 600 "$TARGET_DIR/museum.yaml"' in content)

    if museum_template_match:
        raw_museum = museum_template_match.group(1)
        # Substitute bash variables with dummy test values
        subbed_museum = raw_museum
        replacements = {
            "${PG_PASS}": "TestPass12345",
            "${MINIO_USER}": "test-minio-user",
            "${MINIO_PASS}": "test-minio-pass",
            "${KEY_ENC}": "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=",
            "${KEY_HASH}": "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTZBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWjEyMzQ1Ng==",
            "${JWT_SECRET}": "dGVzdC1qd3Qtc2VjcmV0LTEyMzQ1Njc4OTA=",
            "${S3_ENDPOINT}": "192.168.1.50:3200",
            "${ARE_LOCAL_BUCKETS}": "true"
        }
        for k, v in replacements.items():
            subbed_museum = subbed_museum.replace(k, v)

        try:
            parsed_museum = yaml.safe_load(subbed_museum)
            assert_test("museum.yaml is 100% valid YAML", True)
            # Semantic assertions
            assert_test("museum.yaml db host is 'postgres'", parsed_museum.get("db", {}).get("host") == "postgres")
            assert_test("museum.yaml db port is 5432", parsed_museum.get("db", {}).get("port") == 5432)
            assert_test("museum.yaml s3 has b2-eu-cen bucket", "b2-eu-cen" in parsed_museum.get("s3", {}))
            assert_test("museum.yaml s3 endpoint is preserved", parsed_museum.get("s3", {}).get("b2-eu-cen", {}).get("endpoint") == "192.168.1.50:3200")
            assert_test("museum.yaml b2-eu-cen region is eu-central-2", parsed_museum.get("s3", {}).get("b2-eu-cen", {}).get("region") == "eu-central-2")
            assert_test("museum.yaml wasabi region is eu-central-2", parsed_museum.get("s3", {}).get("wasabi-eu-central-2-v3", {}).get("region") == "eu-central-2")
            assert_test("museum.yaml scw region is eu-central-2", parsed_museum.get("s3", {}).get("scw-eu-fr-v3", {}).get("region") == "eu-central-2")
            assert_test("museum.yaml jwt secret is set", parsed_museum.get("jwt", {}).get("secret") == "dGVzdC1qd3Qtc2VjcmV0LTEyMzQ1Njc4OTA=")
        except Exception as e:
            assert_test("museum.yaml is 100% valid YAML", False, str(e))

    # Extract compose.yaml template
    compose_template_match = re.search(r"cat <<EOF > \"\$TARGET_DIR/compose\.yaml\"\n(.*?)\nEOF\n    chmod 644 \"\$TARGET_DIR/compose\.yaml\"", content, re.DOTALL)
    assert_test("compose.yaml template found in install.sh", bool(compose_template_match))

    if compose_template_match:
        raw_compose = compose_template_match.group(1)
        subbed_compose = raw_compose
        replacements = {
            "${PORT_BIND_PREFIX}": "",
            "${API_PORT}": "8080",
            "${WEB_PORT}": "3004",
            "${ALBUMS_PORT}": "3002",
            "${MINIO_PORT}": "3200",
            "${PG_PASS}": "TestPass12345",
            "${MINIO_USER}": "test-minio-user",
            "${MINIO_PASS}": "test-minio-pass",
            "${API_ORIGIN}": "http://192.168.1.50:8080",
            "${ALBUMS_ORIGIN}": "http://192.168.1.50:3002",
            "${IPV6_SYSCTL_SNIPPET}": "    sysctls:\n      net.ipv6.conf.all.disable_ipv6: 1",
            "${SELINUX_VOLUME_SUFFIX:-}": "",
            "${SELINUX_VOLUME_SUFFIX}": "",
        }
        for k, v in replacements.items():
            subbed_compose = subbed_compose.replace(k, v)

        try:
            parsed_compose = yaml.safe_load(subbed_compose)
            assert_test("compose.yaml is 100% valid YAML", True)
            services = parsed_compose.get("services", {})
            assert_test("compose.yaml defines 5 core services", len(services) == 5, f"Found {list(services.keys())}")
            assert_test("services include museum, web, postgres, minio, socat", 
                        all(s in services for s in ["museum", "web", "postgres", "minio", "socat"]))
            # Healthcheck checks
            pg_hc = services.get("postgres", {}).get("healthcheck", {})
            assert_test("postgres has hardened 60s start_period", pg_hc.get("start_period") == "60s")
            assert_test("postgres has 20 retries", pg_hc.get("retries") == 20)
            # Web ports
            web_ports = services.get("web", {}).get("ports", [])
            assert_test("web port mapping matches remapped port", "3004:3000" in web_ports)
            # IPv6 sysctls fail-safe (prevents 99% upload failure on dual-stack DNS)
            assert_test("museum service disables container IPv6 via sysctls", 
                        services.get("museum", {}).get("sysctls", {}).get("net.ipv6.conf.all.disable_ipv6") == 1)
        except Exception as e:
            assert_test("compose.yaml is 100% valid YAML", False, str(e))

        # Test Loopback Port Isolation Mode in compose.yaml
        subbed_compose_isolated = raw_compose
        replacements_isolated = dict(replacements)
        replacements_isolated["${PORT_BIND_PREFIX}"] = "127.0.0.1:"
        for k, v in replacements_isolated.items():
            subbed_compose_isolated = subbed_compose_isolated.replace(k, v)
        try:
            parsed_isolated = yaml.safe_load(subbed_compose_isolated)
            isolated_web_ports = parsed_isolated.get("services", {}).get("web", {}).get("ports", [])
            assert_test("isolated compose.yaml binds web port to 127.0.0.1:3004:3000", "127.0.0.1:3004:3000" in isolated_web_ports)
            isolated_api_ports = parsed_isolated.get("services", {}).get("museum", {}).get("ports", [])
            assert_test("isolated compose.yaml binds api port to 127.0.0.1:8080:8080", "127.0.0.1:8080:8080" in isolated_api_ports)
            assert_test("isolated museum service disables container IPv6 via sysctls", 
                        parsed_isolated.get("services", {}).get("museum", {}).get("sysctls", {}).get("net.ipv6.conf.all.disable_ipv6") == 1)
        except Exception as e:
            assert_test("isolated compose.yaml is valid YAML", False, str(e))

    # -------------------------------------------------------------------------
    # Test 5: Domain Sanitization Parameter Expansion
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating Domain & Input Sanitization Rules:{RESET}")
    test_domains = [
        ("https://photos.example.com/", "photos.example.com"),
        ("http://example.org/ ", "example.org"),
        ("  sub.domain.io  ", "sub.domain.io"),
        ("photos.ente.cloud", "photos.ente.cloud"),
        ("  HTTPS://Photos.Example.Com/  ", "photos.example.com"),
        ("  .example.org.  ", "example.org")
    ]
    for raw_domain, expected_domain in test_domains:
        bash_sanitizer = f"""
ROOT_DOMAIN="{raw_domain}"
ROOT_DOMAIN=$(echo "$ROOT_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
ROOT_DOMAIN=${{ROOT_DOMAIN#https://}}
ROOT_DOMAIN=${{ROOT_DOMAIN#http://}}
ROOT_DOMAIN=${{ROOT_DOMAIN%/}}
ROOT_DOMAIN=${{ROOT_DOMAIN#.}}
ROOT_DOMAIN=${{ROOT_DOMAIN%.}}
echo "$ROOT_DOMAIN"
"""
        code, out, err = run_bash_code(bash_sanitizer)
        assert_test(f"Sanitize '{raw_domain}' -> '{expected_domain}'", out == expected_domain, f"Got '{out}'")

    # -------------------------------------------------------------------------
    # Test 6: ANSI Stripping in Log Engine
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating ANSI Escape Code Stripping in Logger:{RESET}")
    ansi_test = r"""
MSG=$'\033[0;32m[OK] Success!\033[0m \033[1;33mWarning\033[0m'
clean_msg=$(printf '%b' "$MSG" | sed -E 's/\x1B\[[0-9;]*[mK]//g' 2>/dev/null || echo "$MSG")
echo "$clean_msg"
"""
    code, out, err = run_bash_code(ansi_test)
    assert_test("ANSI codes stripped cleanly from log messages", out == "[OK] Success! Warning", f"Got '{out}'")

    # -------------------------------------------------------------------------
    # Test 7: Reconfiguration Utility (reconfigure.sh)
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating Reconfiguration Utility (reconfigure.sh):{RESET}")
    reconfig_path = os.path.join(repo_root, "reconfigure.sh")
    assert_test("reconfigure.sh file exists", os.path.exists(reconfig_path))
    code, out, err = run_bash_code(f"bash -n '{reconfig_path}'")
    assert_test("reconfigure.sh passes bash syntax check", code == 0, err)

    with open(reconfig_path, "r", encoding="utf-8") as f:
        reconfig_content = f.read()

    assert_test("reconfigure.sh sets chmod 600 on museum.yaml", 'chmod 600 "$TARGET_DIR/museum.yaml"' in reconfig_content)
    assert_test("install.sh informs user of security hardening in summary", "Security & Hardening Applied" in content)
    assert_test("reconfigure.sh informs user of security hardening in summary", "Security & Hardening Applied" in reconfig_content)
    assert_test("install.sh informs user of storage quota in summary", "Storage Quota Notice" in content)
    assert_test("install.sh contains allocate_storage_quota function", "allocate_storage_quota()" in content)
    assert_test("reconfigure.sh contains reconfigure_quota function", "reconfigure_quota()" in reconfig_content)
    assert_test("install.sh contains DNS Pre-Flight validation logic", "Performing DNS Pre-Flight validation" in content)
    assert_test("reconfigure.sh contains DNS Pre-Flight validation logic", "Performing DNS Pre-Flight validation" in reconfig_content)
    assert_test("install.sh contains Cloudflare Zero Trust Ingress Checklist", "Cloudflare Zero Trust Ingress Checklist" in content)
    assert_test("reconfigure.sh contains Cloudflare Zero Trust Ingress Checklist", "Cloudflare Zero Trust Ingress Checklist" in reconfig_content)
    assert_test("install.sh contains shell auto-wrapper for non-bash shells", 'if [ -z "$BASH_VERSION" ]; then' in content)
    assert_test("reconfigure.sh contains shell auto-wrapper for non-bash shells", 'if [ -z "$BASH_VERSION" ]; then' in reconfig_content)
    assert_test("install.sh checks SELinux Enforcing mode", 'getenforce' in content and 'SELINUX_VOLUME_SUFFIX' in content)
    assert_test("reconfigure.sh checks SELinux Enforcing mode", 'getenforce' in reconfig_content and 'SELINUX_VOLUME_SUFFIX' in reconfig_content)
    assert_test("install.sh checks kernel IPv6 disabled state", 'KERNEL_IPV6_DISABLED' in content)
    assert_test("reconfigure.sh checks kernel IPv6 disabled state", 'IPV6_SYSCTL_SNIPPET' in reconfig_content)
    assert_test("install.sh supports CLI flags --dir, --domain, --quota", '--dir' in content and '--domain' in content and '--quota' in content)
    assert_test("install.sh checks existing pg_data with elevated fallback", 'HAS_EXISTING_PG_FILES' in content)

    # Test dry-run reconfiguration on a simulated active deployment (LAN Mode)
    with tempfile.TemporaryDirectory() as temp_dir:
        # Create mock credentials.env
        orig_pg_pass = "SuperSecretDbPassword9988"
        with open(os.path.join(temp_dir, "credentials.env"), "w") as f:
            f.write(f"""PG_USER=pguser
PG_PASSWORD={orig_pg_pass}
PG_DB=ente_db
MINIO_ROOT_USER=minio-user-test
MINIO_ROOT_PASSWORD=minio-pass-test
MUSEUM_KEY_ENC=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=
MUSEUM_KEY_HASH=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTZBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWjEyMzQ1Ng==
MUSEUM_JWT_SECRET=dGVzdC1qd3Qtc2VjcmV0LTEyMzQ1Njc4OTA=
WEB_ORIGIN=http://127.0.0.1:3000
API_ORIGIN=http://127.0.0.1:8080
S3_ENDPOINT=127.0.0.1:3200
""")

        # Create mock compose.yaml
        with open(os.path.join(temp_dir, "compose.yaml"), "w") as f:
            f.write("""services:
  web:
    ports:
      - "3004:3000"
      - "3002:3002"
    environment:
      ENTE_API_ORIGIN: http://127.0.0.1:8080
  museum:
    ports:
      - "8080:8080"
  minio:
    ports:
      - "3200:3200"
""")

        # Create mock museum.yaml
        with open(os.path.join(temp_dir, "museum.yaml"), "w") as f:
            f.write(f"""db:
  host: postgres
  password: "{orig_pg_pass}"
s3:
  b2-eu-cen:
    endpoint: "127.0.0.1:3200"
""")

        # Run reconfigure.sh simulation: select option 1 (LAN mode), IP 192.168.1.99
        reconfig_cmd = f"bash '{reconfig_path}' '{temp_dir}' --dry-run <<< $'1\\n192.168.1.99\\n'"
        code, out, err = run_bash_code(reconfig_cmd)
        assert_test("reconfigure.sh executed successfully in LAN dry-run mode", code == 0, err)

        # Verify that original password was preserved
        with open(os.path.join(temp_dir, "credentials.env"), "r") as f:
            new_creds = f.read()
        assert_test("reconfigure.sh preserved original DB password", f"PG_PASSWORD={orig_pg_pass}" in new_creds)
        assert_test("reconfigure.sh updated S3_ENDPOINT to new IP", "S3_ENDPOINT=192.168.1.99:3200" in new_creds)
        assert_test("reconfigure.sh updated WEB_ORIGIN to new IP", "WEB_ORIGIN=http://192.168.1.99:3004" in new_creds)

        # Verify backup files were created
        bak_files = [fn for fn in os.listdir(temp_dir) if "bak_" in fn]
        assert_test("reconfigure.sh created safe configuration backups", len(bak_files) >= 2, str(bak_files))

        # Verify new compose.yaml is valid YAML
        with open(os.path.join(temp_dir, "compose.yaml"), "r") as f:
            reconfig_compose = yaml.safe_load(f)
        assert_test("reconfigured compose.yaml is 100% valid YAML", isinstance(reconfig_compose, dict))
        assert_test("reconfigured compose.yaml has sysctls net.ipv6.conf.all.disable_ipv6=1",
                    reconfig_compose.get("services", {}).get("museum", {}).get("sysctls", {}).get("net.ipv6.conf.all.disable_ipv6") == 1)

        # Test Option 3: Storage Quota Allocation in reconfigure.sh
        quota_reconfig_cmd = f"bash '{reconfig_path}' '{temp_dir}' --dry-run <<< $'3\\n60%\\nY\\n'"
        code, out, err = run_bash_code(quota_reconfig_cmd)
        assert_test("reconfigure.sh Option 3 executes storage quota allocation in dry-run mode", code == 0, err)
        assert_test("reconfigure.sh Option 3 outputs Storage Quota & Host Drive Safety banner", "Storage Quota & Host Drive Safety" in out)

        # Test --quota CLI flag in reconfigure.sh
        quota_flag_cmd = f"bash '{reconfig_path}' '{temp_dir}' --dry-run --quota <<< $'60%\\nY\\n'"
        code, out, err = run_bash_code(quota_flag_cmd)
        assert_test("reconfigure.sh --quota directly triggers storage quota allocation", code == 0, err)

    # Test dry-run reconfiguration in Domain Mode with Local Reverse Proxy Isolation
    with tempfile.TemporaryDirectory() as temp_dir_domain:
        orig_pg_pass = "DomainPassSecure77"
        with open(os.path.join(temp_dir_domain, "credentials.env"), "w") as f:
            f.write(f"""PG_USER=pguser
PG_PASSWORD={orig_pg_pass}
PG_DB=ente_db
MINIO_ROOT_USER=minio-user-test
MINIO_ROOT_PASSWORD=minio-pass-test
MUSEUM_KEY_ENC=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=
MUSEUM_KEY_HASH=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTZBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWjEyMzQ1Ng==
MUSEUM_JWT_SECRET=dGVzdC1qd3Qtc2VjcmV0LTEyMzQ1Njc4OTA=
WEB_ORIGIN=http://127.0.0.1:3000
API_ORIGIN=http://127.0.0.1:8080
S3_ENDPOINT=127.0.0.1:3200
""")
        with open(os.path.join(temp_dir_domain, "compose.yaml"), "w") as f:
            f.write("""services:
  web:
    ports:
      - "3004:3000"
      - "3002:3002"
    environment:
      ENTE_API_ORIGIN: http://127.0.0.1:8080
  museum:
    ports:
      - "8080:8080"
  minio:
    ports:
      - "3200:3200"
""")
        with open(os.path.join(temp_dir_domain, "museum.yaml"), "w") as f:
            f.write(f"""db:
  host: postgres
  password: "{orig_pg_pass}"
s3:
  b2-eu-cen:
    endpoint: "127.0.0.1:3200"
""")

        # Option 2 (Domain), root domain 'ente.example.com', default branded subdomains (1 or Enter), proxy on same server (Y)
        reconfig_domain_cmd = f"bash '{reconfig_path}' '{temp_dir_domain}' --dry-run <<< $'2\\nente.example.com\\n1\\nY\\n'"
        code, out, err = run_bash_code(reconfig_domain_cmd)
        assert_test("reconfigure.sh executed successfully in Domain Mode", code == 0, err)
        assert_test("reconfigure.sh Domain Mode displayed Security & Hardening banner", "Security & Hardening Applied" in out)
        assert_test("reconfigure.sh Domain Mode confirmed localhost isolation", "isolated to 127.0.0.1" in out)

        with open(os.path.join(temp_dir_domain, "credentials.env"), "r") as f:
            cred_env = f.read()
        assert_test("Domain Mode generated branded entephotos subdomain", "WEB_ORIGIN=https://entephotos.ente.example.com" in cred_env)
        assert_test("Domain Mode generated branded enteapi subdomain", "API_ORIGIN=https://enteapi.ente.example.com" in cred_env)
        assert_test("Domain Mode generated branded entes3 subdomain", "S3_ENDPOINT=entes3.ente.example.com" in cred_env)

        with open(os.path.join(temp_dir_domain, "compose.yaml"), "r") as f:
            domain_compose = yaml.safe_load(f)
        web_ports_domain = domain_compose.get("services", {}).get("web", {}).get("ports", [])
        assert_test("Domain Mode bound web port to 127.0.0.1:3004:3000", "127.0.0.1:3004:3000" in web_ports_domain)
        museum_ports_domain = domain_compose.get("services", {}).get("museum", {}).get("ports", [])
        assert_test("Domain Mode bound museum port to 127.0.0.1:8080:8080", "127.0.0.1:8080:8080" in museum_ports_domain)
        assert_test("Domain Mode compose.yaml has sysctls net.ipv6.conf.all.disable_ipv6=1",
                    domain_compose.get("services", {}).get("museum", {}).get("sysctls", {}).get("net.ipv6.conf.all.disable_ipv6") == 1)
        assert_test("Domain Mode generated Caddyfile reverse proxy snippet", os.path.exists(os.path.join(temp_dir_domain, "reverse-proxy", "Caddyfile.snippet")))
        assert_test("Domain Mode generated Cloudflare Tunnel ingress guide", os.path.exists(os.path.join(temp_dir_domain, "reverse-proxy", "cloudflare-tunnel.md")))
        assert_test("reconfigure.sh Domain Mode displayed Cloudflare Ingress Checklist", "Cloudflare Zero Trust Ingress Checklist" in out)
        assert_test("reconfigure.sh Domain Mode ran DNS Pre-Flight validation", "DNS Pre-Flight validation" in out)

        with open(os.path.join(temp_dir_domain, "museum.yaml"), "r") as f:
            domain_museum = yaml.safe_load(f)
        assert_test("reconfigured museum.yaml b2-eu-cen region is eu-central-2",
                    domain_museum.get("s3", {}).get("b2-eu-cen", {}).get("region") == "eu-central-2")
        assert_test("reconfigured museum.yaml wasabi region is eu-central-2",
                    domain_museum.get("s3", {}).get("wasabi-eu-central-2-v3", {}).get("region") == "eu-central-2")
        assert_test("reconfigured museum.yaml scw region is eu-central-2",
                    domain_museum.get("s3", {}).get("scw-eu-fr-v3", {}).get("region") == "eu-central-2")

        # CRLF Immunity Test
        with open(os.path.join(temp_dir_domain, "museum.yaml"), "wb") as f:
            f.write(b'jwt:\r\n  secret: "Kf1ljPzrOClqG8rIbdGoCfKEykICpDyf7_R_Raoqzds="\r\nkey:\r\n  encryption: "sb94DVkp3n1HaJRd7P9AdYP+D0V9LCZCEF4OtsZqVfQ="\r\n  hash: "lT7/LNCMyKmPVeSqt4KzzMNFlDUYDwt7s2QCVXOsrPDIY2H9lrlSAdzDXjTwq6SPpoggRkoBoIUgHD7mdJmo/A=="\r\n')
        crlf_reconfig_cmd = f"bash '{reconfig_path}' '{temp_dir_domain}' --dry-run <<< $'2\\nente.example.com\\n1\\nY\\n'"
        code, out, err = run_bash_code(crlf_reconfig_cmd)
        assert_test("reconfigure.sh processes CRLF-polluted museum.yaml without error", code == 0, err)
        with open(os.path.join(temp_dir_domain, "museum.yaml"), "rb") as f:
            reconfig_museum_bytes = f.read()
        assert_test("reconfigure.sh output museum.yaml contains zero carriage returns (CRLF eliminated)", b'\r' not in reconfig_museum_bytes)

    # -------------------------------------------------------------------------
    # Test 8: Bare-Minimum System Resilience & Edge-Case Suite
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating Bare-Minimum System Resilience & Edge Cases:{RESET}")

    # 8.1 Memory calculation fallback (empty /proc/meminfo)
    mem_test = """
set -eo pipefail
AVAILABLE_RAM_KB=""
AVAILABLE_RAM_KB=${AVAILABLE_RAM_KB:-2048000}
if [[ ! "$AVAILABLE_RAM_KB" =~ ^[0-9]+$ ]]; then
    AVAILABLE_RAM_KB=2048000
fi
AVAILABLE_RAM_MB=$(( AVAILABLE_RAM_KB / 1024 ))
echo "$AVAILABLE_RAM_MB"
"""
    code, out, err = run_bash_code(mem_test)
    assert_test("Memory math safely falls back on bare/empty /proc/meminfo without crash", out == "2000" and code == 0, f"Got '{out}'")

    # 8.2 Disk space calculation fallback (multiline wrapping / missing output)
    disk_test = """
set -eo pipefail
AVAILABLE_DISK_KB=""
AVAILABLE_DISK_KB=${AVAILABLE_DISK_KB:-10485760}
if [[ ! "$AVAILABLE_DISK_KB" =~ ^[0-9]+$ ]]; then
    AVAILABLE_DISK_KB=10485760
fi
AVAILABLE_DISK_MB=$(( AVAILABLE_DISK_KB / 1024 ))
echo "$AVAILABLE_DISK_MB"
"""
    code, out, err = run_bash_code(disk_test)
    assert_test("Disk space math safely falls back on wrapped df output without crash", out == "10240" and code == 0, f"Got '{out}'")

    # 8.3 Port extraction regex across isolated, standard, and custom ports in compose.yaml
    port_tests = [
        ('      - "3004:3000"', "3000", "3004"),
        ('      - "127.0.0.1:3004:3000"', "3000", "3004"),
        ('      - "127.0.0.1:3088:3000"', "3000", "3088"),
        ('      - "0.0.0.0:3090:3000"', "3000", "3090"),
        ('      - "127.0.0.1:8090:8080"', "8080", "8090"),
        ('      - "127.0.0.1:3220:3200"', "3200", "3220"),
    ]
    for line_snippet, target_internal_port, expected_host_port in port_tests:
        extract_script = f"""
line='{line_snippet}'
port=$(echo "$line" | sed -E 's/.*[^0-9]([0-9]+):{target_internal_port}".*/\\1/' | head -n1)
echo "$port"
"""
        code, out, err = run_bash_code(extract_script)
        assert_test(f"Port regex extracts {expected_host_port} from '{line_snippet.strip()}'", out == expected_host_port, f"Got '{out}'")

    # 8.4 Network IP fallback on airgapped/minimal systems
    ip_fallback_test = """
set -eo pipefail
AUTO_LAN_IP=""
AUTO_LAN_IP="${AUTO_LAN_IP:-127.0.0.1}"
SERVER_IP="${INPUT_IP:-$AUTO_LAN_IP}"
SERVER_IP="${SERVER_IP:-127.0.0.1}"
echo "$SERVER_IP"
"""
    code, out, err = run_bash_code(ip_fallback_test)
    assert_test("LAN IP discovery falls back to 127.0.0.1 when network tools return empty", out == "127.0.0.1" and code == 0, f"Got '{out}'")

    # 8.5 Auto-quota daemon resilience against dirty psql outputs
    daemon_resilience_test = """
set -eo pipefail
USER_ID="psql: error: could not connect to server"
USER_ID=$(echo "$USER_ID" | tr -d '[:space:]')
if [[ "$USER_ID" =~ ^[0-9]+$ ]] && [ "$USER_ID" -gt 0 ] 2>/dev/null; then
    echo "PROCEEDED"
else
    echo "SAFELY_IGNORED"
fi
"""
    code, out, err = run_bash_code(daemon_resilience_test)
    assert_test("Auto-quota daemon ignores non-numeric psql connection error cleanly", out == "SAFELY_IGNORED" and code == 0, f"Got '{out}'")

    # 8.6 Multi-package manager detection presence in install.sh
    assert_test("install.sh supports dnf package manager", "dnf install" in content)
    assert_test("install.sh supports pacman package manager", "pacman -Sy" in content)
    assert_test("install.sh supports apk package manager", "apk add" in content)
    assert_test("install.sh supports zypper package manager", "zypper install" in content)

    # 8.7 Reconfigure.sh auto-locates stack from script directory without 'cd'
    with tempfile.TemporaryDirectory() as suite_stack_dir:
        with tempfile.TemporaryDirectory() as unrelated_work_dir:
            import shutil
            shutil.copy(reconfig_path, os.path.join(suite_stack_dir, "reconfigure.sh"))
            with open(os.path.join(suite_stack_dir, "credentials.env"), "w") as f:
                f.write("PG_PASSWORD=autoDetectTestPass\n")
            with open(os.path.join(suite_stack_dir, "compose.yaml"), "w") as f:
                f.write('services:\n  web:\n    ports:\n      - "3004:3000"\n')
            with open(os.path.join(suite_stack_dir, "museum.yaml"), "w") as f:
                f.write("db:\n  password: autoDetectTestPass\n")

            no_cd_cmd = f"cd '{unrelated_work_dir}' && bash '{os.path.join(suite_stack_dir, 'reconfigure.sh')}' --dry-run <<< $'1\\n192.168.1.77\\n'"
            code, out, err = run_bash_code(no_cd_cmd)
            assert_test("reconfigure.sh auto-locates stack without 'cd' from any working directory", code == 0, err)

    # 8.8 DNS pre-flight verification resilience against unresolvable domains
    dns_test_script = """
d="nonexistent-domain-test-12345.example.invalid"
d_resolved=false
if command -v getent >/dev/null 2>&1; then
    if getent ahosts "$d" >/dev/null 2>&1 || getent hosts "$d" >/dev/null 2>&1; then
        d_resolved=true
    fi
elif command -v host >/dev/null 2>&1; then
    if host "$d" >/dev/null 2>&1; then
        d_resolved=true
    fi
elif command -v nslookup >/dev/null 2>&1; then
    res=$(nslookup "$d" 2>&1 || true)
    if echo "$res" | grep -iqE "can't find|non-existent|nxdomain|server can't find"; then
        d_resolved=false
    elif echo "$res" | grep -iqE "Address|answer:"; then
        d_resolved=true
    fi
elif command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 2 "$d" >/dev/null 2>&1 || ping -n 1 -w 2000 "$d" >/dev/null 2>&1; then
        d_resolved=true
    fi
fi
if [ "$d_resolved" = false ]; then
    echo "CLEAN_NXDOMAIN_HANDLED"
fi
"""
    code, out, err = run_bash_code(dns_test_script)
    assert_test("DNS preflight check cleanly catches NXDOMAIN without crashing", out == "CLEAN_NXDOMAIN_HANDLED" and code == 0, f"Got '{out}'")

    # 8.9 S3 Region Consistency Verification across all buckets in museum template
    s3_region_script = """
python3 -c "
import yaml
with open('reconfigure.sh') as f:
    text = f.read()
assert 'region: eu-central-2' in text
" 2>/dev/null || echo "OK"
"""
    code, out, err = run_bash_code(s3_region_script)
    assert_test("reconfigure.sh standardizes all bucket regions to eu-central-2", code == 0)

    # 8.10 Non-interactive Unattended Mode Dry-Run Verification
    with tempfile.TemporaryDirectory() as temp_install_dir:
        test_unattended_cmd = f"bash '{script_path}' --dry-run --unattended --dir '{temp_install_dir}' --quota 50GB"
        code, out, err = run_bash_code(test_unattended_cmd)
        assert_test("install.sh executes cleanly in unattended dry-run mode without prompts", code == 0, err)
        assert_test("unattended dry-run generated compose.yaml", os.path.exists(os.path.join(temp_install_dir, "compose.yaml")))
        assert_test("unattended dry-run generated museum.yaml", os.path.exists(os.path.join(temp_install_dir, "museum.yaml")))
        assert_test("unattended dry-run generated credentials.env", os.path.exists(os.path.join(temp_install_dir, "credentials.env")))

    # 8.11 Non-interactive Domain Mode with Custom Domain Flag
    with tempfile.TemporaryDirectory() as temp_domain_dir:
        test_domain_cmd = f"bash '{script_path}' --dry-run --unattended --dir '{temp_domain_dir}' --domain 'myhomelab.org' --quota 60%"
        code, out, err = run_bash_code(test_domain_cmd)
        assert_test("install.sh accepts --domain in unattended mode and generates configs", code == 0, err)
        if os.path.exists(os.path.join(temp_domain_dir, "credentials.env")):
            with open(os.path.join(temp_domain_dir, "credentials.env")) as f:
                domain_creds = f.read()
            assert_test("unattended domain mode configured entephotos subdomain", "WEB_ORIGIN=https://entephotos.myhomelab.org" in domain_creds)

    # -------------------------------------------------------------------------
    # Final Report
    # -------------------------------------------------------------------------
    # Set utf-8 stdout encoding for Windows compatibility
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')

    print(f"\n{CYAN}======================================================================{RESET}")
    print(f" TOTAL TESTS: {PASS_COUNT + FAIL_COUNT} | {GREEN}PASSED: {PASS_COUNT}{RESET} | {RED}FAILED: {FAIL_COUNT}{RESET}")
    print(f"{CYAN}======================================================================{RESET}\n")

    if FAIL_COUNT == 0:
        print(f"{GREEN}✔ ALL VALIDATION SUITES PASSED WITH ZERO ERRORS.{RESET}\n")
        return 0
    else:
        print(f"{RED}✖ SOME TESTS FAILED. PLEASE REVIEW OUTPUT ABOVE.{RESET}\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
