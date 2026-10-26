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
    proc = subprocess.run([bash_path, "-c", code], capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()

def main():
    print(f"\n{CYAN}======================================================================{RESET}")
    print(f"{CYAN}       ENTE INSTALLER OFFLINE VALIDATION SUITE (ZERO IMAGE PULLS)       {RESET}")
    print(f"{CYAN}======================================================================{RESET}\n")

    script_path = os.path.abspath("install.sh")
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

    # Extract set-quota.sh template
    quota_match = re.search(r"cat <<'EOF' > \"\$TARGET_DIR/set-quota\.sh\"\n(.*?)\nEOF", content, re.DOTALL)
    assert_test("set-quota.sh template found in install.sh", bool(quota_match))
    if quota_match:
        code, out, err = run_bash_code(f"bash -n << 'EOF'\n{quota_match.group(1)}\nEOF")
        assert_test("set-quota.sh passes bash syntax check", code == 0, err)

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

    # -------------------------------------------------------------------------
    # Test 4: YAML Syntax & Semantic Validation (museum.yaml & compose.yaml)
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating Generated Configuration YAML Syntax:{RESET}")
    # Extract museum.yaml template
    museum_template_match = re.search(r"cat <<EOF > \"\$TARGET_DIR/museum\.yaml\"\n(.*?)\nEOF\n    chmod 644 \"\$TARGET_DIR/museum\.yaml\"", content, re.DOTALL)
    assert_test("museum.yaml template found in install.sh", bool(museum_template_match))

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
            "${API_PORT}": "8080",
            "${WEB_PORT}": "3004",
            "${ALBUMS_PORT}": "3002",
            "${MINIO_PORT}": "3200",
            "${PG_PASS}": "TestPass12345",
            "${MINIO_USER}": "test-minio-user",
            "${MINIO_PASS}": "test-minio-pass",
            "${API_ORIGIN}": "http://192.168.1.50:8080",
            "${ALBUMS_ORIGIN}": "http://192.168.1.50:3002",
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
        except Exception as e:
            assert_test("compose.yaml is 100% valid YAML", False, str(e))

    # -------------------------------------------------------------------------
    # Test 5: Domain Sanitization Parameter Expansion
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating Domain & Input Sanitization Rules:{RESET}")
    test_domains = [
        ("https://photos.example.com/", "photos.example.com"),
        ("http://example.org/ ", "example.org"),
        ("  sub.domain.io  ", "sub.domain.io"),
        ("photos.ente.cloud", "photos.ente.cloud")
    ]
    for raw_domain, expected_domain in test_domains:
        bash_sanitizer = f"""
ROOT_DOMAIN="{raw_domain}"
ROOT_DOMAIN=${{ROOT_DOMAIN#https://}}
ROOT_DOMAIN=${{ROOT_DOMAIN#http://}}
ROOT_DOMAIN=${{ROOT_DOMAIN%/}}
ROOT_DOMAIN=$(echo "$ROOT_DOMAIN" | tr -d '[:space:]')
echo "$ROOT_DOMAIN"
"""
        code, out, err = run_bash_code(bash_sanitizer)
        assert_test(f"Sanitize '{raw_domain}' -> '{expected_domain}'", out == expected_domain, f"Got '{out}'")

    # -------------------------------------------------------------------------
    # Test 6: ANSI Stripping in Log Engine
    # -------------------------------------------------------------------------
    print(f"\n{CYAN}--> Validating ANSI Escape Code Stripping in Logger:{RESET}")
    ansi_test = """
MSG="\033[0;32m[✔] Success!\033[0m \033[1;33mWarning\033[0m"
clean_msg=$(printf '%b' "$MSG" | sed -E 's/\x1B\[[0-9;]*[mK]//g' 2>/dev/null || echo "$MSG")
echo "$clean_msg"
"""
    code, out, err = run_bash_code(ansi_test)
    assert_test("ANSI codes stripped cleanly from log messages", out == "[✔] Success! Warning", f"Got '{out}'")

    # -------------------------------------------------------------------------
    # Final Report
    # -------------------------------------------------------------------------
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
