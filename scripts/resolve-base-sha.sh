#!/bin/sh
# Resolves the current digest for cgr.dev/chainguard/wolfi-base:latest using
# the OCI Distribution API. No Docker daemon required, only curl and awk.
#
# Usage:
#   ./scripts/resolve-base-sha.sh
#
# To pin the resolved digest in a build:
#   BASE_IMAGE=$(./scripts/resolve-base-sha.sh)
#   docker build --build-arg BASE_IMAGE="$BASE_IMAGE" .
#
# Why pin? Chainguard rebuilds wolfi-base:latest continuously and does not
# guarantee long-term availability of older digests. Pinning a digest gives
# you a reproducible build for as long as that digest remains cached locally
# or in a registry mirror.

set -eu

REGISTRY="cgr.dev"
REPO="chainguard/wolfi-base"
TAG="latest"

# Step 1: obtain an anonymous pull token for the repository
TOKEN=$(curl -sf \
    "https://${REGISTRY}/token?scope=repository:${REPO}:pull&service=${REGISTRY}" \
    | awk -F'"' '/"token"/{for(i=1;i<=NF;i++) if($i=="token") {print $(i+2); exit}}')

if [ -z "$TOKEN" ]; then
    printf 'Error: failed to obtain registry token\n' >&2
    exit 1
fi

# Step 2: HEAD the manifest to read the content digest without downloading it.
# Accept both OCI index and Docker manifest-list so the digest covers all platforms.
DIGEST=$(curl -sf -I \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://${REGISTRY}/v2/${REPO}/manifests/${TAG}" \
    | awk 'tolower($1)=="docker-content-digest:" {gsub(/\r/,"",$2); print $2; exit}')

if [ -z "$DIGEST" ]; then
    printf 'Error: failed to resolve digest for %s:%s\n' "$REPO" "$TAG" >&2
    exit 1
fi

printf '%s/%s@%s\n' "$REGISTRY" "$REPO" "$DIGEST"
