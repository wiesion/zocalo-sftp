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
USERS=("alice" "bob" "carol")
IMAGE="${SFTP_IMAGE:-zocalo-sftp:test}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes)

#=============================================================================
# HELPERS
#=============================================================================
write_baseline_config() {
    mkdir -p "$SCRIPT_DIR/config"
    printf 'alice:1001\nbob:1002\ncarol:1003\n' > "$SCRIPT_DIR/config/sftp_users.conf"
    printf 'alpha:2001:alice,carol\nbeta:2002:bob,carol\n' > "$SCRIPT_DIR/config/sftp_projects.conf"
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
    elif docker cp "$name:/etc/passwd" - 2>/dev/null | grep -Eq '^(alice|bob|carol):'; then
        test_fail "/etc/passwd was modified before the config was rejected"
    else
        test_pass
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$cfg"
}

test_hostile_config() {
    log_step "A. Hostile configuration is refused before any mutation"
    local U=$'alice:1001\nbob:1002\ncarol:1003'
    local P=$'alpha:2001:alice\nbeta:2002:bob'

    expect_refusal "Duplicate UID refused"            'UID 1001 assigned to both' $'alice:1001\nbob:1001' "$P"
    expect_refusal "Duplicate username refused"       'duplicate username'        $'alice:1001\nalice:1002' "$P"
    expect_refusal "Duplicate project name refused"   'duplicate project name'    "$U" $'alpha:2001:alice\nalpha:2002:bob'
    expect_refusal "Duplicate project GID refused"    'GID 2001 assigned to both' "$U" $'alpha:2001:alice\nbeta:2001:bob'
    expect_refusal "Project GID == SFTP_USERS_GID refused" 'equals SFTP_USERS_GID' "$U" 'alpha:59999:alice'
    expect_refusal "Project GID == custom SFTP_USERS_GID refused" 'equals SFTP_USERS_GID' "$U" 'alpha:2001:alice' SFTP_USERS_GID=2001
    expect_refusal "Reserved group name refused"      'reserved'                  "$U" 'sftp_users:2001:alice'
    expect_refusal "Member name with separator refused" 'invalid member name'     "$U" 'alpha:2001:alice:0:root'
    expect_refusal "World-accessible SFTP_PROJECT_MODE refused" "grants access to 'other'" "$U" "$P" SFTP_PROJECT_MODE=777
    expect_refusal "SFTP_PROJECT_MODE without group-execute refused" 'lacks group execute' "$U" "$P" SFTP_PROJECT_MODE=760

    # A Match block in a drop-in overrides global ChrootDirectory/ForceCommand
    # in sshd, so drop-ins touching the jail must be rejected outright.
    REFUSAL_DROPIN=$'Match User alice\n    ChrootDirectory none' \
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
    log_step "B. Authenticated non-member (bob) against project 'alpha'"
    local secret="$SCRIPT_DIR/.test-temp-secret.txt"
    echo "alpha-confidential" > "$secret"

    expect_allowed "alice (member) can write to alpha" alice "put $secret alpha/secret.txt"
    expect_allowed "bob (member) can write to beta"    bob   "put $secret beta/own.txt"

    expect_denied "bob cannot list alpha"            bob "ls alpha"
    expect_denied "bob cannot stat a file in alpha"  bob "ls alpha/secret.txt"
    expect_denied "bob cannot download from alpha"   bob "get alpha/secret.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "bob cannot upload to alpha"       bob "put $secret alpha/planted.txt"
    expect_denied "bob cannot delete from alpha"     bob "rm alpha/secret.txt"
    expect_denied "bob cannot mkdir in alpha"        bob "mkdir alpha/evil"
    expect_denied "bob cannot rename out of alpha"   bob "rename alpha/secret.txt beta/stolen.txt"
    expect_denied "bob cannot rename into alpha"     bob "rename beta/own.txt alpha/own.txt"
    expect_denied "bob cannot symlink inside alpha"  bob "symlink x alpha/link"
    expect_denied "bob cannot chmod alpha"           bob "chmod 777 alpha"
    expect_denied "bob cannot hardlink alpha's file into beta" bob "ln alpha/secret.txt beta/hardlink.txt"

    # A symlink bob is allowed to create in his own project must not read through
    expect_allowed "bob can create a symlink in his own project" bob "symlink ../alpha/secret.txt beta/link"
    expect_denied  "symlink in beta does not expose alpha's file" bob "get beta/link $SCRIPT_DIR/.test-temp-stolen.txt"

    expect_denied "absolute path into alpha is denied"   bob "get /alpha/secret.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "../ traversal to alpha is denied"     bob "get beta/../alpha/secret.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "jail has no /etc/passwd"              bob "get /etc/passwd $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "traversal out of the jail is denied"  bob "get ../../../../etc/passwd $SCRIPT_DIR/.test-temp-stolen.txt"

    test_start "bob has no shell (ForceCommand internal-sftp)"
    local out
    out=$(ssh "${SSH_OPTS[@]}" -p "$PORT" -i "$SCRIPT_DIR/secrets/bob_key" bob@localhost id 2>&1 || true)
    if printf '%s' "$out" | grep -q 'uid='; then test_fail "command executed: $out"; else test_pass; fi

    test_start "no stolen data reached the client"
    if [ -e "$SCRIPT_DIR/.test-temp-stolen.txt" ]; then test_fail "stolen file exists"; else test_pass; fi

    test_start "alpha's data is intact after all attempts"
    local back="$SCRIPT_DIR/.test-temp-back.txt"
    if sftp_run alice "get alpha/secret.txt $back" && [ "$(cat "$back")" = "alpha-confidential" ] \
        && ! dexec 'ls /sftp-jail/projects/alpha' | grep -Eq 'planted|evil|stolen|hardlink'; then
        test_pass
    else
        test_fail "alpha content changed"
    fi

    expect_allowed "carol (member of both) reads alpha" carol "get alpha/secret.txt $back"

    test_start "New files inherit the project group (setgid directory)"
    if [ "$(dexec 'stat -c %g /sftp-jail/projects/alpha/secret.txt')" = "2001" ]; then
        test_pass
    else
        test_fail "group is $(dexec 'stat -c %g /sftp-jail/projects/alpha/secret.txt'), expected 2001"
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
    dexec 'chmod 777 /sftp-jail/projects/alpha && chown 9999:9999 /sftp-jail/projects/alpha'
    test_start "Corrupted alpha (9999:9999 mode 777) is repaired to 0:2001 mode 2770"
    if wait_for 25 bash -c "[ \"\$(cd '$SCRIPT_DIR' && docker compose exec -T sftp stat -c '%u:%g:%a' /sftp-jail/projects/alpha | tr -d '[:space:]')\" = '0:2001:2770' ]"; then
        test_pass
    else
        test_fail "state is $(project_dir_state alpha)"
    fi

    test_start "bob is still denied after repair"
    if sftp_run bob "ls alpha"; then test_fail "bob can list alpha"; else test_pass; fi

    # A symlink planted where a project directory should be must not be followed
    dexec 'rm -rf /sftp-jail/projects/beta && ln -s /etc /sftp-jail/projects/beta'
    sleep 12
    test_start "Symlink planted as project directory does not redirect chown/chmod"
    if [ "$(dexec 'stat -c %a /etc')" = "755" ] && [ "$(dexec 'stat -c %u:%g /etc')" = "0:0" ]; then
        test_pass
    else
        test_fail "/etc was modified through the symlink"
    fi
    dexec 'rm -f /sftp-jail/projects/beta'
    test_start "Missing project directory is re-created after removal"
    set_config $'alice:1001\nbob:1002\ncarol:1003' $'alpha:2001:alice,carol\nbeta:2002:bob,carol'
    if wait_for 25 bash -c "[ \"\$(cd '$SCRIPT_DIR' && docker compose exec -T sftp stat -c '%u:%g:%a' /sftp-jail/projects/beta | tr -d '[:space:]')\" = '0:2002:2770' ]"; then
        test_pass
    else
        test_fail "state is $(project_dir_state beta)"
    fi
}

