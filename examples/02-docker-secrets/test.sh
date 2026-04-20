#!/bin/bash
# Automated test script for 02-docker-secrets example
# Tests Docker Secrets integration (production-ready secret management)

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="02-docker-secrets"
USERS=("kosh" "lennier" "talia")
PORT=2222

# Return the expected project for a given user (bash 3 portable - no declare -A)
user_project() {
    case "$1" in
        kosh|lennier) printf '%s' "vorlon-archives" ;;
        talia)        printf '%s' "psi-corps" ;;
    esac
}

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
    test_vorlon_collaboration
    test_psi_corps_isolation
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
        expected=$(user_project "$user")
        test_start "User $user can see $expected project"

        # Project names are visible to all authenticated users (parent dir is 755).
        # This test verifies only that the user's own project appears in the listing.
        actual=$(sftp_list_projects "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT")

        if echo "$actual" | grep -q "^${expected}$"; then
            test_pass
        else
            test_fail "Expected to find '$expected' in listing, got: $actual"
        fi
    done
}

test_vorlon_collaboration() {
    local test_file="$SCRIPT_DIR/.test-temp-vorlon.txt"
    local downloaded_file="$SCRIPT_DIR/.test-temp-vorlon-download.txt"
    echo "Vorlon knowledge" > "$test_file"

    # Kosh uploads
    test_start "Kosh uploads to vorlon-archives"
    if sftp_put_file "kosh" "$SCRIPT_DIR/secrets/kosh_key" "$test_file" "vorlon-archives/knowledge.txt" "$PORT"; then
        test_pass
    else
        test_fail "Kosh cannot upload"
        rm -f "$test_file"
        return
    fi

    # Lennier can access
    test_start "Lennier can download from vorlon-archives"
    if sftp_get_file "lennier" "$SCRIPT_DIR/secrets/lennier_key" "vorlon-archives/knowledge.txt" "$downloaded_file" "$PORT"; then
        test_pass
    else
        test_fail "Lennier cannot download"
    fi

    # Cleanup
    sftp_delete_file "lennier" "$SCRIPT_DIR/secrets/lennier_key" "vorlon-archives/knowledge.txt" "$PORT" 2>/dev/null || true
    rm -f "$test_file" "$downloaded_file"
}

test_psi_corps_isolation() {
    local test_file="$SCRIPT_DIR/.test-temp-psi.txt"
    echo "Psi Corps data" > "$test_file"

    # Talia can use psi-corps
    test_start "Talia can access psi-corps"
    if sftp_put_file "talia" "$SCRIPT_DIR/secrets/talia_key" "$test_file" "psi-corps/data.txt" "$PORT"; then
        test_pass
    else
        test_fail "Talia cannot access psi-corps"
        rm -f "$test_file"
        return
    fi

    # Kosh should not be able to upload to psi-corps (data access isolation)
    local kosh_test="$SCRIPT_DIR/.test-temp-psi-kosh.txt"
    echo "intruder" > "$kosh_test"
    test_start "Kosh cannot write to psi-corps (data isolation)"
    if ! projects_enforce_permissions "$SCRIPT_DIR"; then
        test_skip "VirtioFS fakeowner: bind mounts do not enforce POSIX group permissions on macOS Docker Desktop"
    elif sftp_put_file "kosh" "$SCRIPT_DIR/secrets/kosh_key" "$kosh_test" "psi-corps/intruder.txt" "$PORT"; then
        test_fail "Kosh was able to write to psi-corps (isolation breach)"
    else
        test_pass
    fi
    rm -f "$kosh_test"

    # Cleanup
    sftp_delete_file "talia" "$SCRIPT_DIR/secrets/talia_key" "psi-corps/data.txt" "$PORT" 2>/dev/null || true
    rm -f "$test_file"
}

#=============================================================================
# RUN
#=============================================================================
main
