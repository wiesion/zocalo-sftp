#!/bin/bash
# Automated test script for 05-certificate-auth example
# Tests SSH certificate-based authentication

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="05-certificate-auth"
USERS=("sheridan" "ivanova")
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

    # Generate CA and sign user certificates
    log_step "Setting up Certificate Authority"
    generate_ca_key "$SCRIPT_DIR/secrets"
    log_success "CA key generated"

    for user in "${USERS[@]}"; do
        generate_user_certificate "$SCRIPT_DIR/secrets" "$user"
        log_success "Certificate signed for $user"
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

    test_certificate_authentication
    test_certificate_validity
    test_project_access
    test_file_operations
}

test_certificate_authentication() {
    for user in "${USERS[@]}"; do
        test_start "User $user can authenticate with certificate"
        if sftp_connect_test "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT"; then
            test_pass
        else
            test_fail "Certificate authentication failed for $user"
        fi
    done
}

test_certificate_validity() {
    for user in "${USERS[@]}"; do
        test_start "Certificate for $user is valid"

        # Check if certificate file exists
        if [ ! -f "$SCRIPT_DIR/secrets/${user}_key-cert.pub" ]; then
            test_fail "Certificate file not found"
            continue
        fi

        # Verify certificate has correct principal
        cert_info=$(ssh-keygen -L -f "$SCRIPT_DIR/secrets/${user}_key-cert.pub" 2>/dev/null)

        if echo "$cert_info" | grep -q "Principals:" && \
           echo "$cert_info" | grep -A1 "Principals:" | grep -q "$user"; then
            test_pass
        else
            test_fail "Certificate does not have correct principal"
        fi
    done
}

test_project_access() {
    for user in "${USERS[@]}"; do
        test_start "User $user can see $PROJECT"
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
    local test_file="$SCRIPT_DIR/.test-temp-cert.txt"
    local downloaded_file="$SCRIPT_DIR/.test-temp-cert-download.txt"
    local remote_path="$PROJECT/cert-test.txt"

    # Create test file
    echo "Test with certificate auth" > "$test_file"

    # Test upload
    test_start "User $user can upload file with certificate"
    if sftp_put_file "$user" "$key" "$test_file" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "Failed to upload file"
        rm -f "$test_file"
        return
    fi

    # Test download by other user
    test_start "User ivanova can download file from $user"
    if sftp_get_file "ivanova" "$SCRIPT_DIR/secrets/ivanova_key" "$remote_path" "$downloaded_file" "$PORT"; then
        test_pass
    else
        test_fail "Failed to download file"
    fi

    # Cleanup
    sftp_delete_file "$user" "$key" "$remote_path" "$PORT" 2>/dev/null || true
    rm -f "$test_file" "$downloaded_file"
}

#=============================================================================
# RUN
#=============================================================================
main
