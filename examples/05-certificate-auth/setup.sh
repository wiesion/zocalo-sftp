#!/bin/bash
# Interactive setup script for 05-certificate-auth example
# Sets up the environment and allows manual exploration

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Load test helpers
source "$LIB_DIR/test-helpers.sh"

# Configuration
EXAMPLE_NAME="05-certificate-auth"
USERS=("sheridan" "ivanova")

#=============================================================================
# MAIN SETUP FLOW
#=============================================================================
main() {
    log_step "Setting up $EXAMPLE_NAME for interactive exploration"

    # Clean previous runs
    cleanup_all "$SCRIPT_DIR"

    # Setup environment
    log_step "Generating SSH keys and certificates"
    generate_host_key "$SCRIPT_DIR/secrets"
    log_success "Host key generated"

    # Generate CA
    generate_ca_key "$SCRIPT_DIR/secrets"
    log_success "Certificate Authority created"

    # Generate and sign user certificates
    for user in "${USERS[@]}"; do
        generate_user_certificate "$SCRIPT_DIR/secrets" "$user"
        log_success "Certificate signed for $user (valid for 52 weeks)"
    done

    # Build image
    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"

    # Start services
    (cd "$SCRIPT_DIR" && docker_compose_up)

    # Show certificate info
    show_certificate_info

    # Show connection info
    show_connection_info "${USERS[@]}"

    # Wait for user to finish
    wait_for_user

    # Cleanup on exit
    cleanup_all "$SCRIPT_DIR"
}

show_certificate_info() {
    echo
    log_step "Certificate Information"
    echo

    for user in "${USERS[@]}"; do
        if [ -f "$SCRIPT_DIR/secrets/${user}_key-cert.pub" ]; then
            echo -e "${CYAN}Certificate for $user:${RESET}"

            # Extract key info
            cert_info=$(ssh-keygen -L -f "$SCRIPT_DIR/secrets/${user}_key-cert.pub" 2>/dev/null)

            # Show validity period
            validity=$(echo "$cert_info" | grep "Valid:" | sed 's/^[[:space:]]*//')
            echo -e "  $validity"

            # Show principal
            principal=$(echo "$cert_info" | grep -A1 "Principals:" | tail -1 | sed 's/^[[:space:]]*//')
            echo -e "  Principal: $principal"
            echo
        fi
    done

    log_info "To inspect certificates manually:"
    echo -e "  ${GRAY}ssh-keygen -L -f secrets/<user>_key-cert.pub${RESET}"
    echo
}

#=============================================================================
# RUN
#=============================================================================
main
