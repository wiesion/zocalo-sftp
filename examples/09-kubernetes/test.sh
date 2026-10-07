#!/bin/bash
# Automated test script for 09-kubernetes example
# Tests StatefulSet deployment, split liveness/readiness probes, and
# NetworkPolicy enforcement on a disposable kind + Calico cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$LIB_DIR/test-helpers.sh"
# shellcheck source=lib-k8s.sh
source "$SCRIPT_DIR/lib-k8s.sh"

CLUSTER_NAME="zocalo-sftp-test"
NAMESPACE="zocalo-example"
USERS=("byron" "lochley")
PROJECT="downbelow"
LOCAL_SFTP_PORT=12225
LOCAL_METRICS_PORT=19100
PF_PID=""
SECRETS_DIR="$SCRIPT_DIR/secrets"

#=============================================================================
# MAIN TEST FLOW
#=============================================================================
main() {
    log_step "Starting tests for 09-kubernetes"

    require_k8s_tools
    trap cleanup EXIT

    create_kind_cluster "$CLUSTER_NAME"
    assert_test_context "$CLUSTER_NAME"

    build_and_load_image "$SCRIPT_DIR/../.." "zocalo-sftp:k8s-test" "$CLUSTER_NAME"

    log_step "Generating keys and secrets"
    mkdir -p "$SECRETS_DIR"
    generate_host_key "$SECRETS_DIR"
    for user in "${USERS[@]}"; do
        generate_user_key "$SECRETS_DIR" "$user"
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

    # build_and_load_image always loads under the manifest's own placeholder
    # tag (retagging a pre-built SFTP_IMAGE if one was supplied), so the
    # StatefulSet never needs a post-apply image patch here.
    wait_for_statefulset_ready "$NAMESPACE" zocalo-sftp 120s

    run_tests

    echo
    test_summary
    exit $?
}

#=============================================================================
# TEST CASES
#=============================================================================
run_tests() {
    log_step "Running test cases"

    test_pod_ready
    test_sftp_login
    test_file_roundtrip
    test_networkpolicy_blocks_unlabeled
    test_networkpolicy_allows_monitoring
    test_port22_open_to_all
    test_probes_configured
}

test_pod_ready() {
    test_start "StatefulSet pod is Ready"
    local ready
    ready="$(kubectl -n "$NAMESPACE" get pod zocalo-sftp-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
    if [ "$ready" = "true" ]; then
        test_pass
    else
        test_fail "pod not Ready: $(kubectl -n "$NAMESPACE" get pod zocalo-sftp-0 2>&1)"
    fi
}

start_port_forward() {
    kubectl -n "$NAMESPACE" port-forward svc/zocalo-sftp \
        "${LOCAL_SFTP_PORT}:22" "${LOCAL_METRICS_PORT}:9100" >/tmp/zocalo-k8s-pf.log 2>&1 &
    PF_PID=$!
    local waited=0
    while ! ssh-keyscan -t ed25519 -p "$LOCAL_SFTP_PORT" -T 1 127.0.0.1 >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 15 ]; then
            log_error "port-forward never became reachable"
            return 1
        fi
    done
}

stop_port_forward() {
    if [ -n "$PF_PID" ]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
        PF_PID=""
    fi
}

sftp_run() {
    local user="$1" commands="$2"
    sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 \
         -P "$LOCAL_SFTP_PORT" -i "$SECRETS_DIR/${user}_key" "${user}@localhost" \
         <<< "$commands" 2>&1
}

test_sftp_login() {
    test_start "User byron can authenticate via pubkey"
    start_port_forward
    local out
    out="$(sftp_run byron "pwd")"
    if echo "$out" | grep -q "Remote working directory: /projects"; then
        test_pass
    else
        test_fail "$out"
    fi
}

test_file_roundtrip() {
    test_start "User byron can upload and list a file in $PROJECT"
    local tmpfile
    tmpfile="$(mktemp)"
    echo "hello from byron" > "$tmpfile"
    local out
    out="$(sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 \
         -P "$LOCAL_SFTP_PORT" -i "$SECRETS_DIR/byron_key" byron@localhost 2>&1 <<EOF
cd $PROJECT
put $tmpfile roundtrip.txt
ls -l roundtrip.txt
EOF
)"
    rm -f "$tmpfile"
    stop_port_forward
    if echo "$out" | grep -q "roundtrip.txt"; then
        test_pass
    else
        test_fail "$out"
    fi
}

