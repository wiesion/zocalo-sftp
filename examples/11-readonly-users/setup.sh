#!/bin/bash
# Interactive setup script for 11-readonly-users example
# Sets up the environment and allows manual exploration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
source "$LIB_DIR/test-helpers.sh"

EXAMPLE_NAME="11-readonly-users"
# ivanova_ro has no key of its own: it logs in with ivanova's key.
KEY_USERS=("ivanova" "garibaldi" "kosh")

main() {
    log_step "Setting up $EXAMPLE_NAME for interactive exploration"

    cleanup_all "$SCRIPT_DIR"

    log_step "Generating SSH keys"
    generate_host_key "$SCRIPT_DIR/secrets"
    for user in "${KEY_USERS[@]}"; do
        generate_user_key "$SCRIPT_DIR/secrets" "$user"
        log_success "Generated keys for $user"
    done

    docker_build "$SCRIPT_DIR/../.." "zocalo-sftp:test"
    (cd "$SCRIPT_DIR" && docker_compose_up)

    show_access_matrix
    show_connection_info "${KEY_USERS[@]}"
    printf "  ${CYAN}# As ivanova_ro (ivanova's key, read-only)${RESET}\n"
    printf "  sftp -P 2222 -i secrets/ivanova_key ivanova_ro@localhost\n\n"

    wait_for_user
    cleanup_all "$SCRIPT_DIR"
}

show_access_matrix() {
    echo
    log_step "Access Matrix"
    echo
    echo -e "  ${BOLD}Login${RESET}       ${BOLD}Mode${RESET}        ${BOLD}Projects${RESET}"
    echo -e "  ${GRAY}─────────────────────────────────────────────${RESET}"
    echo -e "  ivanova     read-write  command-staff"
    echo -e "  ivanova_ro  read-only   command-staff ${GRAY}(same key as ivanova)${RESET}"
    echo -e "  garibaldi   read-write  security"
    echo -e "  kosh        read-only   command-staff, security"
    echo
}

main
