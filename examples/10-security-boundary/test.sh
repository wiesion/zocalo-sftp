#!/bin/bash
# Security-boundary tests: hostile configuration, hostile SFTP clients, and
# configuration lifecycle. Unlike the other examples, which show that things
# work, this one tries to make them fail open.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
source "$LIB_DIR/test-helpers.sh"

EXAMPLE_NAME="10-security-boundary"
PORT=2222
USERS=("sheridan" "garibaldi" "ivanova")
IMAGE="${SFTP_IMAGE:-zocalo-sftp:test}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes)

#=============================================================================
# HELPERS
#=============================================================================
write_baseline_config() {
    mkdir -p "$SCRIPT_DIR/config"
    printf 'sheridan:1001\ngaribaldi:1002\nivanova:1003\n' > "$SCRIPT_DIR/config/sftp_users.conf"
    printf 'command-staff:2001:sheridan,ivanova\nsecurity:2002:garibaldi,ivanova\n' > "$SCRIPT_DIR/config/sftp_projects.conf"
    echo 1 > "$SCRIPT_DIR/config/.generation"
}

# Rewrite in place (not mv) and bump the generation counter.
set_config() {
    printf '%s\n' "$1" > "$SCRIPT_DIR/config/sftp_users.conf"
    printf '%s\n' "$2" > "$SCRIPT_DIR/config/sftp_projects.conf"
    printf '%s\n' "$(( $(cat "$SCRIPT_DIR/config/.generation") + 1 ))" > "$SCRIPT_DIR/config/.generation"
}

# Run sftp batch commands as a user; succeeds only if every command succeeds.
sftp_run() {
    local user="$1"; shift
    printf '%s\n' "$@" | sftp -b - "${SSH_OPTS[@]}" -P "$PORT" \
        -i "$SCRIPT_DIR/secrets/${user}_key" "$user@localhost" >/dev/null 2>&1
}

dexec() { (cd "$SCRIPT_DIR" && docker compose exec -T sftp sh -c "$1"); }

