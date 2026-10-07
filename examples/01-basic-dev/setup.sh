#!/bin/bash
# Interactive setup script for 01-basic-dev example
# Sets up the environment and allows manual exploration

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="01-basic-dev"
USERS=("sheridan" "garibaldi")

#=============================================================================
# MAIN SETUP FLOW
#=============================================================================
main() {
    log_step "Setting up $EXAMPLE_NAME for interactive exploration"

    # Clean previous runs
    cleanup_all "$SCRIPT_DIR"

    # Setup environment
    log_step "Generating SSH keys"
    generate_host_key "$SCRIPT_DIR/secrets"

    for user in "${USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
        log_success "Generated keys for $user"
    done

    # Build image
    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"

    # Start services
    (cd "$SCRIPT_DIR" && docker_compose_up)

    # Show connection info
    show_connection_info "${USERS[@]}"

    # Wait for user to finish
    wait_for_user

    # Cleanup on exit
    cleanup_all "$SCRIPT_DIR"
}

#=============================================================================
# RUN
#=============================================================================
main
