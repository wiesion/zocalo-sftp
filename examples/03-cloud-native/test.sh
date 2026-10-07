#!/bin/bash
# Automated test script for 03-cloud-native example
# Tests cloud-native features: metrics, log shipping to Vector, health checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
source "$LIB_DIR/test-helpers.sh"

EXAMPLE_NAME="03-cloud-native"
USERS=("londo" "vir")
PROJECT="centauri-republic"
PORT=2222
METRICS_PORT=9100

#=============================================================================
# MAIN TEST FLOW
#=============================================================================
main() {
    log_step "Starting tests for $EXAMPLE_NAME"

    setup_test_environment "$SCRIPT_DIR"

    log_step "Preparing environment"
    generate_host_key "$SCRIPT_DIR/secrets"
    for user in "${USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
    done

    # Create config files that the compose volume mounts expect.
    # The reconcile loop watches these files for changes.
    mkdir -p "$SCRIPT_DIR/config"
    printf 'londo:1001\nvir:1002\n' > "$SCRIPT_DIR/config/sftp_users.conf"
    printf '%s:2001:londo,vir\n' "$PROJECT" > "$SCRIPT_DIR/config/sftp_projects.conf"
    printf '0\n' > "$SCRIPT_DIR/config/.generation"

    # Vector writes its structured output here (bind mount, see compose.yml).
    mkdir -p "$SCRIPT_DIR/vector-output"

    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"
    (cd "$SCRIPT_DIR" && docker_compose_up "$PORT")

    run_tests

    rm -f "$SCRIPT_DIR/config/sftp_users.conf" \
          "$SCRIPT_DIR/config/sftp_projects.conf" \
          "$SCRIPT_DIR/config/.generation"
    rm -rf "$SCRIPT_DIR/vector-output"
    cleanup_all "$SCRIPT_DIR"

    echo
    test_summary
    exit $?
}

#=============================================================================
# TEST CASES
#=============================================================================
run_tests() {
    log_step "Running test cases"

    test_user_authentication
    test_basic_functionality
    test_metrics_endpoint
    test_metrics_active_connections
    test_metrics_disabled
    test_health_check
    test_runtime_reconciliation
    test_log_shipping
}

test_user_authentication() {
    for user in "${USERS[@]}"; do
        test_start "User $user can authenticate"
        if sftp_connect_test "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT"; then
            test_pass
        else
            test_fail "Authentication failed for $user"
        fi
    done
}

test_basic_functionality() {
    local test_file="$SCRIPT_DIR/.test-temp-centauri.txt"
    printf 'Centauri data\n' > "$test_file"

    test_start "Londo can upload file"
    if sftp_put_file "londo" "$SCRIPT_DIR/secrets/londo_key" "$test_file" "$PROJECT/test.txt" "$PORT"; then
        test_pass
    else
        test_fail "Upload failed"
        rm -f "$test_file"
        return
    fi

    test_start "Vir can access file from Londo"
    if sftp_check_file_exists "vir" "$SCRIPT_DIR/secrets/vir_key" "$PROJECT/test.txt" "$PORT"; then
        test_pass
    else
        test_fail "File not accessible"
    fi

    sftp_delete_file "vir" "$SCRIPT_DIR/secrets/vir_key" "$PROJECT/test.txt" "$PORT" 2>/dev/null || true
    rm -f "$test_file"
}

