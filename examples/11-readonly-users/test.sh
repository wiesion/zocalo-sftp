#!/bin/bash
# Automated test script for 11-readonly-users example
# Tests read-write vs read-only logins, key reuse, and the `ro` flag lifecycle

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
source "$LIB_DIR/test-helpers.sh"

EXAMPLE_NAME="11-readonly-users"
KEY_USERS=("ivanova" "garibaldi" "kosh")
PORT=2222
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes)

# key_of <login>: the private key that logs in as <login> (ivanova_ro shares ivanova's)
key_of() {
    case "$1" in
        ivanova_ro) printf '%s' "$SCRIPT_DIR/secrets/ivanova_key" ;;
        *)        printf '%s' "$SCRIPT_DIR/secrets/${1}_key" ;;
    esac
}

# sftp_run <login> <command...>: succeeds only if every batch command succeeds
sftp_run() {
    local user="$1"; shift
    printf '%s\n' "$@" | sftp -b - "${SSH_OPTS[@]}" -P "$PORT" -i "$(key_of "$user")" "$user@localhost" >/dev/null 2>&1
}

expect_allowed() {  # <description> <login> <sftp command...>
    local desc="$1" user="$2"; shift 2
    test_start "$desc"
    if sftp_run "$user" "$@"; then test_pass; else test_fail "operation failed: $*"; fi
}

expect_denied() {   # <description> <login> <sftp command...>
    local desc="$1" user="$2"; shift 2
    test_start "$desc"
    if sftp_run "$user" "$@"; then test_fail "operation succeeded: $*"; else test_pass; fi
}

