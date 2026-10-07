#!/bin/bash
# Automated test script for 07-2fa example
# Tests two-factor authentication (public key + password, both required)

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="07-2fa"
USERS=("zathras" "corwin")
PROJECT="great-machine"
PORT=2222

# Passwords for each test user
ZATHRAS_PASSWORD="ZaZaZathras!42"
CORWIN_PASSWORD="EarthForce#2260"

#=============================================================================
# PASSWORD LOOKUP HELPER (bash 3 portable, no associative arrays)
#=============================================================================
user_password() {
    case "$1" in
        zathras) printf '%s' "$ZATHRAS_PASSWORD" ;;
        corwin)  printf '%s' "$CORWIN_PASSWORD" ;;
    esac
}

#=============================================================================
# 2FA SFTP HELPERS
# Use expect(1) to drive the two-step auth: key exchange then password prompt.
# OpenSSH presents the password prompt AFTER pubkey auth succeeds.
# log_user 0 suppresses PTY echo at the TCL level; avoids >/dev/null 2>&1
# which can interfere with expect's PTY interaction.
#=============================================================================

# sftp_2fa_connect_test USER KEY_PATH PASSWORD PORT
# Returns 0 if both factors accepted (sftp prompt reached), 1 otherwise.
sftp_2fa_connect_test() {
    local user="$1"
    local key_path="$2"
    local password="$3"
    local port="${4:-2222}"
    local host="${5:-localhost}"

    expect -f - 2>/dev/null <<EOF
log_user 0
set timeout 20
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes \
           -P $port -i ${key_path} ${user}@${host}
expect {
    "password:" { send "${password}\r" }
    "sftp>"     { exit 0 }
    timeout     { exit 1 }
    eof         { exit 1 }
}
expect {
    "sftp>"     { send "exit\r"; exp_continue }
    eof         { exit 0 }
    timeout     { exit 1 }
}
EOF
}

# sftp_key_only_test USER KEY_PATH PORT
# Verifies that key alone is NOT sufficient (connection fails or times out
# waiting for password prompt, then sshd closes the session).
# Returns 0 if authentication fails (as expected), 1 if it unexpectedly succeeds.
sftp_key_only_test() {
    local user="$1"
    local key_path="$2"
    local port="${3:-2222}"
    local host="${4:-localhost}"

    # Send no password when prompted; expect connection to be refused.
    expect -f - 2>/dev/null <<EOF
log_user 0
set timeout 20
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes -o NumberOfPasswordPrompts=0 \
           -P $port -i ${key_path} ${user}@${host}
expect {
    "sftp>"  { exit 1 }
    eof      { exit 0 }
    timeout  { exit 0 }
}
EOF
}

# sftp_password_only_test USER PASSWORD PORT
# Verifies that password alone is NOT sufficient.
# Returns 0 if authentication fails (as expected), 1 if it unexpectedly succeeds.
sftp_password_only_test() {
    local user="$1"
    local password="$2"
    local port="${3:-2222}"
    local host="${4:-localhost}"

    expect -f - 2>/dev/null <<EOF
log_user 0
set timeout 20
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes -o PreferredAuthentications=password \
           -o NumberOfPasswordPrompts=1 \
           -P $port ${user}@${host}
expect {
    "password:" { send "${password}\r" }
    "sftp>"     { exit 1 }
    timeout     { exit 0 }
    eof         { exit 0 }
}
expect {
    "sftp>"  { exit 1 }
    eof      { exit 0 }
    timeout  { exit 0 }
}
EOF
}

#=============================================================================
# MAIN TEST FLOW
#=============================================================================
main() {
    log_step "Starting tests for $EXAMPLE_NAME"

    # Check dependency
    if ! command -v expect >/dev/null 2>&1; then
        log_error "expect(1) is required for 2FA tests but not found"
        exit 1
    fi

    # Setup
    setup_test_environment "$SCRIPT_DIR"

    # Generate keys and passwords
    log_step "Preparing environment"
    generate_host_key "$SCRIPT_DIR/secrets"

    for user in "${USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
    done

    printf '%s' "$ZATHRAS_PASSWORD" > "$SCRIPT_DIR/secrets/zathras.password"
    printf '%s' "$CORWIN_PASSWORD"  > "$SCRIPT_DIR/secrets/corwin.password"
    chmod 600 "$SCRIPT_DIR/secrets/zathras.password" "$SCRIPT_DIR/secrets/corwin.password"
    log_success "Keys and password secrets prepared"

    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"
    (cd "$SCRIPT_DIR" && docker_compose_up "$PORT")

    # Run tests
    run_tests

    # Cleanup
    (cd "$SCRIPT_DIR" && docker_compose_down)
    cleanup_all "$SCRIPT_DIR"

    # Show results
    echo
    test_summary
    exit $?
}

#=============================================================================
# TEST CASES
#=============================================================================
run_tests() {
    log_step "Running test cases"

    test_both_factors_accepted
    test_key_alone_rejected
    test_password_alone_rejected
    test_wrong_password_with_key_rejected
    test_project_access
}

test_both_factors_accepted() {
    for user in "${USERS[@]}"; do
        local pw
        pw=$(user_password "$user")
        test_start "User $user succeeds with key + correct password"
        if sftp_2fa_connect_test "$user" "$SCRIPT_DIR/secrets/${user}_key" "$pw" "$PORT"; then
            test_pass
        else
            test_fail "2FA authentication failed for $user"
        fi
    done
}

test_key_alone_rejected() {
    local user="zathras"
    test_start "Key alone is rejected for $user (2FA enforced)"
    if sftp_key_only_test "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT"; then
        test_pass
    else
        test_fail "Key-only access succeeded (2FA not enforced)"
    fi
}

test_password_alone_rejected() {
    local user="zathras"
    local pw
    pw=$(user_password "$user")
    test_start "Password alone is rejected for $user (2FA enforced)"
    if sftp_password_only_test "$user" "$pw" "$PORT"; then
        test_pass
    else
        test_fail "Password-only access succeeded (2FA not enforced)"
    fi
}

test_wrong_password_with_key_rejected() {
    local user="corwin"
    test_start "Correct key + wrong password is rejected for $user"
    if sftp_2fa_connect_test "$user" "$SCRIPT_DIR/secrets/${user}_key" "wrong-password-xyz" "$PORT"; then
        test_fail "Wrong password was accepted with correct key (auth bypass)"
    else
        test_pass
    fi
}

test_project_access() {
    local user="zathras"
    local pw
    pw=$(user_password "$user")
    local test_file="$SCRIPT_DIR/.test-temp-2fa.txt"
    local remote_path="$PROJECT/great-machine-data.txt"

    printf '%s\n' "Zathras is used to being not listened to." > "$test_file"

    test_start "User $user can upload file with 2FA"
    local result=0
    expect -f - 2>/dev/null <<EOF || result=$?
log_user 0
set timeout 30
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes \
           -P $PORT -i $SCRIPT_DIR/secrets/${user}_key ${user}@localhost
expect {
    "password:" { send "${pw}\r" }
    timeout     { exit 1 }
    eof         { exit 1 }
}
expect {
    "sftp>"     { send "put ${test_file} ${remote_path}\r" }
    timeout     { exit 1 }
    eof         { exit 1 }
}
expect {
    "sftp>"     { send "exit\r"; exp_continue }
    eof         { exit 0 }
    timeout     { exit 1 }
}
EOF

    if [ "$result" -eq 0 ]; then
        test_pass
    else
        test_fail "Failed to upload file with 2FA"
    fi

    rm -f "$test_file"
}

#=============================================================================
# RUN
#=============================================================================
main
