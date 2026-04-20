#!/bin/bash
# Kubernetes test helpers for 09-kubernetes. Separate from
# ../lib/test-helpers.sh to avoid adding kind/kubectl deps to the library
# the Compose examples share.

CALICO_VERSION="v3.29.1"

#=============================================================================
# CLUSTER LIFECYCLE. Each run gets its own disposable kind cluster.
#=============================================================================
require_k8s_tools() {
    for tool in kind kubectl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "$tool is required but not installed."
            log_info "See this example's README.md for install instructions."
            exit 1
        fi
    done
}

# Guard against ever running destructive kubectl commands against a context
# this script didn't create itself.
assert_test_context() {
    local expected="$1"
    local current
    current="$(kubectl config current-context 2>/dev/null || true)"
    if [ "$current" != "kind-${expected}" ]; then
        log_error "kubectl context is '$current', expected 'kind-${expected}'"
        log_error "Refusing to proceed against an unexpected cluster."
        exit 1
    fi
}

create_kind_cluster() {
    local cluster_name="$1"

    if kind get clusters 2>/dev/null | grep -qx "$cluster_name"; then
        log_info "kind cluster '$cluster_name' already exists, reusing"
        kubectl config use-context "kind-${cluster_name}" >/dev/null
        return 0
    fi

    log_step "Creating kind cluster '$cluster_name' (default CNI disabled)"
    local kind_config
    kind_config="$(mktemp)"
    cat > "$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${cluster_name}
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
EOF
    kind create cluster --config "$kind_config" || {
        rm -f "$kind_config"
        log_error "Failed to create kind cluster"
        return 1
    }
    rm -f "$kind_config"

    install_calico "$cluster_name"
}

# kind's default CNI (kindnet) does not enforce NetworkPolicy. Calico does,
# and this example's whole point is proving a NetworkPolicy actually works.
# A cluster that can't enforce it would let a broken policy pass silently.
install_calico() {
    local cluster_name="$1"

    log_step "Installing Calico ${CALICO_VERSION} for NetworkPolicy enforcement"
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" >/dev/null

    # The CRDs this just created (Installation, APIServer, ...) need a moment
    # to become Established before the API server will accept instances of
    # them; creating one too early fails with "no matches for kind".
    kubectl wait --for condition=established --timeout=60s \
        crd/installations.operator.tigera.io crd/apiservers.operator.tigera.io

    local custom_resources
    custom_resources="$(mktemp)"
    cat > "$custom_resources" <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

    # calico-system is created BY the operator IN RESPONSE to seeing this
    # Installation resource. It must be applied before polling for the
    # namespace to appear, not after (that ordering just times out waiting
    # for a namespace nothing has asked the operator to create yet).
    kubectl create -f "$custom_resources" >/dev/null
    rm -f "$custom_resources"

    log_info "Waiting for the Tigera operator to create calico-system..."
    local waited=0
    while ! kubectl get ns calico-system >/dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge 60 ]; then
            log_error "calico-system namespace never appeared"
            return 1
        fi
    done

    log_info "Waiting for node to become Ready under Calico..."
    kubectl wait --for=condition=Ready node --all --timeout=180s || {
        log_error "Node never became Ready, Calico install likely failed"
        return 1
    }
    log_success "Calico is up, NetworkPolicy is enforced"
}

teardown_kind_cluster() {
    local cluster_name="$1"
    log_step "Deleting kind cluster '$cluster_name'"
    kind delete cluster --name "$cluster_name" >/dev/null 2>&1 || true
    log_success "Cluster deleted"
}

#=============================================================================
# IMAGE
#=============================================================================
# Sets (and exports) SFTP_IMAGE rather than returning the tag via stdout, since
# the log_* helpers below also print to stdout, so a caller capturing this
# function's output via $(...) would get log lines mixed into the value.
build_and_load_image() {
    local context_dir="$1"
    local default_tag="$2"
    local cluster_name="$3"

    if [ -n "${SFTP_IMAGE:-}" ]; then
        log_info "Using pre-built image: $SFTP_IMAGE (skipping build)"
    else
        log_step "Building Docker image"
        docker build -t "$default_tag" "$context_dir" || {
            log_error "Failed to build Docker image"
            return 1
        }
        export SFTP_IMAGE="$default_tag"
    fi

    log_step "Loading image into kind cluster"
    kind load docker-image "$SFTP_IMAGE" --name "$cluster_name" || {
        log_error "Failed to load image into kind"
        return 1
    }
}

#=============================================================================
# WORKLOAD READINESS
#=============================================================================
wait_for_statefulset_ready() {
    local namespace="$1"
    local name="$2"
    local timeout="${3:-120s}"

    log_info "Waiting for StatefulSet/$name to be ready..."
    kubectl -n "$namespace" wait --for=jsonpath='{.status.readyReplicas}'=1 \
        "statefulset/$name" --timeout="$timeout"
}