#=============================================================================
# D. LIFECYCLE: removing and re-using identities must revoke access
#=============================================================================
test_lifecycle() {
    log_step "D. Lifecycle: removal revokes, GID reuse does not resurrect access"
    local f="$SCRIPT_DIR/.test-temp-life.txt"
    echo "beta-data" > "$f"
    sftp_run bob "put $f beta/before-removal.txt" || true

    local U=$'alice:1001\nbob:1002\ncarol:1003'

    # Remove beta (GID 2002)
    set_config "$U" 'alpha:2001:alice,carol'
    test_start "Removed project's group is deleted from /etc/group"
    if wait_for 25 bash -c "! (cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^beta:' /etc/group)"; then
        test_pass
    else
        test_fail "group beta still present"
    fi

    test_start "Removed project's directory is locked to root:root 0700"
    if wait_for 25 bash -c "[ \"\$(cd '$SCRIPT_DIR' && docker compose exec -T sftp stat -c '%u:%g:%a' /sftp-jail/projects/beta | tr -d '[:space:]')\" = '0:0:700' ]"; then
        test_pass
    else
        test_fail "state is $(project_dir_state beta)"
    fi

    expect_denied "bob lost access to the removed project" bob "get beta/before-removal.txt $SCRIPT_DIR/.test-temp-stolen.txt"
    expect_denied "carol lost access to the removed project" carol "ls beta"

    # Reuse GID 2002 for a new project with different members
    set_config "$U" $'alpha:2001:alice,carol\ngamma:2002:alice'
    test_start "New project 'gamma' reusing GID 2002 is created"
    wait_for 25 bash -c "(cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^gamma:x:2002:alice' /etc/group)" \
        && test_pass || test_fail "gamma not created"

    expect_allowed "alice (gamma member) can write to gamma" alice "put $f gamma/ok.txt"
    expect_denied  "bob cannot reach gamma"                  bob   "ls gamma"
    expect_denied  "old beta data stays sealed despite GID reuse" alice "get beta/before-removal.txt $SCRIPT_DIR/.test-temp-stolen.txt"

    # Disable and re-enable
    set_config $'alice:1001\nbob:1002:disabled\ncarol:1003' $'alpha:2001:alice,carol\ngamma:2002:alice'
    test_start "Disabled user cannot log in"
    wait_for 25 bash -c "! sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes -P $PORT -i '$SCRIPT_DIR/secrets/bob_key' bob@localhost <<< pwd" \
        && test_pass || test_fail "bob can still log in"

    set_config $'alice:1001\nbob:1002\ncarol:1003' $'alpha:2001:alice,carol\ngamma:2002:alice'
    test_start "Re-enabled user can log in again"
    wait_for 25 bash -c "sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes -P $PORT -i '$SCRIPT_DIR/secrets/bob_key' bob@localhost <<< pwd" \
        && test_pass || test_fail "bob cannot log in"

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
    set_config $'alice:1001\nbob:1002\ncarol:1003\ndave:1004' $'alpha:2001:alice,carol\ngamma:2002:alice\ndelta:2002:dave'
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
    if sftp_run alice "pwd"; then test_pass; else test_fail "alice locked out"; fi

    # Removing a user who is still listed in a project must still revoke them,
    # and the stale reference must not grant anything or block the reconcile.
    set_config $'alice:1001\nbob:1002' $'alpha:2001:alice,carol\ngamma:2002:alice'
    test_start "Removed user still listed in a project is locked and dropped from the group"
    if wait_for 25 bash -c "(cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^carol:!' /etc/shadow)" \
        && [ "$(dexec "awk -F: '\$1==\"alpha\"{print \$4}' /etc/group" | tr -d '[:space:]')" = "alice" ]; then
        test_pass
    else
        test_fail "carol not locked or still in alpha: $(dexec 'grep ^alpha: /etc/group; grep ^carol: /etc/shadow')"
    fi
    expect_denied "Removed user cannot log in" carol "pwd"

    # Restore a valid config
    set_config $'alice:1001\nbob:1002\ncarol:1003' $'alpha:2001:alice,carol\ngamma:2002:alice'
    wait_for 25 bash -c "! (cd '$SCRIPT_DIR' && docker compose exec -T sftp grep -q '^carol:!' /etc/shadow)" || true
}

#=============================================================================
# F. RESTART: state converges and config is revalidated
#=============================================================================
test_restart() {
    log_step "F. Restart"
    (cd "$SCRIPT_DIR" && docker compose restart sftp >/dev/null 2>&1)
    test_start "Container comes back after restart with the reconciled config"
    if wait_for 30 ssh-keyscan -t ed25519 -p "$PORT" -T 1 127.0.0.1 \
        && wait_for 20 sftp_run alice "ls gamma"; then
        test_pass
    else
        test_fail "service did not recover"
    fi
    expect_denied "bob is still denied gamma after restart" bob "ls gamma"
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
