#!/bin/sh
# Generates a single SBOM (SPDX + CycloneDX) for a locally built zocalo-sftp
# image using syft, and optionally scans it for vulnerabilities with grype.
#
# Both tools run as Docker containers, no local installation required.
# The Docker socket is mounted read-only so syft can inspect local images
# without pulling from a registry.
#
# Usage:
#   ./scripts/generate-sbom.sh [IMAGE]
#
# Examples:
#   ./scripts/generate-sbom.sh                     # zocalo-sftp:latest
#   ./scripts/generate-sbom.sh zocalo-sftp:1.2.0
#
# sftp-reconciled is a stripped, statically linked Rust binary, invisible to
# image-based cataloging by default. The Dockerfile copies Cargo.lock into
# the final image for exactly this reason: with rust-cargo-lock-cataloger
# explicitly enabled (it's tagged for directory sources, not image sources,
# so it's off by default here), one syft scan catalogs both the apk packages
# and the full Cargo dependency tree (nix, notify, sha-crypt, signal-hook,
# transitives) in a single document. Verified empirically, not assumed.
#
# Output files are written to the current directory:
#   sbom.spdx.json      SPDX format
#   sbom.cyclonedx.json CycloneDX format
#
# Set SCAN=yes to also run a grype vulnerability scan against the generated
# SBOM (not a second image scan, scans exactly what was published):
#   SCAN=yes ./scripts/generate-sbom.sh

set -eu

IMAGE="${1:-zocalo-sftp:latest}"
SOCK="/var/run/docker.sock"
CATALOGERS="--select-catalogers +rust-cargo-lock-cataloger"

if ! command -v docker >/dev/null 2>&1; then
    printf 'Error: docker is required but not found in PATH\n' >&2
    exit 1
fi

if [ ! -S "$SOCK" ]; then
    printf 'Error: Docker socket not found at %s\n' "$SOCK" >&2
    printf 'If you are using Docker Desktop on macOS, the socket should be\n' >&2
    printf 'symlinked automatically. Try restarting Docker Desktop.\n' >&2
    exit 1
fi

# Verify the target image is available locally before spinning up syft
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'Error: image %s not found locally. Build it first:\n' "$IMAGE" >&2
    printf '  docker build -t %s .\n' "$IMAGE" >&2
    exit 1
fi

printf 'Generating SBOM for %s\n' "$IMAGE"

# shellcheck disable=SC2086  # CATALOGERS is a deliberate word-split flag pair
docker run --rm \
    -v "${SOCK}:${SOCK}:ro" \
    anchore/syft:latest \
    "docker:${IMAGE}" \
    $CATALOGERS \
    -o spdx-json \
    > sbom.spdx.json

# shellcheck disable=SC2086
docker run --rm \
    -v "${SOCK}:${SOCK}:ro" \
    anchore/syft:latest \
    "docker:${IMAGE}" \
    $CATALOGERS \
    -o cyclonedx-json \
    > sbom.cyclonedx.json

printf 'Written:\n'
printf '  sbom.spdx.json\n'
printf '  sbom.cyclonedx.json\n'

if [ "${SCAN:-no}" = "yes" ]; then
    printf '\nRunning vulnerability scan with grype...\n'
    docker run --rm \
        -v "$(pwd)/sbom.spdx.json:/sbom.json:ro" \
        anchore/grype:latest \
        sbom:/sbom.json
fi
