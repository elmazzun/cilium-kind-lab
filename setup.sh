#!/bin/bash

CILIUM_STABLE="v1.16.5"
CILIUM_CLI="v0.16.22"
HUBBLE="v1.16.5"
CLUSTER_1_NAME="cluster1"
CLUSTER_1_CONTEXT="kind-$CLUSTER_1_NAME"
CLUSTER_2_NAME="cluster2"
CLUSTER_2_CONTEXT="kind-$CLUSTER_2_NAME"

function check_required_software() {
    if ! command -v docker; then
        echo "Please install docker."
        exit 1
    fi

    if ! command -v helm; then
        echo "Please install helm."
        exit 1
    fi

    if ! command -v kind; then
        echo "Please install kind."
        exit 1
    fi

    if ! command -v kubectl; then
        echo "Please install kubectl."
        exit 1
    fi
}

function create_cluster() {
    local -r CLUSTER_NAME="$1"
    local -r CLUSTER_CONFIG="$2"

    kind create cluster --name="$CLUSTER_NAME" --config="$CLUSTER_CONFIG"
}

# Disable kube-proxy by removing iptables entries 
# pertinent to kube-proxy from all nodes 
function delete_kube_proxy_from_iptables() {
    local -r CLUSTER_CONTEXT="$1"

    kubectl config use "$CLUSTER_CONTEXT"
    for NODE in $(kubectl get no --no-headers | awk '{print $1;}'); do
        echo "Removing kube-proxy iptables rules from $NODE..."
        docker exec "$NODE" sh -c "iptables-save | grep -v KUBE | iptables-restore"
    done
}

function install_gateway_api() {
    local -r GATEWAY_MANIFESTS_BASE_URL="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.0.0/config/crd"
    local -r CLUSTER_CONTEXT="$1"

    kubectl config use "$CLUSTER_CONTEXT"
    # Install Gateway API
    # Cilium supports Gateway API v1.0.0, even though GA is v1.2.0 now
    kubectl \
        apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_gatewayclasses.yaml
    kubectl \
        apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_gateways.yaml
    kubectl \
        apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_httproutes.yaml
    kubectl \
        apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_referencegrants.yaml
    kubectl \
        apply -f $GATEWAY_MANIFESTS_BASE_URL/experimental/gateway.networking.k8s.io_grpcroutes.yaml
    kubectl \
        apply -f $GATEWAY_MANIFESTS_BASE_URL/experimental/gateway.networking.k8s.io_tlsroutes.yaml
}

function install_cilium() {
    local -r CLUSTER_NAME="$1"
    local -r CLUSTER_CONTEXT="$2"
    local -r CLUSTER_ID="$3"
    local -r API_SERVER_IP="$CLUSTER_NAME-control-plane"
    local -r API_SERVER_PORT="6443"

    kind load docker-image quay.io/cilium/cilium:$CILIUM_STABLE --name="$CLUSTER_NAME"

    kubectl config use "$CLUSTER_CONTEXT" 

    helm install cilium cilium/cilium \
        -n kube-system \
        --set k8sServiceHost="${API_SERVER_IP}" \
        --set k8sServicePort="${API_SERVER_PORT}" \
        --set cluster.name="$CLUSTER_CONTEXT" \
        --set cluster.id="$CLUSTER_ID" \
        --version "$CILIUM_STABLE" \
        -f cilium-values.yaml \
        --timeout 240s

    cilium status "$CLUSTER_NAME" --wait 240s
}

function install_cilium_cli() {
    if ! command -v cilium; then
        local -r GOOS=$(go env GOOS)
        local -r GOARCH=$(go env GOARCH)
        curl -L \
            --remote-name-all \
            "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI}/cilium-${GOOS}-${GOARCH}.tar.gz{,.sha256sum}"
        sha256sum --check "cilium-${GOOS}-${GOARCH}.tar.gz.sha256sum"
        sudo tar -C /usr/local/bin -xzvf "cilium-${GOOS}-${GOARCH}.tar.gz"
        rm cilium-"${GOOS}"-"${GOARCH}".tar.gz{,.sha256sum}
    fi
}

