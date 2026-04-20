#!/bin/bash
# Interactive setup script for 04-multi-project example
# Sets up the environment and allows manual exploration

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="04-multi-project"
ALL_USERS=("sheridan" "ivanova" "franklin" "sinclair" "garibaldi" "lyta")

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

    for user in "${ALL_USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
        log_success "Generated keys for $user"
    done

    # Build image
    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"

    # Start services
    (cd "$SCRIPT_DIR" && docker_compose_up)

    # Show access matrix
    show_access_matrix

    # Show connection info
    show_connection_info "${ALL_USERS[@]}"

    # Wait for user to finish
    wait_for_user

    # Cleanup on exit
    cleanup_all "$SCRIPT_DIR"
}

show_access_matrix() {
    echo
    log_step "Access Matrix"
    echo
    echo -e "  ${BOLD}User${RESET}          ${BOLD}Projects${RESET}"
    echo -e "  ${GRAY}─────────────────────────────────────────────${RESET}"
    echo -e "  sheridan      command-staff, security, shared-intel"
    echo -e "  ivanova       command-staff, shared-intel"
    echo -e "  sinclair      command-staff, shared-intel"
    echo -e "  garibaldi     security, shared-intel"
    echo -e "  franklin      medlab ${GRAY}(isolated)${RESET}"
    echo -e "  lyta          telepath-ops ${GRAY}(isolated)${RESET}"
    echo
}

#=============================================================================
# RUN
#=============================================================================
main