test_networkpolicy_blocks_unlabeled() {
    test_start "Metrics port blocked from an unlabeled pod (NetworkPolicy)"
    kubectl -n "$NAMESPACE" delete pod netpol-denied --ignore-not-found >/dev/null 2>&1
    kubectl -n "$NAMESPACE" run netpol-denied --restart=Never --image=curlimages/curl --command -- \
        sh -c "curl -s -m 5 -o /dev/null -w 'HTTP_%{http_code}' http://zocalo-sftp.$NAMESPACE.svc:9100/metrics || echo BLOCKED" >/dev/null
    local result
    result="$(wait_for_pod_log netpol-denied 15)"
    kubectl -n "$NAMESPACE" delete pod netpol-denied --ignore-not-found >/dev/null 2>&1
    if echo "$result" | grep -q "BLOCKED\|HTTP_000"; then
        test_pass
    else
        test_fail "expected blocked, got: $result"
    fi
}

test_networkpolicy_allows_monitoring() {
    test_start "Metrics port reachable from a role=monitoring pod"
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n monitoring delete pod netpol-allowed --ignore-not-found >/dev/null 2>&1
    kubectl -n monitoring run netpol-allowed --restart=Never --image=curlimages/curl \
        --labels="role=monitoring" --command -- \
        sh -c "curl -s -m 5 -o /dev/null -w 'HTTP_%{http_code}' http://zocalo-sftp.$NAMESPACE.svc:9100/metrics || echo BLOCKED" >/dev/null
    local result
    result="$(wait_for_pod_log netpol-allowed 15 monitoring)"
    kubectl -n monitoring delete pod netpol-allowed --ignore-not-found >/dev/null 2>&1
    if echo "$result" | grep -q "HTTP_200"; then
        test_pass
    else
        test_fail "expected HTTP_200, got: $result"
    fi
}

test_port22_open_to_all() {
    test_start "SFTP port stays open to an unlabeled pod (not swept up by the metrics deny)"
    kubectl -n "$NAMESPACE" delete pod netpol-ssh --ignore-not-found >/dev/null 2>&1
    kubectl -n "$NAMESPACE" run netpol-ssh --restart=Never --image=curlimages/curl --command -- \
        sh -c "curl -s -m 5 telnet://zocalo-sftp.$NAMESPACE.svc:22 2>&1 | head -c 20 || echo NO_BANNER" >/dev/null
    local result
    result="$(wait_for_pod_log netpol-ssh 15)"
    kubectl -n "$NAMESPACE" delete pod netpol-ssh --ignore-not-found >/dev/null 2>&1
    if echo "$result" | grep -q "SSH-2.0"; then
        test_pass
    else
        test_fail "expected SSH banner, got: $result"
    fi
}

test_probes_configured() {
    test_start "Liveness and readiness probes are distinct (not a single combined check)"
    local liveness readiness
    liveness="$(kubectl -n "$NAMESPACE" get pod zocalo-sftp-0 -o jsonpath='{.spec.containers[0].livenessProbe.exec.command}')"
    readiness="$(kubectl -n "$NAMESPACE" get pod zocalo-sftp-0 -o jsonpath='{.spec.containers[0].readinessProbe.exec.command}')"
    if [ -n "$liveness" ] && [ -n "$readiness" ] && [ "$liveness" != "$readiness" ]; then
        test_pass
    else
        test_fail "liveness=[$liveness] readiness=[$readiness]"
    fi
}

# Polls a Job-less one-shot pod's logs until it exits, then returns the log.
wait_for_pod_log() {
    local pod="$1" timeout="$2" ns="${3:-$NAMESPACE}"
    local waited=0
    while [ "$waited" -lt "$timeout" ]; do
        local phase
        phase="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
        if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
            kubectl -n "$ns" logs "$pod" 2>&1
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "TIMEOUT waiting for pod $pod"
}

cleanup() {
    stop_port_forward
    kubectl delete namespace "$NAMESPACE" monitoring --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "$SECRETS_DIR"
    teardown_kind_cluster "$CLUSTER_NAME"
}

main
