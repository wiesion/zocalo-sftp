#!/bin/bash
# Shared test library for Zocalo SFTP examples
# Provides common functionality for setup.sh and test.sh scripts

set -euo pipefail

#=============================================================================
# COLOR OUTPUT
#=============================================================================
# Initialise colors: empty when NO_COLOR is set or output is not a terminal
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    readonly RED="" GREEN="" YELLOW="" BLUE="" CYAN="" GRAY="" BOLD="" RESET=""
else
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly GRAY='\033[0;90m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
fi

#=============================================================================
# LOGGING FUNCTIONS
#=============================================================================
log_info() {
    printf "${BLUE}ℹ${RESET} %s\n" "$*"
}

log_success() {
    printf "${GREEN}✓${RESET} %s\n" "$*"
}

log_error() {
    printf "${RED}✗${RESET} %s\n" "$*" >&2
}

log_warning() {
    printf "${YELLOW}⚠${RESET} %s\n" "$*"
}

log_step() {
    printf "\n${BOLD}${CYAN}▶${RESET} ${BOLD}%s${RESET}\n" "$*"
}

log_debug() {
    if [ -n "${DEBUG:-}" ]; then
        printf "${GRAY}[DEBUG]${RESET} %s\n" "$*" >&2
    fi
}

#=============================================================================
# TEST RESULT TRACKING
#=============================================================================
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TESTS_TOTAL=0

test_start() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    printf "${CYAN}→${RESET} %s... " "$*"
}

test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "${GREEN}PASS${RESET}\n"
}

test_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "${RED}FAIL${RESET}\n"
    if [ -n "${1:-}" ]; then
        printf "  ${RED}↳${RESET} %s\n" "$1"
    fi
}

test_skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    printf "${YELLOW}SKIP${RESET}\n"
    if [ -n "${1:-}" ]; then
        printf "  ${YELLOW}↳${RESET} %s\n" "$1"
    fi
}

test_summary() {
    printf "\n"
    printf "${BOLD}Test Summary:${RESET}\n"
    printf "  Total:  %s\n" "$TESTS_TOTAL"
    printf "  ${GREEN}Passed: %s${RESET}\n" "$TESTS_PASSED"
    if [ "$TESTS_SKIPPED" -gt 0 ]; then
        printf "  ${YELLOW}Skipped: %s${RESET}\n" "$TESTS_SKIPPED"
    fi
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf "  ${RED}Failed: %s${RESET}\n" "$TESTS_FAILED"
        return 1
    fi
    return 0
}

#=============================================================================
# SSH KEY GENERATION
#=============================================================================
generate_ssh_key() {
    local key_path="$1"
    local key_name
    key_name=$(basename -- "$key_path")

    if [ -f "$key_path" ]; then
        log_debug "Key $key_name already exists, skipping"
        return 0
    fi

    log_debug "Generating key: $key_name"
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "$key_name" >/dev/null 2>&1
}

generate_host_key() {
    local secrets_dir="$1"
    mkdir -p "$secrets_dir"
    generate_ssh_key "$secrets_dir/ssh_host_ed25519_key"
}

generate_user_key() {
    local secrets_dir="$1"
    local username="$2"

    mkdir -p "$secrets_dir"
    generate_ssh_key "$secrets_dir/${username}_key"
    cat "$secrets_dir/${username}_key.pub" > "$secrets_dir/${username}.authorized_keys"
}

#=============================================================================
# SSH CERTIFICATE GENERATION
#=============================================================================
generate_ca_key() {
    local secrets_dir="$1"
    local ca_name="${2:-ssh_user_ca}"

    mkdir -p "$secrets_dir"

    if [ -f "$secrets_dir/$ca_name" ]; then
        log_debug "CA key $ca_name already exists, skipping"
        return 0
    fi

    log_debug "Generating CA key: $ca_name"
    ssh-keygen -t ed25519 -f "$secrets_dir/$ca_name" -N "" -C "SFTP User CA" >/dev/null 2>&1
}

generate_user_certificate() {
    local secrets_dir="$1"
    local username="$2"
    local ca_key="${3:-ssh_user_ca}"
    local validity="${4:-+52w}"

    mkdir -p "$secrets_dir"

    # Generate user keypair if it doesn't exist
    if [ ! -f "$secrets_dir/${username}_key" ]; then
        ssh-keygen -t ed25519 -f "$secrets_dir/${username}_key" -N "" -C "${username}@sftp" >/dev/null 2>&1
    fi

    # Sign the user's public key with the CA
    log_debug "Signing certificate for $username"
    ssh-keygen -s "$secrets_dir/$ca_key" \
        -I "${username}-$(date +%Y)" \
        -n "$username" \
        -V "$validity" \
        "$secrets_dir/${username}_key.pub" >/dev/null 2>&1

    # This creates ${username}_key-cert.pub
}