function install_hubble_cli() {
    if ! command -v hubble; then
        curl -L \
            --fail --remote-name-all \
            https://github.com/cilium/hubble/releases/download/$HUBBLE/hubble-linux-amd64.tar.gz{,.sha256sum}
        sha256sum --check hubble-linux-amd64.tar.gz.sha256sum
        sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
        rm hubble-linux-amd64.tar.gz{,.sha256sum}
    fi
}

function create_cilium_cluster_mesh() {
    local -r CLUSTER_1_CONTEXT="$1"
    local -r CLUSTER_2_CONTEXT="$2"

    cilium clustermesh enable --context "$CLUSTER_1_CONTEXT" --service-type NodePort
    cilium clustermesh enable --context "$CLUSTER_2_CONTEXT" --service-type NodePort
    cilium clustermesh status --context "$CLUSTER_1_CONTEXT" --wait
    cilium clustermesh status --context "$CLUSTER_2_CONTEXT" --wait
    cilium clustermesh connect --context "$CLUSTER_1_CONTEXT" --destination-context "$CLUSTER_2_CONTEXT"
    cilium clustermesh status --context "$CLUSTER_1_CONTEXT" --wait
    cilium clustermesh status --context "$CLUSTER_2_CONTEXT" --wait
    # cilium connectivity test --context "$CLUSTER_1_CONTEXT" --multi-cluster "$CLUSTER_2_CONTEXT" -v --timeout 60s
}

check_required_software

create_cluster $CLUSTER_1_NAME $CLUSTER_1_NAME.yaml
create_cluster $CLUSTER_2_NAME $CLUSTER_2_NAME.yaml

delete_kube_proxy_from_iptables $CLUSTER_1_CONTEXT
delete_kube_proxy_from_iptables $CLUSTER_2_CONTEXT

# install_gateway_api $CLUSTER_1_CONTEXT
# install_gateway_api $CLUSTER_2_CONTEXT

docker pull quay.io/cilium/cilium:$CILIUM_STABLE
helm repo add cilium https://helm.cilium.io/

install_cilium_cli

install_hubble_cli

install_cilium $CLUSTER_1_NAME $CLUSTER_1_CONTEXT "1"
install_cilium $CLUSTER_2_NAME $CLUSTER_2_CONTEXT "2"

create_cilium_cluster_mesh $CLUSTER_1_CONTEXT $CLUSTER_2_CONTEXT

# TODO:
# - hubble
# - k8s dashboard
# - prometheus + grafana

# echo ">>> Enabling hubble..."
# cilium hubble enable --context kind-cluster1
# cilium hubble enable --ui --context kind-cluster1

# echo ">>> Accessing Hubble UI with:"
# echo ">>> cilium hubble ui"
# echo ">>> Accessing to Grafana with:"
# echo ">>> kubectl -n cilium-monitoring port-forward service/grafana --address 0.0.0.0 --address :: 3000:3000"

# Install bookinfo
# There should be 1 container for each Pod (no sidecar container)
# kubectl -n default apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/bookinfo/platform/kube/bookinfo.yaml
# kubectl -n default apply -f https://raw.githubusercontent.com/cilium/cilium/v1.15/examples/kubernetes/gateway/basic-http.yaml

# Install Dashboard
# helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
# helm upgrade --install \
#     kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
#     --create-namespace -n kubernetes-dashboard \
#     --timeout 180s \
#     --kube-context kind-cluster1
# kubectl apply -f ./dashboard-admin.yaml

# sleep 10

# kubectl get secret admin-user -n kubernetes-dashboard -o jsonpath="{.data.token}" | base64 -d

# cilium hubble enable --context kind-cluster2

#  kubectl -n cilium-monitoring port-forward service/grafana --address 0.0.0.0 --address :: 3000:3000

# kubectl -n cilium-monitoring port-forward service/prometheus --address 0.0.0.0 --address :: 9090:9090

# hubble status kind-cluster1
