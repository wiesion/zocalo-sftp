#!/bin/bash
# Automated test script for 08-custom-config example
# Tests sshd_config.d drop-in overrides for per-group and per-user settings

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="08-custom-config"
MEDIA_TEAM_USERS=("bester" "zack")
ALL_USERS=("bester" "zack" "morden")
PORT=2222

#=============================================================================
# HELPERS
#=============================================================================

# sftp_connect_noagent: like sftp_connect_test but with SSH_AUTH_SOCK cleared.
# Use for users with MaxAuthTries 1 where agent interference would exhaust the
# single allowed attempt before the specified key is tried.
# SSH_AUTH_SOCK must be unset for sftp itself, not just the echo side of the
# pipeline, so we use a subshell to scope the environment assignment.
sftp_connect_noagent() {
    local user="$1"
    local key_path="$2"
    local port="${3:-2222}"
    local host="${4:-localhost}"

    (
        unset SSH_AUTH_SOCK
        printf 'pwd\n' | sftp -b - \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -P "$port" -i "$key_path" \
            "$user@$host" >/dev/null 2>&1
    )
}

# sshd_test_param: query a single sshd config parameter via sshd -T.
# The optional second argument provides a user match context for Match blocks.
# Usage: sshd_test_param PARAM [user=USERNAME]
sshd_test_param() {
    local param="$1"
    local ctx="${2:-}"
    # OpenSSH 10+ outputs global directives lowercase but Match block directives
    # in their canonical capitalized form.  Normalise to lowercase before grepping
    # so the function works across both old and new sshd versions.
    if [ -n "$ctx" ]; then
        cd "$SCRIPT_DIR" && docker compose exec -T sftp \
            sshd -T -C "$ctx" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep "^${param} " | awk '{print $2}'
    else
        cd "$SCRIPT_DIR" && docker compose exec -T sftp \
            sshd -T 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep "^${param} " | awk '{print $2}'
    fi
}

#=============================================================================
# MAIN TEST FLOW
#=============================================================================
main() {
    log_step "Starting tests for $EXAMPLE_NAME"

    # Setup
    setup_test_environment "$SCRIPT_DIR"

    # Generate keys
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
    test_drop_in_global_config
    test_drop_in_media_team_config
    test_drop_in_strict_user_config
    test_media_team_project_access
    test_shadow_council_access
    test_file_operations
}

test_user_authentication() {
    for user in "${MEDIA_TEAM_USERS[@]}"; do
        test_start "User $user can authenticate"
        if sftp_connect_test "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT"; then
            test_pass
        else
            test_fail "Authentication failed for $user"
        fi
    done

    # morden has MaxAuthTries 1; connect without SSH agent to avoid exhausting
    # the single allowed attempt with an agent key that doesn't match.
    test_start "User morden can authenticate (MaxAuthTries 1, agent suppressed)"
    if sftp_connect_noagent "morden" "$SCRIPT_DIR/secrets/morden_key" "$PORT"; then
        test_pass
    else
        test_fail "Authentication failed for morden"
    fi
}

test_drop_in_global_config() {
    # Verify 01-global.conf: MaxStartups 5:30:50 applied globally.
    test_start "Drop-in 01-global.conf: MaxStartups is 5:30:50"
    local maxstartups
    maxstartups=$(sshd_test_param "maxstartups") || true
    if [ "$maxstartups" = "5:30:50" ]; then
        test_pass
    else
        test_fail "Expected maxstartups 5:30:50, got: $maxstartups"
    fi
}

test_drop_in_media_team_config() {
    # Verify 02-media-team.conf: MaxSessions 5 and ClientAliveInterval 600 for bester.
    # The -C flag takes a single key=value token; pass user=bester so sshd
    # evaluates Match User blocks (bester is also in media-team group so the
    # Match Group media-team block fires).
    test_start "Drop-in 02-media-team.conf: MaxSessions 5 for media-team users"
    local maxsessions
    maxsessions=$(sshd_test_param "maxsessions" "user=bester") || true
    if [ "$maxsessions" = "5" ]; then
        test_pass
    else
        test_fail "Expected maxsessions 5 for bester (media-team), got: $maxsessions"
    fi

    test_start "Drop-in 02-media-team.conf: ClientAliveInterval 600 for media-team users"
    local interval
    interval=$(sshd_test_param "clientaliveinterval" "user=bester") || true
    if [ "$interval" = "600" ]; then
        test_pass
    else
        test_fail "Expected clientaliveinterval 600 for bester, got: $interval"
    fi
}

test_drop_in_strict_user_config() {
    # Verify 03-strict-user.conf: MaxAuthTries 1 for morden specifically.
    test_start "Drop-in 03-strict-user.conf: MaxAuthTries 1 for morden"
    local maxauthtries
    maxauthtries=$(sshd_test_param "maxauthtries" "user=morden") || true
    if [ "$maxauthtries" = "1" ]; then
        test_pass
    else
        test_fail "Expected maxauthtries 1 for morden, got: $maxauthtries"
    fi

    # Sanity check: bester (media-team) has MaxAuthTries 6, not 1.
    test_start "Sanity: MaxAuthTries for bester is not 1 (drop-in is user-specific)"
    local bester_tries
    bester_tries=$(sshd_test_param "maxauthtries" "user=bester") || true
    if [ "$bester_tries" != "1" ]; then
        test_pass
    else
        test_fail "bester unexpectedly has maxauthtries 1"
    fi
}

test_media_team_project_access() {
    for user in "${MEDIA_TEAM_USERS[@]}"; do
        test_start "User $user can see media-team project"
        local projects
        projects=$(sftp_list_projects "$user" "$SCRIPT_DIR/secrets/${user}_key" "$PORT")
        if printf '%s\n' "$projects" | grep -q "^media-team$"; then
            test_pass
        else
            test_fail "Expected to see media-team, got: $projects"
        fi
    done
}

test_shadow_council_access() {
    # morden can list projects; suppress agent to avoid MaxAuthTries 1 issues.
    test_start "User morden can see shadow-council project"
    local projects
    projects=$(
        unset SSH_AUTH_SOCK
        printf 'ls -1\n' | sftp -b - \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -P "$PORT" -i "$SCRIPT_DIR/secrets/morden_key" \
            "morden@localhost" 2>/dev/null | grep -v "^sftp>" | grep -v "^Connected" | sort
    ) || true
    if printf '%s\n' "$projects" | grep -q "^shadow-council$"; then
        test_pass
    else
        test_fail "Expected to see shadow-council, got: $projects"
    fi
}

test_file_operations() {
    local user="bester"
    local key="$SCRIPT_DIR/secrets/${user}_key"
    local test_file="$SCRIPT_DIR/.test-temp-custom.txt"
    local remote_path="media-team/psi-report.txt"

    printf '%s\n' "Classified Psi Corps report, eyes only." > "$test_file"

    test_start "User $user can upload to media-team"
    if sftp_put_file "$user" "$key" "$test_file" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "Failed to upload file"
        rm -f "$test_file"
        return
    fi

    test_start "User zack can access bester's file in media-team"
    if sftp_check_file_exists "zack" "$SCRIPT_DIR/secrets/zack_key" "$remote_path" "$PORT"; then
        test_pass
    else
        test_fail "zack cannot see file from bester"
    fi

    # Cleanup
    sftp_delete_file "$user" "$key" "$remote_path" "$PORT" 2>/dev/null || true
    rm -f "$test_file"
}

#=============================================================================
# RUN
#=============================================================================
main