#=============================================================================
# DOCKER OPERATIONS
#=============================================================================
docker_build() {
    local context_dir="$1"
    local image_name="${2:-zocalo-sftp:test}"

    # In CI, SFTP_IMAGE is pre-set and the image is already loaded, so skip the
    # build to avoid redundant work. Also export so compose picks it up.
    if [ -n "${SFTP_IMAGE:-}" ]; then
        log_info "Using pre-built image: $SFTP_IMAGE (skipping build)"
        return 0
    fi

    log_step "Building Docker image"
    docker build -t "$image_name" "$context_dir" || {
        log_error "Failed to build Docker image"
        return 1
    }
    export SFTP_IMAGE="$image_name"
    log_success "Image built: $image_name"
}

docker_compose_up() {
    local ssh_port="${1:-2222}"

    log_step "Starting services with docker compose"
    # Brief pause to let Docker Desktop's VirtioFS propagate newly written
    # secret files into the Linux VM. On a warm build cache, compose up fires
    # within milliseconds of ssh-keygen; without the pause the VM hasn't
    # synced the directory yet and reports "bind source path does not exist".
    # Two seconds is sufficient in practice; this is a no-op on Linux CI.
    sleep 2
    docker compose up -d || {
        log_error "Failed to start services"
        return 1
    }

    # Wait until sshd is actually accepting connections, not just until the
    # container is "Up". ssh-keyscan connects and retrieves host keys; it
    # returns 0 as soon as the SSH banner is received.
    log_info "Waiting for SFTP service to be ready..."
    local max_wait=30
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if ssh-keyscan -t ed25519 -p "$ssh_port" -T 1 127.0.0.1 >/dev/null 2>&1; then
            log_success "Services are running"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_error "Service failed to start within ${max_wait}s"
    docker compose logs
    return 1
}

docker_compose_down() {
    if [ "$TESTS_FAILED" -gt 0 ]; then
        log_step "Dumping container logs (tests failed)"
        docker compose logs
    fi
    log_step "Stopping services"
    docker compose down -v 2>/dev/null || true
    log_success "Services stopped"
}

