#!/bin/bash

set -euo pipefail

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

    if ! command -v cloud-provider-kind; then
        echo "Please install cloud-provider-kind."
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

    docker pull "quay.io/cilium/cilium:v$CILIUM_STABLE"
    helm repo add cilium https://helm.cilium.io/
    helm repo update cilium

    kind load docker-image "quay.io/cilium/cilium:v$CILIUM_STABLE" \
        --name="$CLUSTER_NAME"

    # kubectl config use "$CLUSTER_CONTEXT" 

    # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#kubeproxy-free
    # Although "kubeadm init" (used by KinD) exports KUBERNETES_SERVICE_HOST 
    # and KUBERNETES_SERVICE_PORT as ClusterIP Service, there is not kube-proxy 
    # in my setup provisioning such service: therefore, Cilium agent needs to 
    # be made aware of this information by setting k8sServiceHost and 
    # k8sServicePort in the Helm chart.
    helm install cilium cilium/cilium \
        -n kube-system \
        --set k8sServiceHost="${API_SERVER_IP}" \
        --set k8sServicePort="${API_SERVER_PORT}" \
        --set cluster.name="$CLUSTER_CONTEXT" \
        --set cluster.id="$CLUSTER_ID" \
        --version "$CILIUM_STABLE" \
        -f cilium-values.yaml \
        --kube-context "$CLUSTER_CONTEXT" \
        --timeout 240s

    cilium status "$CLUSTER_NAME" --wait 240s

    echo "Checking if Cilium agent is actually replacing kube-proxy"
    kubectl -n kube-system -c cilium-agent exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
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

# https://docs.cilium.io/en/stable/observability/hubble/setup/#hubble-setup
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

# https://docs.cilium.io/en/latest/observability/metrics/
function install_cilium_monitoring() {
    kubectl apply \
        -f https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/kubernetes/addons/prometheus/monitoring-example.yaml
    kubectl wait \
        --for=condition=Ready pod -l app=prometheus -n cilium-monitoring \
        --timeout=180s
    kubectl wait \
        --for=condition=Ready pod -l app=grafana -n cilium-monitoring \
        --timeout=180s
    # kubectl -n cilium-monitoring port-forward service/grafana --address 0.0.0.0 --address :: 3000:3000
}

# https://docs.cilium.io/en/latest/network/servicemesh/istio/
function install_istio() {
    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update istio

    # Install basic CRDs and cluster roles required to set up Istio
    helm install istio-base istio/base \
        -n istio-system \
        --create-namespace \
        --wait

    # Install control plane component that manages and configures the 
    # proxies to route traffic within the mesh
    helm install istiod istio/istiod \
        -n istio-system \
        --set profile=ambient \
        --wait

    # Install Istio CNI node agent: it is responsible for detecting the pods 
    # that belong to the ambient mesh, and configuring the traffic redirection 
    # between pods and the ztunnel node proxy (which will be installed later)
    helm install istio-cni istio/cni \
        -n istio-system \
        --set profile=ambient \
        --wait

    # Install the node proxy component of Istio's ambient mode
    helm install ztunnel istio/ztunnel \
        -n istio-system \
        --wait

    # Kiali, Prometheus and Grafana
    kubectl apply \
        -n istio-system \
        -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/addons/kiali.yaml

    kubectl apply \
        -n istio-system \
        -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/addons/grafana.yaml

    kubectl apply \
        -n istio-system \
        -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/addons/prometheus.yaml
}

function install_dashboard() {
    local -r CLUSTER_CONTEXT="$1"

    helm repo add kubernetes-dashboard \
        https://kubernetes.github.io/dashboard/ || true
    helm upgrade \
        --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
        --kube-context "$CLUSTER_CONTEXT" \
        --create-namespace -n kubernetes-dashboard \
        --timeout 240s

    kubectl -n kubernetes-dashboard apply -f dashboard-admin.yaml
    sleep 3
    kubectl get secret admin-user -n kubernetes-dashboard \
        -o jsonpath="{.data.token}" | base64 -d
}

function deploy_demo_app() {
    local -r CLUSTER_CONTEXT="$1"

    kubectl config use "$CLUSTER_CONTEXT"
    kubectl create namespace bookinfo
    # kubectl label namespace bookinfo istio-injection=enabled
    kubectl label namespace bookinfo istio.io/dataplane-mode=ambient

    # demo app
    kubectl apply \
        -n bookinfo \
        -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/bookinfo/platform/kube/bookinfo.yaml
    # curl clients
    kubectl apply \
        -n bookinfo \
        -f https://raw.githubusercontent.com/linsun/sample-apps/main/sleep/sleep.yaml
    kubectl apply \
        -n bookinfo \
        -f https://raw.githubusercontent.com/linsun/sample-apps/main/sleep/notsleep.yaml
    # while true; do kubectl exec deploy/notsleep -- curl -s http://productpage:9080/ | head -n1; sleep 0.3; done
    # while true; do kubectl exec deploy/sleep -- curl -s http://productpage:9080/ | head -n1; sleep 0.3; done
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

CILIUM_STABLE="1.17.2"
CILIUM_CLI="v0.18.2"
HUBBLE="v1.16.5"
CLUSTER_1_NAME="cluster1"
CLUSTER_1_CONTEXT="kind-$CLUSTER_1_NAME"
CLUSTER_2_NAME="cluster2"
CLUSTER_2_CONTEXT="kind-$CLUSTER_2_NAME"

check_required_software

create_cluster "$CLUSTER_1_NAME" "$CLUSTER_1_NAME.yaml" || true
# create_cluster $CLUSTER_2_NAME $CLUSTER_2_NAME.yaml

delete_kube_proxy_from_iptables $CLUSTER_1_CONTEXT
# delete_kube_proxy_from_iptables $CLUSTER_2_CONTEXT

# install_gateway_api $CLUSTER_1_CONTEXT
# install_gateway_api $CLUSTER_2_CONTEXT

install_cilium_cli

install_hubble_cli

install_cilium "$CLUSTER_1_NAME" "$CLUSTER_1_CONTEXT" "1"
# install_cilium $CLUSTER_2_NAME $CLUSTER_2_CONTEXT "2"

install_cilium_monitoring # TODO: add context

install_istio # TODO: add context

install_dashboard "$CLUSTER_1_CONTEXT"

deploy_demo_app "$CLUSTER_1_CONTEXT"

# create_cilium_cluster_mesh $CLUSTER_1_CONTEXT $CLUSTER_2_CONTEXT

# cilium hubble enable --context kind-cluster2

#  kubectl -n cilium-monitoring port-forward service/grafana --address 0.0.0.0 --address :: 3000:3000

# kubectl -n cilium-monitoring port-forward service/prometheus --address 0.0.0.0 --address :: 9090:9090

# hubble status kind-cluster1
