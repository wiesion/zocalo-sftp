#!/bin/bash
# Interactive setup script for 07-2fa example
# Sets up two-factor authentication (public key + password) for manual exploration

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="07-2fa"
USERS=("zathras" "corwin")

# Passwords, change these in production
ZATHRAS_PASSWORD="ZaZaZathras!42"
CORWIN_PASSWORD="EarthForce#2260"

#=============================================================================
# MAIN SETUP FLOW
#=============================================================================
main() {
    log_step "Setting up $EXAMPLE_NAME for interactive exploration"

    # Clean previous runs
    cleanup_all "$SCRIPT_DIR"

    # Generate host key and user keys
    log_step "Generating keys and password secrets"
    generate_host_key "$SCRIPT_DIR/secrets"

    for user in "${USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
        log_success "Key pair generated for $user"
    done

    # Write password secret files
    printf '%s' "$ZATHRAS_PASSWORD" > "$SCRIPT_DIR/secrets/zathras.password"
    printf '%s' "$CORWIN_PASSWORD"  > "$SCRIPT_DIR/secrets/corwin.password"
    chmod 600 "$SCRIPT_DIR/secrets/zathras.password" "$SCRIPT_DIR/secrets/corwin.password"
    log_success "Password secrets written"

    # Build image
    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"

    # Start services
    (cd "$SCRIPT_DIR" && docker_compose_up)

    # Show connection info
    printf "\n"
    log_step "Connection Information (2FA required)"
    printf "\n"
    printf "Both a matching key AND the correct password are required:\n\n"
    printf "  # As zathras (password: %s)\n" "$ZATHRAS_PASSWORD"
    printf "  sftp -P 2222 -i secrets/zathras_key zathras@localhost\n\n"
    printf "  # As corwin (password: %s)\n" "$CORWIN_PASSWORD"
    printf "  sftp -P 2222 -i secrets/corwin_key corwin@localhost\n\n"
    printf "  # Key-only or password-only connections will be rejected.\n\n"

    # Wait for user to finish
    wait_for_user

    # Cleanup on exit
    cleanup_all "$SCRIPT_DIR"
}

#=============================================================================
# RUN
#=============================================================================
main