# Check if the sftp-jail project directory enforces POSIX permissions.
# Docker Desktop on macOS uses VirtioFS with a "fakeowner" pseudo-filesystem for
# bind mounts. fakeowner bypasses UID/GID enforcement at the kernel level, so
# group-based isolation tests cannot pass on macOS Docker Desktop with bind mounts.
# Returns 0 if proper enforcement is available (real Linux fs), 1 if not (fakeowner).
projects_enforce_permissions() {
    local compose_dir="${1:-.}"
    local fstype
    # findmnt may not be available in all container images; fall back to
    # /proc/mounts which is a kernel interface present on all Linux containers.
    fstype=$(cd "$compose_dir" && docker compose exec -T sftp \
        sh -c 'findmnt -n -o FSTYPE /sftp-jail/projects 2>/dev/null ||
               awk "\$2==\"/sftp-jail/projects\"{print \$3;exit}" /proc/mounts 2>/dev/null' \
        2>/dev/null | tr -d '[:space:]')
    [ "$fstype" != "fakeowner" ]
}

docker_cleanup() {
    log_step "Cleaning up Docker resources"
    docker compose down -v 2>/dev/null || true
    # Remove test images if they exist
    docker rmi zocalo-sftp:test 2>/dev/null || true
}

#=============================================================================
# SFTP OPERATIONS
#=============================================================================
sftp_connect_test() {
    local user="$1"
    local key_path="$2"
    local port="${3:-2222}"
    local host="${4:-localhost}"

    # Try to connect and execute pwd command
    echo "pwd" | sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
        -P "$port" -i "$key_path" "$user@$host" >/dev/null 2>&1
}

sftp_list_projects() {
    local user="$1"
    local key_path="$2"
    local port="${3:-2222}"
    local host="${4:-localhost}"

    # || true: under set -e + pipefail, a failed connection would otherwise
    # kill the whole test script instead of letting the caller's grep -q
    # check on an empty result report a clean test failure.
    echo "ls -1" | sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
        -P "$port" -i "$key_path" "$user@$host" 2>/dev/null | grep -v "^sftp>" | grep -v "^Connected" | sort || true
}

sftp_put_file() {
    local user="$1"
    local key_path="$2"
    local local_file="$3"
    local remote_path="$4"
    local port="${5:-2222}"
    local host="${6:-localhost}"

    echo "put $local_file $remote_path" | sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
        -P "$port" -i "$key_path" "$user@$host" >/dev/null 2>&1
}

sftp_get_file() {
    local user="$1"
    local key_path="$2"
    local remote_path="$3"
    local local_file="$4"
    local port="${5:-2222}"
    local host="${6:-localhost}"

    echo "get $remote_path $local_file" | sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
        -P "$port" -i "$key_path" "$user@$host" >/dev/null 2>&1
}

sftp_delete_file() {
    local user="$1"
    local key_path="$2"
    local remote_path="$3"
    local port="${4:-2222}"
    local host="${5:-localhost}"

    echo "rm $remote_path" | sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
        -P "$port" -i "$key_path" "$user@$host" >/dev/null 2>&1
}

sftp_check_file_exists() {
    local user="$1"
    local key_path="$2"
    local remote_path="$3"
    local port="${4:-2222}"
    local host="${5:-localhost}"

    echo "ls $remote_path" | sftp -b - -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
        -P "$port" -i "$key_path" "$user@$host" >/dev/null 2>&1
}

#=============================================================================
# CLEANUP AND SETUP
#=============================================================================
cleanup_all() {
    local example_dir="$1"

    log_step "Cleaning up previous runs"

    # Stop containers
    (cd "$example_dir" && docker_compose_down)

    # Remove generated files
    rm -rf -- "$example_dir/secrets"

    # Project directories under data/ are created by the containerized sftp
    # process running as root, so on a real Linux host (no fakeowner, unlike
    # Docker Desktop's VirtioFS) they're owned by UID 0 on the bind mount and
    # the unprivileged host user cannot remove them directly. Reclaim
    # ownership via a disposable root container first.
    if [ -d "$example_dir/data" ]; then
        docker run --rm -v "$example_dir/data:/data" busybox \
            chown -R "$(id -u):$(id -g)" /data >/dev/null 2>&1 || true
    fi
    rm -rf -- "$example_dir/data"
    rm -f -- "$example_dir/.test-temp-"*

    log_success "Cleanup complete"
}

setup_test_environment() {
    local example_dir="$1"

    # Ensure we're in the right directory
    if [ ! -f "$example_dir/compose.yml" ]; then
        log_error "compose.yml not found in $example_dir"
        return 1
    fi

    # Clean previous runs
    cleanup_all "$example_dir"

    # Create necessary directories
    mkdir -p "$example_dir/secrets"
    mkdir -p "$example_dir/data"
}

#=============================================================================
# ASSERTIONS
#=============================================================================
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values do not match}"

    if [ "$expected" = "$actual" ]; then
        return 0
    else
        log_error "$message"
        log_error "  Expected: $expected"
        log_error "  Actual:   $actual"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String not found}"

    # -F: treat needle as a fixed string, not a regex
    if printf '%s\n' "$haystack" | grep -qF "$needle"; then
        return 0
    else
        log_error "$message"
        log_error "  Looking for: $needle"
        log_error "  In: $haystack"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not be present}"

    # -F: treat needle as a fixed string, not a regex
    if ! printf '%s\n' "$haystack" | grep -qF "$needle"; then
        return 0
    else
        log_error "$message"
        log_error "  Found unexpected: $needle"
        return 1
    fi
}

#=============================================================================
# INTERACTIVE HELPERS
#=============================================================================

# LOGS_PID is set by wait_for_user and read by cleanup_on_interrupt
LOGS_PID=

show_connection_info() {
    local users=("$@")

    printf "\n"
    log_step "Connection Information"
    printf "\n"

    printf "Use these commands to connect:\n\n"

    for user in "${users[@]}"; do
        printf "  ${CYAN}# As %s${RESET}\n" "$user"
        printf "  sftp -P 2222 -i secrets/%s_key %s@localhost\n\n" "$user" "$user"
    done

    printf "${YELLOW}Press Ctrl+C when done to clean up${RESET}\n"
}

wait_for_user() {
    trap cleanup_on_interrupt INT
    printf "\n"
    log_info "Services are running. Press Ctrl+C to stop and cleanup."

    # Follow logs in background, but allow interrupt
    docker compose logs -f &
    LOGS_PID=$!

    # Wait for interrupt
    wait "$LOGS_PID" 2>/dev/null || true
}

cleanup_on_interrupt() {
    printf "\n"
    log_step "Interrupt received, cleaning up..."
    if [ -n "$LOGS_PID" ]; then kill "$LOGS_PID" 2>/dev/null || true; fi
    docker_compose_down
    exit 0
}