wait_for() {
    local max="$1"; shift
    local waited=0
    while [ "$waited" -lt "$max" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1; waited=$((waited + 1))
    done
    return 1
}

main() {
    log_step "Starting tests for $EXAMPLE_NAME"

    setup_test_environment "$SCRIPT_DIR"

    log_step "Preparing environment"
    generate_host_key "$SCRIPT_DIR/secrets"
    for user in "${KEY_USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
    done

    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"
    (cd "$SCRIPT_DIR" && docker_compose_up "$PORT")

    run_tests

    (cd "$SCRIPT_DIR" && docker_compose_down)
    cleanup_all "$SCRIPT_DIR"

    echo
    test_summary
    exit $?
}

run_tests() {
    log_step "Running test cases"

    test_authentication
    test_readwrite_user
    test_readonly_user_with_shared_key
    test_readonly_general_account
    test_project_isolation
    test_flag_lifecycle
}

test_authentication() {
    for login in ivanova ivanova_ro garibaldi kosh; do
        test_start "$login can authenticate"
        if sftp_connect_test "$login" "$(key_of "$login")" "$PORT"; then
            test_pass
        else
            test_fail "Authentication failed for $login"
        fi
    done
}

test_readwrite_user() {
    local f="$SCRIPT_DIR/.test-temp-rw.txt"
    echo "command-staff report" > "$f"

    expect_allowed "ivanova (rw) can upload to command-staff"  ivanova "put $f command-staff/report.txt"
    expect_allowed "ivanova (rw) can create a directory" ivanova "mkdir command-staff/docs"
    expect_allowed "ivanova (rw) can rename a file"     ivanova "rename command-staff/report.txt command-staff/report-v1.txt"
    expect_allowed "ivanova (rw) can delete a file"     ivanova "rm command-staff/report-v1.txt"
    expect_allowed "ivanova (rw) can remove a directory" ivanova "rmdir command-staff/docs"

    # Leave one file behind for the read-only tests
    sftp_run ivanova "put $f command-staff/report.txt" || true
    rm -f "$f"
}

test_readonly_user_with_shared_key() {
    local f="$SCRIPT_DIR/.test-temp-ro.txt" dl="$SCRIPT_DIR/.test-temp-ro-dl.txt"
    echo "intruder" > "$f"

    # ivanova_ro logs in with ivanova's key: same credential, different login, different rights
    expect_allowed "ivanova_ro (ivanova's key) can list command-staff"     ivanova_ro "ls command-staff"
    test_start "ivanova_ro (ivanova's key) can download from command-staff"
    if sftp_get_file ivanova_ro "$(key_of ivanova_ro)" "command-staff/report.txt" "$dl" "$PORT" && grep -q "command-staff report" "$dl"; then
        test_pass
    else
        test_fail "ivanova_ro could not read command-staff/report.txt"
    fi

    expect_denied "ivanova_ro cannot upload to command-staff"        ivanova_ro "put $f command-staff/intruder.txt"
    expect_denied "ivanova_ro cannot overwrite a file"       ivanova_ro "put $f command-staff/report.txt"
    expect_denied "ivanova_ro cannot delete a file"          ivanova_ro "rm command-staff/report.txt"
    expect_denied "ivanova_ro cannot create a directory"     ivanova_ro "mkdir command-staff/newdir"
    expect_denied "ivanova_ro cannot rename a file"          ivanova_ro "rename command-staff/report.txt command-staff/stolen.txt"
    expect_denied "ivanova_ro cannot chmod a file"           ivanova_ro "chmod 777 command-staff/report.txt"
    expect_denied "ivanova_ro cannot create a symlink"       ivanova_ro "ln -s report.txt command-staff/link"

    test_start "ivanova (rw) still sees command-staff/report.txt unchanged after the ro attempts"
    if sftp_get_file ivanova "$(key_of ivanova)" "command-staff/report.txt" "$dl" "$PORT" && grep -q "command-staff report" "$dl"; then
        test_pass
    else
        test_fail "command-staff/report.txt was modified or removed"
    fi
    rm -f "$f" "$dl"
}

test_readonly_general_account() {
    local f="$SCRIPT_DIR/.test-temp-aud.txt" dl="$SCRIPT_DIR/.test-temp-aud-dl.txt"
    echo "security ledger" > "$f"
    sftp_run garibaldi "put $f security/ledger.txt" || true

    expect_allowed "kosh can read command-staff" kosh "ls command-staff"
    test_start "kosh can download from security"
    if sftp_get_file kosh "$(key_of kosh)" "security/ledger.txt" "$dl" "$PORT" && grep -q "security ledger" "$dl"; then
        test_pass
    else
        test_fail "kosh could not read security/ledger.txt"
    fi
    expect_denied "kosh cannot upload to command-staff"  kosh "put $f command-staff/audit.txt"
    expect_denied "kosh cannot upload to security"   kosh "put $f security/audit.txt"
    expect_denied "kosh cannot delete from security" kosh "rm security/ledger.txt"
    rm -f "$f" "$dl"
}

test_project_isolation() {
    # Read-only is not a back door: a ro account only sees projects it is a member of.
    # Skipped on macOS Docker Desktop (VirtioFS fakeowner does not enforce group permissions).
    test_start "ivanova_ro cannot read security (not a member)"
    if ! projects_enforce_permissions "$SCRIPT_DIR"; then
        test_skip "VirtioFS fakeowner: bind mounts do not enforce POSIX group permissions"
    elif sftp_run ivanova_ro "ls security/ledger.txt"; then
        test_fail "ivanova_ro could read a project it is not a member of"
    else
        test_pass
    fi
}

# Dropping the `ro` flag makes the account writable at its next session; adding it back
# takes the write access away again. Group membership is resolved at login, no restart.
test_flag_lifecycle() {
    local users="$SCRIPT_DIR/config/sftp_users.conf" backup f="$SCRIPT_DIR/.test-temp-life.txt"
    backup=$(mktemp)
    cp "$users" "$backup"
    echo "lifecycle" > "$f"

    sed -i 's/^kosh:1004:ro$/kosh:1004/' "$users"
    test_start "Removing the ro flag lets kosh write (next session)"
    if wait_for 30 sftp_run kosh "put $f command-staff/life.txt"; then test_pass; else test_fail "kosh still read-only after flag removal"; fi

    sed -i 's/^kosh:1004$/kosh:1004:ro/' "$users"
    test_start "Restoring the ro flag takes write access away again"
    if wait_for 30 bash -c "! sftp -b - ${SSH_OPTS[*]} -P $PORT -i '$(key_of kosh)' kosh@localhost <<< 'put $f command-staff/life2.txt'"; then
        test_pass
    else
        test_fail "kosh still writable after flag restored"
    fi

    cat "$backup" > "$users"
    rm -f "$backup" "$f"
}

main