test_metrics_endpoint() {
    # Socat binds before sshd in the entrypoint but is started with &, so
    # allow a brief grace period for the OS to schedule the socat process.
    test_start "Metrics endpoint is accessible"
    local waited=0
    while [ "$waited" -lt 10 ]; do
        if curl -sf "http://localhost:$METRICS_PORT/metrics" >/dev/null 2>&1; then break; fi
        sleep 1; waited=$((waited + 1))
    done
    if [ "$waited" -ge 10 ]; then test_fail "Metrics endpoint not responding after 10s"; return; fi
    test_pass

    # Prometheus requires Content-Type: text/plain; version=0.0.4 to parse correctly
    test_start "Metrics Content-Type header is Prometheus-compatible"
    local ct
    ct=$(curl -sI "http://localhost:$METRICS_PORT/metrics" \
        | grep -i "^content-type:" | tr -d '\r' || true)
    if printf '%s' "$ct" | grep -q 'text/plain' && printf '%s' "$ct" | grep -q 'version=0.0.4'; then
        test_pass
    else
        test_fail "Expected text/plain; version=0.0.4, got: ${ct:-<none>}"
    fi

    local metrics
    metrics=$(curl -s "http://localhost:$METRICS_PORT/metrics")

    # All six metric families must be present
    test_start "All expected metric names are present"
    local name missing=""
    for name in sftp_active_connections sftp_active_users \
                sftp_disk_used_kb sftp_disk_available_kb sftp_disk_total_kb \
                sftp_project_disk_kb; do
        printf '%s\n' "$metrics" | grep -q "^$name" || missing="$missing $name"
    done
    if [ -z "$missing" ]; then test_pass; else test_fail "Missing:$missing"; fi

    # HELP and TYPE lines must be present for Prometheus to accept the format
    test_start "Metrics are in Prometheus exposition format (# HELP / # TYPE)"
    if printf '%s\n' "$metrics" | grep -q '^# HELP' && \
       printf '%s\n' "$metrics" | grep -q '^# TYPE'; then
        test_pass
    else
        test_fail "Missing # HELP or # TYPE lines"
    fi

    # Every sample line must have a numeric value, catch broken substitutions
    # (e.g. empty variable producing "sftp_disk_used_kb ") before Prometheus does
    test_start "All metric sample values are numeric"
    local bad
    bad=$(printf '%s\n' "$metrics" | awk '
        /^#/ || /^$/ { next }
        { if ($2 !~ /^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/)
              print "Non-numeric value in: " $0 }
    ')
    if [ -z "$bad" ]; then test_pass; else test_fail "$bad"; fi

    # Per-project metric must be labelled with the actual project name
    test_start "Per-project disk metric present for project $PROJECT"
    if printf '%s\n' "$metrics" | grep -q "sftp_project_disk_kb{project=\"$PROJECT\"}"; then
        test_pass
    else
        test_fail "sftp_project_disk_kb{project=\"$PROJECT\"} not found in metrics output"
    fi
}

test_metrics_active_connections() {
    local fifo sftp_pid metrics conns users_count
    fifo=$(mktemp -u /tmp/sftp_test_fifo_XXXXXX)
    mkfifo "$fifo"

    # Background sftp BEFORE opening the write end so it does not inherit fd 9.
    # sftp's open() on the FIFO blocks until we open the write end below.
    sftp -b "$fifo" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -P "$PORT" -i "$SCRIPT_DIR/secrets/londo_key" \
        "londo@localhost" >/dev/null 2>&1 &
    sftp_pid=$!

    # Now open the write end. sftp's open() unblocks, session begins.
    # Since sftp was forked before this line, it cannot inherit fd 9,
    # so exec 9>&- later is the sole remaining write end → delivers EOF.
    exec 9>"$fifo"
    sleep 3  # allow SSH handshake and sftp subsystem negotiation to complete

    metrics=$(curl -s "http://localhost:$METRICS_PORT/metrics")

    test_start "sftp_active_connections reflects live session (>= 1)"
    conns=$(printf '%s\n' "$metrics" | awk '/^sftp_active_connections /{print $2}')
    if [ -n "$conns" ] && [ "$conns" -ge 1 ] 2>/dev/null; then
        test_pass
    else
        test_fail "Expected >= 1, got: '${conns:-empty}'"
    fi

    test_start "sftp_active_users reflects live session (>= 1)"
    users_count=$(printf '%s\n' "$metrics" | awk '/^sftp_active_users /{print $2}')
    if [ -n "$users_count" ] && [ "$users_count" -ge 1 ] 2>/dev/null; then
        test_pass
    else
        test_fail "Expected >= 1, got: '${users_count:-empty}'"
    fi

    # Closing fd 9 removes the only write end → sftp gets EOF → session closes
    exec 9>&-
    rm -f "$fifo"
    wait "$sftp_pid" 2>/dev/null || true
    sleep 1  # let sshd reap the session before next scrape

    metrics=$(curl -s "http://localhost:$METRICS_PORT/metrics")

    test_start "sftp_active_connections drops to 0 after session ends"
    conns=$(printf '%s\n' "$metrics" | awk '/^sftp_active_connections /{print $2}')
    if [ "${conns:-0}" -eq 0 ] 2>/dev/null; then
        test_pass
    else
        test_fail "Expected 0, got: '${conns:-empty}'"
    fi
}

test_metrics_disabled() {
    # Spin up a throwaway container with SFTP_ENABLE_METRICS omitted (defaults to
    # "no") and verify that nothing binds port 9100 inside the container.
    test_start "Metrics port not listening when SFTP_ENABLE_METRICS=no (default)"

    local key_file cid
    key_file=$(mktemp /tmp/sftp_metrics_test_XXXXXX)
    rm -f "$key_file"
    ssh-keygen -t ed25519 -f "$key_file" -N "" -q

    cid=$(docker run -d \
        -v "${key_file}:/run/secrets/ssh_host_ed25519_key:ro" \
        "${SFTP_IMAGE:-zocalo-sftp:test}")

    # Wait until sshd is listening before checking the metrics port
    local waited=0
    while [ "$waited" -lt 20 ]; do
        if docker exec "$cid" sh -c \
            'timeout 1 socat /dev/null TCP4:127.0.0.1:22 2>/dev/null'; then break; fi
        sleep 1; waited=$((waited + 1))
    done

    # socat exits 0 when it can connect (port open), non-zero on ECONNREFUSED
    if docker exec "$cid" sh -c \
        'timeout 1 socat /dev/null TCP4:127.0.0.1:9100 2>/dev/null'; then
        test_fail "Port 9100 is listening when SFTP_ENABLE_METRICS=no"
    else
        test_pass
    fi

    docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -f "$key_file" "${key_file}.pub"
}

test_log_shipping() {
    # The container itself emits plain text (see README.md#logging); this
    # test verifies the *shipped* side of that story: Vector (running as a
    # compose service, see vector.toml) reading the sftp container's stdout
    # via the Docker Engine API and structuring it, not anything the
    # container does itself.
    local out_file="$SCRIPT_DIR/vector-output/sftp-structured.log"

    # Perform an SFTP operation so internal-sftp writes a fresh line for
    # Vector to pick up, and so there's a source=sftp entry with a pid to
    # check, not just whatever happened to occur at container startup.
    local tmp_file="$SCRIPT_DIR/.test-log-probe.txt"
    printf 'log probe\n' > "$tmp_file"
    sftp_put_file "londo" "$SCRIPT_DIR/secrets/londo_key" \
        "$tmp_file" "$PROJECT/log-probe.txt" "$PORT" >/dev/null 2>&1 || true
    sftp_delete_file "londo" "$SCRIPT_DIR/secrets/londo_key" \
        "$PROJECT/log-probe.txt" "$PORT" >/dev/null 2>&1 || true
    rm -f "$tmp_file"

    test_start "Vector produces structured output for the sftp container"
    local waited=0 max_wait=20
    while [ "$waited" -lt "$max_wait" ]; do
        if [ -s "$out_file" ]; then test_pass; break; fi
        sleep 1; waited=$((waited + 1))
    done
    if [ "$waited" -ge "$max_wait" ]; then
        test_fail "$out_file not found or empty after ${max_wait}s"
        return
    fi

    test_start "Vector output is valid, parseable JSON"
    local parse_errors
    parse_errors=$(python3 -c '
import sys, json
errs = []
with open(sys.argv[1]) as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            json.loads(line)
        except json.JSONDecodeError as e:
            errs.append(f"line {i}: {e}: {line[:80]}")
if errs:
    print("\n".join(errs), file=sys.stderr)
    sys.exit(1)
' "$out_file" 2>&1 || true)
    if [ -z "$parse_errors" ]; then
        test_pass
    else
        test_fail "Invalid JSON in vector output: $parse_errors"
        return
    fi

    test_start "Entries contain required fields (timestamp, source, level, message)"
    local field_errors
    field_errors=$(python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        missing = [f for f in ("timestamp", "source", "level", "message") if f not in obj]
        if missing:
            print("Missing fields " + str(missing) + " in: " + line[:120], file=sys.stderr)
            sys.exit(1)
' "$out_file" 2>&1 || true)
    if [ -z "$field_errors" ]; then
        test_pass
    else
        test_fail "$field_errors"
        return
    fi

    test_start "sshd entries present (source=sshd)"
    if python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line and json.loads(line).get("source") == "sshd":
            sys.exit(0)
sys.exit(1)
' "$out_file" 2>/dev/null; then
        test_pass
    else
        test_fail "No entries with source=sshd found"
    fi

    test_start "sftp entries present with pid extracted and header stripped (source=sftp)"
    if python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("source") != "sftp":
            continue
        if not isinstance(obj.get("pid"), int):
            continue
        if "internal-sftp[" in obj.get("message", ""):
            continue  # header should have been parsed out, not left in message
        sys.exit(0)
sys.exit(1)
' "$out_file" 2>/dev/null; then
        test_pass
    else
        test_fail "No well-formed source=sftp entry found (pid missing, or header not stripped from message)"
    fi

    test_start "reconciled entries present (source=reconciled, from runtime reconciliation above)"
    if python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line and json.loads(line).get("source") == "reconciled":
            sys.exit(0)
sys.exit(1)
' "$out_file" 2>/dev/null; then
        test_pass
    else
        test_fail "No entries with source=reconciled found"
    fi
}

test_health_check() {
    test_start "Container health check is healthy"

    local max_wait=60 waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if (cd "$SCRIPT_DIR" && docker compose ps sftp 2>&1) | grep -q "(healthy)"; then
            test_pass
            return
        fi
        sleep 2; waited=$((waited + 2))
    done
    test_fail "Container not healthy after ${max_wait}s"
}

test_runtime_reconciliation() {
    log_step "Runtime reconciliation tests (SFTP_RECONCILE_INTERVAL=5)"
    local cid max_wait=20 waited

    cid=$(cd "$SCRIPT_DIR" && docker compose ps -q sftp)

    # ── User add ──────────────────────────────────────────────────────────────
    printf 'narn:1003\n' >> "$SCRIPT_DIR/config/sftp_users.conf"
    printf '%s\n' "$(( $(cat "$SCRIPT_DIR/config/.generation") + 1 ))" \
        > "$SCRIPT_DIR/config/.generation"

    test_start "New user 'narn' added to /etc/passwd within reconcile interval"
    waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if docker exec "$cid" grep -q "^narn:" /etc/passwd 2>/dev/null; then
            test_pass; break
        fi
        sleep 1; waited=$((waited + 1))
    done
    if [ "$waited" -ge "$max_wait" ]; then test_fail "narn not found in /etc/passwd after ${max_wait}s"; fi

    # ── User remove (lock) ────────────────────────────────────────────────────
    _c=$(awk '!/^vir:/' "$SCRIPT_DIR/config/sftp_users.conf")
    printf '%s\n' "$_c" > "$SCRIPT_DIR/config/sftp_users.conf"
    printf '%s\n' "$(( $(cat "$SCRIPT_DIR/config/.generation") + 1 ))" \
        > "$SCRIPT_DIR/config/.generation"

    test_start "Removed user 'vir' is locked in /etc/shadow within reconcile interval"
    waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if docker exec "$cid" grep -q "^vir:!" /etc/shadow 2>/dev/null; then
            test_pass; break
        fi
        sleep 1; waited=$((waited + 1))
    done
    if [ "$waited" -ge "$max_wait" ]; then test_fail "vir not locked in /etc/shadow after ${max_wait}s"; fi

    # ── Project add ───────────────────────────────────────────────────────────
    printf 'narn-homeworld:2002:narn\n' >> "$SCRIPT_DIR/config/sftp_projects.conf"
    printf '%s\n' "$(( $(cat "$SCRIPT_DIR/config/.generation") + 1 ))" \
        > "$SCRIPT_DIR/config/.generation"

    test_start "New project 'narn-homeworld' group created in /etc/group"
    waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if docker exec "$cid" grep -q "^narn-homeworld:" /etc/group 2>/dev/null; then
            test_pass; break
        fi
        sleep 1; waited=$((waited + 1))
    done
    if [ "$waited" -ge "$max_wait" ]; then test_fail "narn-homeworld group not found after ${max_wait}s"; fi

    test_start "Project directory /sftp-jail/projects/narn-homeworld created"
    if docker exec "$cid" test -d /sftp-jail/projects/narn-homeworld 2>/dev/null; then
        test_pass
    else
        test_fail "directory not found"
    fi

    test_start "User 'narn' is member of 'narn-homeworld' group"
    local members
    members=$(docker exec "$cid" awk -F: '$1=="narn-homeworld"{print $4}' /etc/group 2>/dev/null)
    if printf '%s' "$members" | grep -q "narn"; then
        test_pass
    else
        test_fail "expected narn in members, got: '${members}'"
    fi

    # ── disabled flag ─────────────────────────────────────────────────────────
    _c=$(awk -F: '$1=="narn"{print $1":"$2":disabled"; next} {print}' \
        "$SCRIPT_DIR/config/sftp_users.conf")
    printf '%s\n' "$_c" > "$SCRIPT_DIR/config/sftp_users.conf"
    printf '%s\n' "$(( $(cat "$SCRIPT_DIR/config/.generation") + 1 ))" \
        > "$SCRIPT_DIR/config/.generation"

    test_start "Disabled user 'narn' is locked in /etc/shadow"
    waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if docker exec "$cid" grep -q "^narn:!" /etc/shadow 2>/dev/null; then
            test_pass; break
        fi
        sleep 1; waited=$((waited + 1))
    done
    if [ "$waited" -ge "$max_wait" ]; then test_fail "narn not locked after ${max_wait}s"; fi

    # ── re-enable ─────────────────────────────────────────────────────────────
    _c=$(awk -F: 'BEGIN{OFS=":"} $1=="narn"{$3=""} NF==3 && $3==""{print $1":"$2; next} {print}' \
        "$SCRIPT_DIR/config/sftp_users.conf")
    printf '%s\n' "$_c" > "$SCRIPT_DIR/config/sftp_users.conf"
    printf '%s\n' "$(( $(cat "$SCRIPT_DIR/config/.generation") + 1 ))" \
        > "$SCRIPT_DIR/config/.generation"

    test_start "Re-enabled user 'narn' is unlocked in /etc/shadow"
    waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if ! docker exec "$cid" grep -q "^narn:!" /etc/shadow 2>/dev/null; then
            test_pass; break
        fi
        sleep 1; waited=$((waited + 1))
    done
    if [ "$waited" -ge "$max_wait" ]; then test_fail "narn still locked after ${max_wait}s"; fi
}

#=============================================================================
# RUN
#=============================================================================
main