# wait_for <seconds> <command...>: poll until the command succeeds
wait_for() {
    local max="$1"; shift
    local waited=0
    while [ "$waited" -lt "$max" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1; waited=$((waited + 1))
    done
    return 1
}

expect_denied() {   # <description> <user> <sftp command>
    test_start "$1"
    if sftp_run "$2" "$3"; then test_fail "operation succeeded: $3"; else test_pass; fi
}

expect_allowed() {  # <description> <user> <sftp command>
    test_start "$1"
    if sftp_run "$2" "$3"; then test_pass; else test_fail "operation failed: $3"; fi
}

#=============================================================================
# A. HOSTILE CONFIGURATION: the container must refuse to start, mutating nothing
#=============================================================================
# expect_refusal <description> <expected-message-regex> <users> <projects> [ENV=VAL ...]
expect_refusal() {
    local desc="$1" pattern="$2" users="$3" projects="$4"; shift 4
    local cfg name out rc=0
    cfg=$(mktemp -d)
    name="zocalo-refusal-$$"
    printf '%s\n' "$users" > "$cfg/sftp_users.conf"
    printf '%s\n' "$projects" > "$cfg/sftp_projects.conf"
    if [ -n "${REFUSAL_DROPIN:-}" ]; then
        mkdir -p "$cfg/sshd_config.d"
        printf '%s\n' "$REFUSAL_DROPIN" > "$cfg/sshd_config.d/99-hostile.conf"
    fi
    local env_args=()
    for kv in "$@"; do env_args+=(-e "$kv"); done

    test_start "$desc"
    docker rm -f "$name" >/dev/null 2>&1 || true
    out=$(docker run --name "$name" ${env_args[@]+"${env_args[@]}"} \
        -v "$cfg:/config:ro" \
        -v "$SCRIPT_DIR/secrets/ssh_host_ed25519_key:/run/secrets/ssh_host_ed25519_key:ro" \
        "$IMAGE" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        test_fail "container started with hostile config"
    elif ! printf '%s' "$out" | grep -Eq "$pattern"; then
        test_fail "exited $rc but message did not match /$pattern/: $(printf '%s' "$out" | tail -3)"
    elif docker cp "$name:/etc/passwd" - 2>/dev/null | grep -Eq '^(sheridan|garibaldi|ivanova):'; then
        test_fail "/etc/passwd was modified before the config was rejected"
    else
        test_pass
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$cfg"
}

test_hostile_config() {
    log_step "A. Hostile configuration is refused before any mutation"
    local U=$'sheridan:1001\ngaribaldi:1002\nivanova:1003'
    local P=$'command-staff:2001:sheridan\nsecurity:2002:garibaldi'

    expect_refusal "Duplicate UID refused"            'UID 1001 assigned to both' $'sheridan:1001\ngaribaldi:1001' "$P"
    expect_refusal "Duplicate username refused"       'duplicate username'        $'sheridan:1001\nsheridan:1002' "$P"
    expect_refusal "Duplicate project name refused"   'duplicate project name'    "$U" $'command-staff:2001:sheridan\ncommand-staff:2002:garibaldi'
    expect_refusal "Duplicate project GID refused"    'GID 2001 assigned to both' "$U" $'command-staff:2001:sheridan\nsecurity:2001:garibaldi'
    expect_refusal "Project GID == SFTP_USERS_GID refused" 'equals SFTP_USERS_GID' "$U" 'command-staff:59999:sheridan'
    expect_refusal "Project GID == custom SFTP_USERS_GID refused" 'equals SFTP_USERS_GID' "$U" 'command-staff:2001:sheridan' SFTP_USERS_GID=2001
    expect_refusal "Reserved group name refused"      'reserved'                  "$U" 'sftp_users:2001:sheridan'
    expect_refusal "Reserved read-only group name refused" 'reserved'             "$U" 'sftp_ro:2001:sheridan'
    expect_refusal "Project GID == SFTP_READONLY_GID refused" 'equals SFTP_READONLY_GID' "$U" 'command-staff:59998:sheridan'
    expect_refusal "SFTP_READONLY_GID == SFTP_USERS_GID refused" 'must differ from SFTP_USERS_GID' "$U" "$P" SFTP_READONLY_GID=59999
    expect_refusal "Unknown user flag refused"        "unknown flag \"rw\""       $'sheridan:1001:rw' "$P"
    expect_refusal "Duplicate user flag refused"      'duplicate flag'            $'sheridan:1001:ro,ro' "$P"
    expect_refusal "Member name with separator refused" 'invalid member name'     "$U" 'command-staff:2001:sheridan:0:root'
    expect_refusal "World-accessible SFTP_PROJECT_MODE refused" "grants access to 'other'" "$U" "$P" SFTP_PROJECT_MODE=777
    expect_refusal "SFTP_PROJECT_MODE without group-execute refused" 'lacks group execute' "$U" "$P" SFTP_PROJECT_MODE=760

    # A Match block in a drop-in overrides global ChrootDirectory/ForceCommand
    # in sshd, so drop-ins touching the jail must be rejected outright.
    REFUSAL_DROPIN=$'Match User sheridan\n    ChrootDirectory none' \
        expect_refusal "Drop-in overriding ChrootDirectory refused" 'not allowed in drop-ins' "$U" "$P"
    REFUSAL_DROPIN=$'Match Group sftp_users\n    ForceCommand /bin/sh' \
        expect_refusal "Drop-in overriding ForceCommand refused"    'not allowed in drop-ins' "$U" "$P"
    REFUSAL_DROPIN='Include /tmp/*.conf' \
        expect_refusal "Drop-in with nested Include refused"        'not allowed in drop-ins' "$U" "$P"
}

#=============================================================================
# B. HOSTILE CLIENT: an authenticated non-member against a project
#=============================================================================
test_hostile_client() {
    log_step "B. Authenticated non-member (garibaldi) against project 'command-staff'"
    local secret="$SCRIPT_DIR/.test-temp-secret.txt"
    echo "command-staff-confidential" > "$secret"

    expect_allowed "sheridan (member) can write to command-staff" sheridan "put $secret command-staff/secret.txt"
    expect_allowed "garibaldi (member) can write to security"    garibaldi   "put $secret security/own.txt"

    expect_denied "garibaldi cannot list command-staff"            garibaldi "ls command-staff"
    expect_denied "garibaldi cannot stat a file in command-staff"  garibaldi "ls command-staff/secret.txt"
    expect_denied "garibaldi cannot download from command-staff"   garibaldi "get command-staff/secret.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "garibaldi cannot upload to command-staff"       garibaldi "put $secret command-staff/planted.txt"
    expect_denied "garibaldi cannot delete from command-staff"     garibaldi "rm command-staff/secret.txt"
    expect_denied "garibaldi cannot mkdir in command-staff"        garibaldi "mkdir command-staff/evil"
    expect_denied "garibaldi cannot rename out of command-staff"   garibaldi "rename command-staff/secret.txt security/stolen.txt"
    expect_denied "garibaldi cannot rename into command-staff"     garibaldi "rename security/own.txt command-staff/own.txt"
    expect_denied "garibaldi cannot symlink inside command-staff"  garibaldi "symlink x command-staff/link"
    expect_denied "garibaldi cannot chmod command-staff"           garibaldi "chmod 777 command-staff"
    expect_denied "garibaldi cannot hardlink command-staff's file into security" garibaldi "ln command-staff/secret.txt security/hardlink.txt"

    # A symlink garibaldi is allowed to create in his own project must not read through
    expect_allowed "garibaldi can create a symlink in his own project" garibaldi "symlink ../command-staff/secret.txt security/link"
    expect_denied  "symlink in security does not expose command-staff's file" garibaldi "get security/link $SCRIPT_DIR/.test-temp-stolen.txt"

    expect_denied "absolute path into command-staff is denied"   garibaldi "get /command-staff/secret.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "../ traversal to command-staff is denied"     garibaldi "get security/../command-staff/secret.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "jail has no /etc/passwd"              garibaldi "get /etc/passwd $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "traversal out of the jail is denied"  garibaldi "get ../../../../etc/passwd $SCRIPT_DIR/.test-temp-stolen.txt"

    test_start "garibaldi has no shell (ForceCommand internal-sftp)"
    local out
    out=$(ssh "${SSH_OPTS[@]}" -p "$PORT" -i "$SCRIPT_DIR/secrets/garibaldi_key" garibaldi@localhost id 2>&1 || true)
    if printf '%s' "$out" | grep -q 'uid='; then test_fail "command executed: $out"; else test_pass; fi

    test_start "no stolen data reached the client"
    if [ -e "$SCRIPT_DIR/.test-temp-stolen.txt" ]; then test_fail "stolen file exists"; else test_pass; fi

    test_start "command-staff's data is intact after all attempts"
    local back="$SCRIPT_DIR/.test-temp-back.txt"
    if sftp_run sheridan "get command-staff/secret.txt $back" && [ "$(cat "$back")" = "command-staff-confidential" ] \
        && ! dexec 'ls /sftp-jail/projects/command-staff' | grep -Eq 'planted|evil|stolen|hardlink'; then
        test_pass
    else
        test_fail "command-staff content changed"
    fi

    expect_allowed "ivanova (member of both) reads command-staff" ivanova "get command-staff/secret.txt $back"

    test_start "New files inherit the project group (setgid directory)"
    if [ "$(dexec 'stat -c %g /sftp-jail/projects/command-staff/secret.txt')" = "2001" ]; then
        test_pass
    else
        test_fail "group is $(dexec 'stat -c %g /sftp-jail/projects/command-staff/secret.txt'), expected 2001"
    fi
    rm -f "$secret" "$back"
}

#=============================================================================
# C. DRIFT: existing project directories are re-asserted
#=============================================================================
project_dir_state() { dexec "stat -c '%u:%g:%a' /sftp-jail/projects/$1" 2>/dev/null | tr -d '[:space:]'; }

test_drift_repair() {
    log_step "C. Drifted project directories are repaired"

    # chmod first: after chown the dir is owned by 9999 and the container has no CAP_FOWNER
    dexec 'chmod 777 /sftp-jail/projects/command-staff && chown 9999:9999 /sftp-jail/projects/command-staff'
    test_start "Corrupted command-staff (9999:9999 mode 777) is repaired to 0:2001 mode 2770"
    if wait_for 25 bash -c "[ \"\$(cd '$SCRIPT_DIR' && docker compose exec -T sftp stat -c '%u:%g:%a' /sftp-jail/projects/command-staff | tr -d '[:space:]')\" = '0:2001:2770' ]"; then
        test_pass
    else
        test_fail "state is $(project_dir_state command-staff)"
    fi

    test_start "garibaldi is still denied after repair"
    if sftp_run garibaldi "ls command-staff"; then test_fail "garibaldi can list command-staff"; else test_pass; fi

    # A symlink planted where a project directory should be must not be followed
    dexec 'rm -rf /sftp-jail/projects/security && ln -s /etc /sftp-jail/projects/security'
    sleep 12
    test_start "Symlink planted as project directory does not redirect chown/chmod"
    if [ "$(dexec 'stat -c %a /etc')" = "755" ] && [ "$(dexec 'stat -c %u:%g /etc')" = "0:0" ]; then
        test_pass
    else
        test_fail "/etc was modified through the symlink"
    fi
    dexec 'rm -f /sftp-jail/projects/security'
    test_start "Missing project directory is re-created after removal"
    set_config $'sheridan:1001\ngaribaldi:1002\nivanova:1003' $'command-staff:2001:sheridan,ivanova\nsecurity:2002:garibaldi,ivanova'
    if wait_for 25 bash -c "[ \"\$(cd '$SCRIPT_DIR' && docker compose exec -T sftp stat -c '%u:%g:%a' /sftp-jail/projects/security | tr -d '[:space:]')\" = '0:2002:2770' ]"; then
        test_pass
    else
        test_fail "state is $(project_dir_state security)"
    fi
}

#=============================================================================
# D. LIFECYCLE: removing and re-using identities must revoke access
#=============================================================================
test_lifecycle() {
    log_step "D. Lifecycle: removal revokes, GID reuse does not resurrect access"
    local f="$SCRIPT_DIR/.test-temp-life.txt"
    echo "security-data" > "$f"
    sftp_run garibaldi "put $f security/before-removal.txt" || true

    local U=$'sheridan:1001\ngaribaldi:1002\nivanova:1003'

    # Remove security (GID 2002)
    set_config "$U" 'command-staff:2001:sheridan,ivanova'
    test_start "Removed project's group is deleted from /etc/group"
    if wait_for 25 bash -c "! (cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^security:' /etc/group)"; then
        test_pass
    else
        test_fail "group security still present"
    fi

    test_start "Removed project's directory is locked to root:root 0700"
    if wait_for 25 bash -c "[ \"\$(cd '$SCRIPT_DIR' && docker compose exec -T sftp stat -c '%u:%g:%a' /sftp-jail/projects/security | tr -d '[:space:]')\" = '0:0:700' ]"; then
        test_pass
    else
        test_fail "state is $(project_dir_state security)"
    fi

    expect_denied "garibaldi lost access to the removed project" garibaldi "get security/before-removal.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "ivanova lost access to the removed project" ivanova "ls security"

    # Reuse GID 2002 for a new project with different members
    set_config "$U" $'command-staff:2001:sheridan,ivanova\ngamma:2002:sheridan'
    test_start "New project 'gamma' reusing GID 2002 is created"
    wait_for 25 bash -c "(cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^gamma:x:2002:sheridan' /etc/group)" \
        && test_pass || test_fail "gamma not created"

    expect_allowed "sheridan (gamma member) can write to gamma" sheridan "put $f gamma/ok.txt"
    expect_denied  "garibaldi cannot reach gamma"                  garibaldi   "ls gamma"
    expect_denied  "old security data stays sealed despite GID reuse" sheridan "get security/before-removal.txt $SCRIPT_DIR/.test-temp-stolen.txt"

    # Disable and re-enable
    set_config $'sheridan:1001\ngaribaldi:1002:disabled\nivanova:1003' $'command-staff:2001:sheridan,ivanova\ngamma:2002:sheridan'
    test_start "Disabled user cannot log in"
    wait_for 25 bash -c "! sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes -P $PORT -i '$SCRIPT_DIR/secrets/garibaldi_key' garibaldi@localhost <<< pwd" \
        && test_pass || test_fail "garibaldi can still log in"

    set_config $'sheridan:1001\ngaribaldi:1002\nivanova:1003' $'command-staff:2001:sheridan,ivanova\ngamma:2002:sheridan'
    test_start "Re-enabled user can log in again"
    wait_for 25 bash -c "sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes -P $PORT -i '$SCRIPT_DIR/secrets/garibaldi_key' garibaldi@localhost <<< pwd" \
        && test_pass || test_fail "garibaldi cannot log in"

    rm -f "$f"
}

#=============================================================================
# E. INVALID RUNTIME CONFIG: nothing is applied, last good state is kept
#=============================================================================
test_invalid_runtime_config() {
    log_step "E. Invalid config pushed at runtime is rejected as a whole"
    local before after
    before=$(dexec 'cat /etc/group /etc/passwd')

    # Duplicate GID plus a legitimate new user in the same push
    set_config $'sheridan:1001\ngaribaldi:1002\nivanova:1003\ndave:1004' $'command-staff:2001:sheridan,ivanova\ngamma:2002:sheridan\ndelta:2002:dave'
    sleep 12
    test_start "Duplicate-GID config applies nothing (no delta, no dave)"
    after=$(dexec 'cat /etc/group /etc/passwd')
    if [ "$before" = "$after" ]; then test_pass; else test_fail "state changed:
$(diff <(printf '%s' "$before") <(printf '%s' "$after"))"; fi

    test_start "Rejection is logged"
    local logs
    logs=$(cd "$SCRIPT_DIR" && docker compose logs sftp 2>&1)
    if printf '%s' "$logs" | grep -q 'reconcile skipped'; then test_pass; else test_fail "no 'reconcile skipped' in logs"; fi

    test_start "Unreadable duplicate state did not lock anyone out"
    if sftp_run sheridan "pwd"; then test_pass; else test_fail "sheridan locked out"; fi

    # Removing a user who is still listed in a project must still revoke them,
    # and the stale reference must not grant anything or block the reconcile.
    set_config $'sheridan:1001\ngaribaldi:1002' $'command-staff:2001:sheridan,ivanova\ngamma:2002:sheridan'
    test_start "Removed user still listed in a project is locked and dropped from the group"
    if wait_for 25 bash -c "(cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^ivanova:!' /etc/shadow)" \
        && [ "$(dexec "awk -F: '\$1==\"command-staff\"{print \$4}' /etc/group" | tr -d '[:space:]')" = "sheridan" ]; then
        test_pass
    else
        test_fail "ivanova not locked or still in command-staff: $(dexec 'grep ^command-staff: /etc/group; grep ^ivanova: /etc/shadow')"
    fi
    expect_denied "Removed user cannot log in" ivanova "pwd"

    # Restore a valid config
    set_config $'sheridan:1001\ngaribaldi:1002\nivanova:1003' $'command-staff:2001:sheridan,ivanova\ngamma:2002:sheridan'
    wait_for 25 bash -c "! (cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^ivanova:!' /etc/shadow)" || true
}

#=============================================================================
# F. RESTART: state converges and config is revalidated
#=============================================================================
test_restart() {
    log_step "F. Restart"
    (cd "$SCRIPT_DIR" && docker compose restart sftp >/dev/null 2>&1)
    test_start "Container comes back after restart with the reconciled config"
    if wait_for 30 ssh-keyscan -t ed25519 -p "$PORT" -T 1 127.0.0.1 \
        && wait_for 20 sftp_run sheridan "ls gamma"; then
        test_pass
    else
        test_fail "service did not recover"
    fi
    expect_denied "garibaldi is still denied gamma after restart" garibaldi "ls gamma"
}

#=============================================================================
# MAIN
#=============================================================================
main() {
    log_step "Starting tests for $EXAMPLE_NAME"
    setup_test_environment "$SCRIPT_DIR"
    rm -rf "$SCRIPT_DIR/config"
    write_baseline_config

    generate_host_key "$SCRIPT_DIR/secrets"
    for user in "${USERS[@]}"; do generate_user_key "$SCRIPT_DIR/secrets" "$user"; done

    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"
    IMAGE="${SFTP_IMAGE:-zocalo-sftp:test}"

    test_hostile_config

    (cd "$SCRIPT_DIR" && docker_compose_up "$PORT")
    test_hostile_client
    test_drift_repair
    test_lifecycle
    test_invalid_runtime_config
    test_restart

    (cd "$SCRIPT_DIR" && docker_compose_down)
    cleanup_all "$SCRIPT_DIR"
    rm -rf "$SCRIPT_DIR/config"

    echo
    test_summary
    exit $?
}

main
