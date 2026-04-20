#!/bin/bash
# Interactive setup script for 08-custom-config example
# Demonstrates sshd_config.d drop-in overrides for per-group and per-user settings

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="08-custom-config"
ALL_USERS=("bester" "zack" "morden")

#=============================================================================
# MAIN SETUP FLOW
#=============================================================================
main() {
    log_step "Setting up $EXAMPLE_NAME for interactive exploration"

    # Clean previous runs
    cleanup_all "$SCRIPT_DIR"

    # Generate keys
    log_step "Generating SSH keys"
    generate_host_key "$SCRIPT_DIR/secrets"

    for user in "${ALL_USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
        log_success "Key pair generated for $user"
    done

    # Build image
    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"

    # Start services
    (cd "$SCRIPT_DIR" && docker_compose_up)

    # Show drop-in config summary
    printf "\n"
    log_step "Active Drop-in Configuration"
    printf "\n"
    printf "Drop-in files mounted from ./config/sshd_config.d/:\n\n"
    printf "  01-global.conf     : MaxStartups 5:30:50 (tighter connection queue)\n"
    printf "  02-media-team.conf : Match Group media-team: MaxSessions 5,\n"
    printf "                       ClientAliveInterval 600 (relaxed for large transfers)\n"
    printf "  03-strict-user.conf : Match User morden: MaxAuthTries 1\n\n"
    printf "To inspect the effective sshd configuration:\n\n"
    printf "  # Global settings:\n"
    printf "  docker compose exec sftp sshd -T | grep maxstartups\n\n"
    printf "  # Settings for media-team group (bester, zack):\n"
    printf "  docker compose exec sftp sshd -T \\\\\n"
    printf "    -C 'user=bester,group=media-team,host=localhost,addr=127.0.0.1'\n\n"
    printf "  # Settings for morden:\n"
    printf "  docker compose exec sftp sshd -T \\\\\n"
    printf "    -C 'user=morden,group=sftp_users,host=localhost,addr=127.0.0.1'\n\n"

    # Show connection info
    show_connection_info "${ALL_USERS[@]}"

    # Wait for user to finish
    wait_for_user

    # Cleanup on exit
    cleanup_all "$SCRIPT_DIR"
}

#=============================================================================
# RUN
#=============================================================================
main
