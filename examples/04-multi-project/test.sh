#!/bin/bash
# Automated test script for 04-multi-project example
# Tests complex multi-user, multi-project access patterns

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="04-multi-project"
ALL_USERS=("sheridan" "ivanova" "franklin" "sinclair" "garibaldi" "lyta")
PORT=2222

# Return space-separated list of projects a user has write access to
# (bash 3 portable - no declare -A)
user_projects() {
    case "$1" in
        sheridan)  printf '%s' "command-staff security shared-intel" ;;
        ivanova)   printf '%s' "command-staff shared-intel" ;;
        franklin)  printf '%s' "medlab" ;;
        sinclair)  printf '%s' "command-staff shared-intel" ;;
        garibaldi) printf '%s' "security shared-intel" ;;
        lyta)      printf '%s' "telepath-ops" ;;
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

    for user in "${ALL_USERS[@]}"; do
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
    test_project_access
    test_project_isolation
    test_shared_project_collaboration
}

test_user_authentication() {
    for user in "${ALL_USERS[@]}"; do
        test_start "User $user can authenticate"
        if sftp_connect_test "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT"; then
            test_pass
        else
            test_fail "Authentication failed for $user"
        fi
    done
}

test_project_access() {
    # Verify each user can write to each of their assigned projects.
    # Note: /sftp-jail/projects is mode 755, so project names are visible to all
    # authenticated users. Isolation is enforced by per-project mode 2770, not
    # by hiding names. Tests here verify WRITE capability, not listing visibility.
    local test_file="$SCRIPT_DIR/.test-temp-access.txt"
    echo "access test" > "$test_file"

    for user in "${ALL_USERS[@]}"; do
        local projects
        projects=$(user_projects "$user")
        for project in $projects; do
            test_start "$user can write to $project"
            if sftp_put_file "$user" "$SCRIPT_DIR/secrets/${user}_key" "$test_file" "$project/test.txt" "$PORT"; then
                test_pass
                sftp_delete_file "$user" "$SCRIPT_DIR/secrets/${user}_key" "$project/test.txt" "$PORT" 2>/dev/null || true
            else
                test_fail "$user cannot write to $project"
            fi
        done
    done

    rm -f "$test_file"
}

test_project_isolation() {
    # Verify users CANNOT write to projects they are not a member of.
    # Skipped on macOS Docker Desktop: VirtioFS uses fakeowner mounts that
    # bypass POSIX group permission enforcement for host bind mounts.
    local test_file="$SCRIPT_DIR/.test-temp-isolation.txt"
    echo "intruder" > "$test_file"
    local skip_reason="VirtioFS fakeowner: bind mounts do not enforce POSIX group permissions on macOS Docker Desktop"

    test_start "Franklin cannot write to security"
    if ! projects_enforce_permissions "$SCRIPT_DIR"; then
        test_skip "$skip_reason"
    elif sftp_put_file "franklin" "$SCRIPT_DIR/secrets/franklin_key" "$test_file" "security/intrusion.txt" "$PORT"; then
        test_fail "Franklin was able to write to security (isolation breach)"
    else
        test_pass
    fi

    test_start "Lyta cannot write to command-staff"
    if ! projects_enforce_permissions "$SCRIPT_DIR"; then
        test_skip "$skip_reason"
    elif sftp_put_file "lyta" "$SCRIPT_DIR/secrets/lyta_key" "$test_file" "command-staff/intrusion.txt" "$PORT"; then
        test_fail "Lyta was able to write to command-staff (isolation breach)"
    else
        test_pass
    fi

    test_start "Garibaldi cannot write to medlab"
    if ! projects_enforce_permissions "$SCRIPT_DIR"; then
        test_skip "$skip_reason"
    elif sftp_put_file "garibaldi" "$SCRIPT_DIR/secrets/garibaldi_key" "$test_file" "medlab/intrusion.txt" "$PORT"; then
        test_fail "Garibaldi was able to write to medlab (isolation breach)"
    else
        test_pass
    fi

    rm -f "$test_file"
}

test_shared_project_collaboration() {
    local test_file="$SCRIPT_DIR/.test-temp-intel.txt"
    local downloaded_file="$SCRIPT_DIR/.test-temp-intel-download.txt"
    echo "Shared intelligence report" > "$test_file"

    # Sheridan uploads to shared-intel
    test_start "Sheridan uploads to shared-intel"
    if sftp_put_file "sheridan" "$SCRIPT_DIR/secrets/sheridan_key" "$test_file" "shared-intel/report.txt" "$PORT"; then
        test_pass
    else
        test_fail "Sheridan cannot upload to shared-intel"
        rm -f "$test_file"
        return
    fi

    # Ivanova can download from shared-intel
    test_start "Ivanova can download from shared-intel"
    if sftp_get_file "ivanova" "$SCRIPT_DIR/secrets/ivanova_key" "shared-intel/report.txt" "$downloaded_file" "$PORT"; then
        test_pass
    else
        test_fail "Ivanova cannot download from shared-intel"
    fi

    # Garibaldi can also access it
    test_start "Garibaldi can access shared-intel"
    if sftp_check_file_exists "garibaldi" "$SCRIPT_DIR/secrets/garibaldi_key" "shared-intel/report.txt" "$PORT"; then
        test_pass
    else
        test_fail "Garibaldi cannot see file in shared-intel"
    fi

    # Sinclair can delete it
    test_start "Sinclair can delete from shared-intel"
    if sftp_delete_file "sinclair" "$SCRIPT_DIR/secrets/sinclair_key" "shared-intel/report.txt" "$PORT"; then
        test_pass
    else
        test_fail "Sinclair cannot delete from shared-intel"
    fi

    rm -f "$test_file" "$downloaded_file"
}

#=============================================================================
# RUN
#=============================================================================
main
