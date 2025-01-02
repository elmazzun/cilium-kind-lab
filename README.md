# cilium-kind-lab

This repo creates a local [kind](https://kind.sigs.k8s.io/) cluster and uses [Cilium](https://cilium.io/) 
as its CNI.

I'm trying to use Cilium as much as possible to implement Service Mesh, Cluster 
Mesh, Gateway API, monitoring and observability

For now, this cluster holds no particular application besides [bookinfo](https://istio.io/latest/docs/examples/bookinfo/).

## The environment

The following tools are required in order to run the init script:

- `docker`  (will NOT be installed by script)
- `helm`    (will NOT be installed by script)
- `kind`    (will NOT be installed by script)
- `kubectl` (will NOT be installed by script)
- `cilium`  (will be installed by script)
- `hubble`  (will be installed by script)

Please note that kind cluster may fail to start because of low resources limits: 
check https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files.

My current `inotify` limits:

```bash
sysctl -a
...
fs.inotify.max_queued_events = 16384
fs.inotify.max_user_instances = 1280
fs.inotify.max_user_watches = 655360
...
```

Following my working environment where I developed this repo:

```bash
$ lsb_release -a
No LSB modules are available.
Distributor ID:	Linuxmint
Description:	Linux Mint 21
Release:	21
Codename:	vanessa

$ uname -r
6.8.0-40-generic

$ docker version -f json | jq '.Client.Version'
"27.4.1"

$ helm version --short
v3.12.0+gc9f554d

$ kind version
kind v0.26.0 go1.23.4 linux/amd64

$ kubectl version --client -o json | jq '.clientVersion.gitVersion'
"v1.29.0"

$ cilium version
cilium-cli: v0.16.22 compiled with go1.23.4 on linux/amd64
cilium image (default): v1.16.4
cilium image (stable): v1.16.5
cilium image (running): 1.16.5

$ hubble version
hubble v1.16.5@HEAD-6dbbd44 compiled with go1.23.4 on linux/amd64
```

## The cluster

The cluster is made of 1 control-plane node and 2 worker nodes.

In order to create the cluster, just run `./setup.sh`.

A basic UI is provided by [k8s dashboard](https://github.com/kubernetes/dashboard): in order to access it, 
you should `port-forward` its Kong Service and login by inserting the admin user access token, which is 
printed on screen at the end of init script.

```bash
$ ./setup.sh
...
Dashboard will be available at:
  https://localhost:8443
serviceaccount/admin-user created
clusterrolebinding.rbac.authorization.k8s.io/admin-user created
secret/admin-user created
eyJhbGciOiJSUz...7_A74l_uwclHkk-HE8zQ # <--- Copy this

# Port-forward and access the dashboard from https://localhost:8443/ after pasting the token above
$ kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443
Forwarding from 127.0.0.1:8443 -> 8443
Forwarding from [::1]:8443 -> 8443
```

## TODO

- [X] install k8s dashboard
- [X] install Hubble 
- [X] replace `kube-proxy` with Cilium
- [ ] enable Cilium Service Mesh
- [ ] expose Services by using Cilium Gateway API
- [ ] create more than one `kind` cluster and make them communicate via Cilium Cluster Mesh