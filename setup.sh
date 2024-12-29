#!/bin/bash

CILIUM_STABLE="v1.16.5"

kind create cluster --name=cluster1 --config=cluster-1.yaml

# Disable kube-proxy by removing iptables entries 
# pertinent to kube-proxy from all nodes 
for NODE in $(kubectl get no --no-headers | awk '{print $1;}'); do
    echo "Removing kube-proxy iptables rules from $NODE..."
    docker exec "$NODE" sh -c "iptables-save | grep -v KUBE | iptables-restore"
done

# kind create cluster --name=cluster2 --config=cluster-2.yaml

docker pull quay.io/cilium/cilium:$CILIUM_STABLE

kind load docker-image quay.io/cilium/cilium:$CILIUM_STABLE --name=cluster1
# kind load docker-image quay.io/cilium/cilium:$CILIUM_STABLE --name=cluster2

helm repo add cilium https://helm.cilium.io/

readonly GATEWAY_MANIFESTS_BASE_URL="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.0.0/config/crd"

# Install Gateway API
# Cilium supports Gateway API v1.0.0, even though GA is v1.2.0 now
kubectl apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f $GATEWAY_MANIFESTS_BASE_URL/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f $GATEWAY_MANIFESTS_BASE_URL/experimental/gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply -f $GATEWAY_MANIFESTS_BASE_URL/experimental/gateway.networking.k8s.io_tlsroutes.yaml

API_SERVER_IP="cluster1-control-plane"
API_SERVER_PORT="6443"

helm install cilium cilium/cilium \
    -n kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=${API_SERVER_IP} \
    --set k8sServicePort=${API_SERVER_PORT} \
    --set image.pullPolicy=IfNotPresent \
    --set ipam.mode=kubernetes \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set gatewayAPI.enabled=true \
    --set securityContext.privileged=true \
    --set envoy.securityContext.privileged=true \
    --set prometheus.enabled=true \
    --set ingressController.enabled=true \
    --set ingressController.default=true \
    --set operator.prometheus.enabled=true \
    --set hubble.metrics.enableOpenMetrics=true \
    --set ingressController.loadbalancerMode=dedicated \
    --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2:exemplars=true;labelsContext=source_ip\,source_namespace\,source_workload\,destination_ip\,destination_namespace\,destination_workload\,traffic_direction}" \
    --version "$CILIUM_STABLE" \
    --timeout 240s \
    --kube-context kind-cluster1

if ! command -v cilium; then
    CILIUM_CLI="v0.16.22"
    GOOS=$(go env GOOS)
    GOARCH=$(go env GOARCH)
    curl -L \
        --remote-name-all \
        https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI}/cilium-${GOOS}-${GOARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-${GOOS}-${GOARCH}.tar.gz.sha256sum
    sudo tar -C /usr/local/bin -xzvf cilium-${GOOS}-${GOARCH}.tar.gz
    rm cilium-${GOOS}-${GOARCH}.tar.gz{,.sha256sum}
fi

# cilium status kind-cluster2 --wait 300s

if ! command -v hubble; then
    HUBBLE="v1.16.5"
    curl -L \
        --fail --remote-name-all \
        https://github.com/cilium/hubble/releases/download/$HUBBLE/hubble-linux-amd64.tar.gz{,.sha256sum}
    sha256sum --check hubble-linux-amd64.tar.gz.sha256sum
    sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
    rm hubble-linux-amd64.tar.gz{,.sha256sum}
fi

# Installing Star Wars Demo
# kubectl create -f https://raw.githubusercontent.com/cilium/cilium/1.16.5/examples/minikube/http-sw-app.yaml

# Installing Prometheus + Grafana
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/1.16.5/examples/kubernetes/addons/prometheus/monitoring-example.yaml

echo ">>> Enabling hubble..."
# cilium hubble enable --context kind-cluster1
cilium hubble enable --ui --context kind-cluster1
cilium status kind-cluster1 --wait 300s

echo ">>> Accessing Hubble UI..."
# cilium hubble ui --context kind-cluster1

# Install bookinfo
# There should be 1 container for each Pod (no sidecar container)
kubectl -n default apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl -n default apply -f https://raw.githubusercontent.com/cilium/cilium/v1.15/examples/kubernetes/gateway/basic-http.yaml

# Install Dashboard
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm upgrade --install \
    kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    --create-namespace -n kubernetes-dashboard \
    --timeout 300s \
    --kube-context kind-cluster1
kubectl apply -f ./dashboard-admin.yaml

sleep 10

kubectl get secret admin-user -n kubernetes-dashboard -o jsonpath="{.data.token}" | base64 -d

# cilium hubble enable --context kind-cluster2

#  kubectl -n cilium-monitoring port-forward service/grafana --address 0.0.0.0 --address :: 3000:3000

# kubectl -n cilium-monitoring port-forward service/prometheus --address 0.0.0.0 --address :: 9090:9090

# hubble status kind-cluster1
