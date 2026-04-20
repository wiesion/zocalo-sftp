#!/bin/bash
# Interactive setup script for 06-password-auth example
# Sets up the environment and allows manual exploration

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="06-password-auth"
USERS=("delenn" "marcus")

# Passwords, change these to something strong in production
DELENN_PASSWORD="Minbari-G1432!"
MARCUS_PASSWORD="RangerPrime#99"

#=============================================================================
# MAIN SETUP FLOW
#=============================================================================
main() {
    log_step "Setting up $EXAMPLE_NAME for interactive exploration"

    # Clean previous runs
    cleanup_all "$SCRIPT_DIR"

    # Generate host key
    log_step "Generating host key and password secrets"
    generate_host_key "$SCRIPT_DIR/secrets"
    log_success "Host key generated"

    # Write password secret files
    printf '%s' "$DELENN_PASSWORD" > "$SCRIPT_DIR/secrets/delenn.password"
    printf '%s' "$MARCUS_PASSWORD" > "$SCRIPT_DIR/secrets/marcus.password"
    chmod 600 "$SCRIPT_DIR/secrets/delenn.password" "$SCRIPT_DIR/secrets/marcus.password"
    log_success "Password secrets written"

    # Build image
    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"

    # Start services
    (cd "$SCRIPT_DIR" && docker_compose_up)

    # Show connection info
    printf "\n"
    log_step "Connection Information"
    printf "\n"
    printf "Connect with password authentication:\n\n"
    printf "  # As delenn (password: %s)\n" "$DELENN_PASSWORD"
    printf "  sftp -P 2222 -o PreferredAuthentications=password delenn@localhost\n\n"
    printf "  # As marcus (password: %s)\n" "$MARCUS_PASSWORD"
    printf "  sftp -P 2222 -o PreferredAuthentications=password marcus@localhost\n\n"
    printf "  # Or with sshpass (if installed):\n"
    printf "  sshpass -p '%s' sftp -o StrictHostKeyChecking=no -P 2222 delenn@localhost\n\n" "$DELENN_PASSWORD"

    # Wait for user to finish
    wait_for_user

    # Cleanup on exit
    cleanup_all "$SCRIPT_DIR"
}

#=============================================================================
# RUN
#=============================================================================
main
