#!/bin/bash
# Interactive setup script for 09-kubernetes example
# Stands up a disposable kind + Calico cluster, deploys zocalo-sftp as a
# StatefulSet, and leaves it running for manual exploration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$LIB_DIR/test-helpers.sh"
# shellcheck source=lib-k8s.sh
source "$SCRIPT_DIR/lib-k8s.sh"

CLUSTER_NAME="zocalo-sftp-dev"
NAMESPACE="zocalo-example"
USERS=("byron" "lochley")
SECRETS_DIR="$SCRIPT_DIR/secrets"

main() {
    log_step "Setting up 09-kubernetes for interactive exploration"

    require_k8s_tools
    trap cleanup EXIT

    create_kind_cluster "$CLUSTER_NAME"
    assert_test_context "$CLUSTER_NAME"

    # Same default tag as test.sh, matching the manifest's placeholder image,
    # no reason for these to differ; a mismatch here forces an extra rollout
    # (apply creates a pod referencing a tag that was never loaded, then the
    # set-image patch below replaces it) for no benefit.
    build_and_load_image "$SCRIPT_DIR/../.." "zocalo-sftp:k8s-test" "$CLUSTER_NAME"

    log_step "Generating keys and secrets"
    mkdir -p "$SECRETS_DIR"
    generate_host_key "$SECRETS_DIR"
    for user in "${USERS[@]}"; do
        generate_user_key "$SECRETS_DIR" "$user"
        log_success "Generated keys for $user"
    done

    log_step "Applying manifests"
    kubectl apply -k "$SCRIPT_DIR/manifests"

    kubectl -n "$NAMESPACE" create secret generic zocalo-host-key \
        --from-file=ssh_host_ed25519_key="$SECRETS_DIR/ssh_host_ed25519_key" \
        --dry-run=client -o yaml | kubectl apply -f -

    local user_secret_args=()
    for user in "${USERS[@]}"; do
        user_secret_args+=("--from-file=${user}.authorized_keys=$SECRETS_DIR/${user}.authorized_keys")
    done
    kubectl -n "$NAMESPACE" create secret generic zocalo-user-secrets \
        "${user_secret_args[@]}" --dry-run=client -o yaml | kubectl apply -f -

    local current_image
    current_image="$(kubectl -n "$NAMESPACE" get statefulset/zocalo-sftp -o jsonpath='{.spec.template.spec.containers[0].image}')"
    if [ "$current_image" != "$SFTP_IMAGE" ]; then
        kubectl -n "$NAMESPACE" set image statefulset/zocalo-sftp "sftp=$SFTP_IMAGE"
    fi

    wait_for_statefulset_ready "$NAMESPACE" zocalo-sftp 120s

    show_connection_info
    wait_for_user
}

show_connection_info() {
    echo
    log_step "Cluster is up, StatefulSet zocalo-sftp/0 is Ready"
    echo
    echo -e "  ${CYAN}Port-forward SFTP:${RESET}    kubectl -n $NAMESPACE port-forward svc/zocalo-sftp 2222:22"
    echo -e "  ${CYAN}Port-forward metrics:${RESET} kubectl -n $NAMESPACE port-forward svc/zocalo-sftp 9100:9100"
    echo -e "  ${CYAN}Connect (byron):${RESET}      sftp -P 2222 -i $SECRETS_DIR/byron_key byron@localhost"
    echo -e "  ${CYAN}Connect (lochley):${RESET}    sftp -P 2222 -i $SECRETS_DIR/lochley_key lochley@localhost"
    echo -e "  ${CYAN}Logs:${RESET}                 kubectl -n $NAMESPACE logs -f zocalo-sftp-0"
    echo -e "  ${CYAN}Pod status:${RESET}           kubectl -n $NAMESPACE get pods"
    echo
    echo -e "  ${CYAN}NetworkPolicy demo${RESET}: metrics are blocked from any pod without"
    echo -e "  the right label/namespace. Try it yourself:"
    echo -e "    kubectl run denied --restart=Never --image=curlimages/curl -n $NAMESPACE -- \\"
    echo -e "      curl -s -m5 http://zocalo-sftp.$NAMESPACE.svc:9100/metrics   ${GRAY}# hangs / refused${RESET}"
    echo
}

wait_for_user() {
    echo -e "${YELLOW}Press Enter to tear everything down...${RESET}"
    read -r
}

cleanup() {
    log_step "Cleaning up"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "$SECRETS_DIR"
    teardown_kind_cluster "$CLUSTER_NAME"
}

main
