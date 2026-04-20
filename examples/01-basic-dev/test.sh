#!/bin/bash
# Automated test script for 01-basic-dev example
# Tests basic SFTP functionality with two users sharing a project

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="01-basic-dev"
USERS=("sheridan" "garibaldi")
PROJECT="station-ops"
PORT=2222

#=============================================================================
# MAIN TEST FLOW
#=============================================================================
main() {
    log_step "Starting tests for $EXAMPLE_NAME"

    # Setup
    setup_test_environment "$SCRIPT_DIR"

    # Build and start
    log_step "Preparing environment"
    generate_host_key "$SCRIPT_DIR/secrets"

    for user in "${USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
    done

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

    test_user_authentication
    test_project_visibility
    test_file_operations
    test_cross_user_collaboration
    test_restart_idempotency
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

test_project_visibility() {
    for user in "${USERS[@]}"; do
        test_start "User $user sees $PROJECT project"
        projects=$(sftp_list_projects "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT")

        if echo "$projects" | grep -q "^$PROJECT$"; then
            test_pass
        else
            test_fail "Expected to see '$PROJECT', got: $projects"
        fi
    done
}

test_file_operations() {
    local user="sheridan"
    local key="$SCRIPT_DIR/secrets/${user}_key"
    local test_file="$SCRIPT_DIR/.test-temp-upload.txt"
    local downloaded_file="$SCRIPT_DIR/.test-temp-download.txt"
    local remote_path="$PROJECT/test-file.txt"

    # Create test file
    echo "Test content from automated test" > "$test_file"

    # Test upload
    test_start "User $user can upload file to $PROJECT"
    if sftp_put_file "$user" "$key" "$test_file" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "Failed to upload file"
        return
    fi

    # Test file exists
    test_start "Uploaded file exists in $PROJECT"
    if sftp_check_file_exists "$user" "$key" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "File not found after upload"
        return
    fi

    # Test download
    test_start "User $user can download file from $PROJECT"
    if sftp_get_file "$user" "$key" "$remote_path" "$downloaded_file" "$PORT"; then
        test_pass
    else
        test_fail "Failed to download file"
        return
    fi

    # Verify content
    test_start "Downloaded file has correct content"
    if diff -q "$test_file" "$downloaded_file" >/dev/null 2>&1; then
        test_pass
    else
        test_fail "File content mismatch"
    fi

    # Test delete
    test_start "User $user can delete file from $PROJECT"
    if sftp_delete_file "$user" "$key" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "Failed to delete file"
    fi

    # Cleanup local test files
    rm -f "$test_file" "$downloaded_file"
}

test_cross_user_collaboration() {
    local user1="sheridan"
    local user2="garibaldi"
    local key1="$SCRIPT_DIR/secrets/${user1}_key"
    local key2="$SCRIPT_DIR/secrets/${user2}_key"
    local test_file="$SCRIPT_DIR/.test-temp-shared.txt"
    local downloaded_file="$SCRIPT_DIR/.test-temp-shared-download.txt"
    local remote_path="$PROJECT/shared-file.txt"

    # Create test file
    echo "Shared content between users" > "$test_file"

    # User1 uploads
    test_start "User $user1 uploads shared file"
    if sftp_put_file "$user1" "$key1" "$test_file" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "User $user1 failed to upload"
        rm -f "$test_file"
        return
    fi

    # User2 can see it
    test_start "User $user2 can see file uploaded by $user1"
    if sftp_check_file_exists "$user2" "$key2" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "User $user2 cannot see file from $user1"
    fi

    # User2 can download it
    test_start "User $user2 can download file from $user1"
    if sftp_get_file "$user2" "$key2" "$remote_path" "$downloaded_file" "$PORT"; then
        test_pass
    else
        test_fail "User $user2 failed to download"
    fi

    # User2 can delete it
    test_start "User $user2 can delete file from $user1"
    if sftp_delete_file "$user2" "$key2" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "User $user2 failed to delete"
    fi

    # Cleanup
    rm -f "$test_file" "$downloaded_file"
}

test_restart_idempotency() {
    # Validates that the mknod guard ([ -e /sftp-jail/dev/null ] || mknod ...)
    # and template-based sshd_config generation are idempotent: two consecutive
    # restarts must both succeed without crashing on existing device nodes or
    # trying to sed-substitute already-substituted values.
    local max_wait=20

    test_start "Container survives first restart"
    if (cd "$SCRIPT_DIR" && docker compose restart sftp >/dev/null 2>&1); then
        local waited=0
        while [ "$waited" -lt "$max_wait" ]; do
            if ssh-keyscan -p "$PORT" -T 1 localhost >/dev/null 2>&1; then break; fi
            sleep 1
            waited=$((waited + 1))
        done
        if [ "$waited" -lt "$max_wait" ]; then
            test_pass
        else
            test_fail "SSH did not recover within ${max_wait}s after first restart"
            return
        fi
    else
        test_fail "docker compose restart failed on first attempt"
        return
    fi

    test_start "Container survives second restart"
    if (cd "$SCRIPT_DIR" && docker compose restart sftp >/dev/null 2>&1); then
        local waited=0
        while [ "$waited" -lt "$max_wait" ]; do
            if ssh-keyscan -p "$PORT" -T 1 localhost >/dev/null 2>&1; then break; fi
            sleep 1
            waited=$((waited + 1))
        done
        if [ "$waited" -lt "$max_wait" ]; then
            test_pass
        else
            test_fail "SSH did not recover within ${max_wait}s after second restart"
        fi
    else
        test_fail "docker compose restart failed on second attempt"
    fi
}

#=============================================================================
# RUN
#=============================================================================
main
