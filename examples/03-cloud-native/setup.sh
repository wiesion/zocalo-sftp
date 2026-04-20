#!/bin/bash
# Interactive setup script for 03-cloud-native example
# Sets up the environment and allows manual exploration

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="03-cloud-native"
USERS=("londo" "vir")

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

    # Show cloud-native features
    show_cloud_features

    # Show connection info
    show_connection_info "${USERS[@]}"

    # Wait for user to finish
    wait_for_user

    # Cleanup on exit
    cleanup_all "$SCRIPT_DIR"
}

show_cloud_features() {
    echo
    log_step "Cloud-Native Features"
    echo
    echo -e "  ${CYAN}Metrics:${RESET}     http://localhost:9100/metrics"
    echo -e "  ${CYAN}Prometheus:${RESET}  http://localhost:9090"
    echo -e "  ${CYAN}JSON Logs:${RESET}   docker compose logs -f sftp"
    echo -e "  ${CYAN}Health:${RESET}      docker compose ps"
    echo
}

#=============================================================================
# RUN
#=============================================================================
main
