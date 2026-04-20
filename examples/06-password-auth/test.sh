#!/bin/bash
# Automated test script for 06-password-auth example
# Tests password-only SFTP authentication

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="06-password-auth"
USERS=("delenn" "marcus")
PROJECT="minbari-ops"
PORT=2222

# Passwords for each test user
DELENN_PASSWORD="Minbari-G1432!"
MARCUS_PASSWORD="RangerPrime#99"

#=============================================================================
# PASSWORD SFTP HELPERS
# Use expect(1) to drive interactive SFTP password prompts.
# log_user 0 suppresses PTY echo at the TCL level; avoids >/dev/null 2>&1
# which can interfere with expect's PTY interaction.
#=============================================================================

# sftp_password_connect_test USER PASSWORD PORT
# Returns 0 if the connection succeeds (pwd executes), 1 otherwise.
sftp_password_connect_test() {
    local user="$1"
    local password="$2"
    local port="${3:-2222}"
    local host="${4:-localhost}"

    expect -f - 2>/dev/null <<EOF
log_user 0
set timeout 15
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes -o PreferredAuthentications=password \
           -P $port ${user}@${host}
expect {
    "password:" { send "${password}\r" }
    timeout     { exit 1 }
    eof         { exit 1 }
}
expect {
    "sftp>"     { send "pwd\r" }
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

# sftp_password_put_file USER PASSWORD LOCAL_FILE REMOTE_PATH PORT
sftp_password_put_file() {
    local user="$1"
    local password="$2"
    local local_file="$3"
    local remote_path="$4"
    local port="${5:-2222}"
    local host="${6:-localhost}"

    expect -f - 2>/dev/null <<EOF
log_user 0
set timeout 30
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes -o PreferredAuthentications=password \
           -P $port ${user}@${host}
expect {
    "password:" { send "${password}\r" }
    timeout     { exit 1 }
    eof         { exit 1 }
}
expect {
    "sftp>"     { send "put ${local_file} ${remote_path}\r" }
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

# sftp_password_wrong_password_test USER WRONG_PASSWORD PORT
# Returns 0 if authentication is REJECTED (expected), 1 if it succeeds (test failure).
sftp_password_wrong_password_test() {
    local user="$1"
    local password="$2"
    local port="${3:-2222}"
    local host="${4:-localhost}"

    # sftp with wrong password will prompt multiple times then exit non-zero.
    # We send the wrong password and expect eventual failure (eof without sftp>).
    expect -f - 2>/dev/null <<EOF
log_user 0
set timeout 20
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes -o PreferredAuthentications=password \
           -o NumberOfPasswordPrompts=1 \
           -P $port ${user}@${host}
expect {
    "password:" { send "${password}\r" }
    timeout     { exit 2 }
    eof         { exit 2 }
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
        log_error "expect(1) is required for password auth tests but not found"
        exit 1
    fi

    # Setup
    setup_test_environment "$SCRIPT_DIR"

    # Generate host key and password secret files
    log_step "Preparing environment"
    generate_host_key "$SCRIPT_DIR/secrets"

    printf '%s' "$DELENN_PASSWORD" > "$SCRIPT_DIR/secrets/delenn.password"
    printf '%s' "$MARCUS_PASSWORD" > "$SCRIPT_DIR/secrets/marcus.password"
    chmod 600 "$SCRIPT_DIR/secrets/delenn.password" "$SCRIPT_DIR/secrets/marcus.password"
    log_success "Password secrets written"

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

    test_password_authentication
    test_wrong_password_rejected
    test_pubkey_rejected
    test_file_operations
    test_project_visibility
}

user_password() {
    case "$1" in
        delenn) printf '%s' "$DELENN_PASSWORD" ;;
        marcus) printf '%s' "$MARCUS_PASSWORD" ;;
    esac
}

test_password_authentication() {
    for user in "${USERS[@]}"; do
        local pw
        pw=$(user_password "$user")
        test_start "User $user can authenticate with correct password"
        if sftp_password_connect_test "$user" "$pw" "$PORT"; then
            test_pass
        else
            test_fail "Password authentication failed for $user"
        fi
    done
}

test_wrong_password_rejected() {
    test_start "Wrong password is rejected for delenn"
    if sftp_password_wrong_password_test "delenn" "wrong-password-xyz" "$PORT"; then
        test_pass
    else
        test_fail "Wrong password was accepted (should have been rejected)"
    fi

    test_start "Wrong password is rejected for marcus"
    if sftp_password_wrong_password_test "marcus" "bad-pass-123" "$PORT"; then
        test_pass
    else
        test_fail "Wrong password was accepted (should have been rejected)"
    fi
}

test_pubkey_rejected() {
    # In password-only mode, pubkey auth must not work even if the client
    # offers a key.  Generate a throwaway key for this test.
    local throw_key="$SCRIPT_DIR/.test-temp-throwaway-key"
    ssh-keygen -t ed25519 -f "$throw_key" -N "" -C "throwaway" >/dev/null 2>&1

    test_start "Public key auth is rejected in password-only mode"
    if sftp_connect_test "delenn" "$throw_key" "$PORT"; then
        test_fail "Pubkey authentication succeeded (should have been rejected)"
    else
        test_pass
    fi

    rm -f "$throw_key" "${throw_key}.pub"
}

test_file_operations() {
    local user="delenn"
    local password="$DELENN_PASSWORD"
    local test_file="$SCRIPT_DIR/.test-temp-upload.txt"
    local remote_path="$PROJECT/prophecy.txt"

    printf '%s\n' "The Minbari do not lie, though we have not always told the full truth." > "$test_file"

    test_start "User $user can upload file to $PROJECT"
    if sftp_password_put_file "$user" "$password" "$test_file" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "Failed to upload file"
        rm -f "$test_file"
        return
    fi

    rm -f "$test_file"
}

test_project_visibility() {
    for user in "${USERS[@]}"; do
        local pw
        pw=$(user_password "$user")
        test_start "User $user can list $PROJECT"

        # log_file captures all PTY output to a temp file so we can grep it
        # without relying on command substitution of the expect process stdout.
        local logfile
        logfile=$(mktemp)

        expect -f - 2>/dev/null <<EOF || true
log_user 0
log_file -noappend -a "$logfile"
set timeout 15
spawn sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes -o PreferredAuthentications=password \
           -P $PORT ${user}@localhost
expect {
    "password:" { send "${pw}\r" }
    timeout     { exit 1 }
    eof         { exit 1 }
}
expect {
    "sftp>"     { send "ls -1\r" }
    timeout     { exit 1 }
    eof         { exit 1 }
}
expect {
    "sftp>"     { send "exit\r"; exp_continue }
    eof         { exit 0 }
    timeout     { exit 1 }
}
EOF

        if grep -q "$PROJECT" "$logfile" 2>/dev/null; then
            test_pass
        else
            test_fail "Expected to see '$PROJECT' in listing"
        fi
        rm -f "$logfile"
    done
}

#=============================================================================
# RUN
#=============================================================================
main
