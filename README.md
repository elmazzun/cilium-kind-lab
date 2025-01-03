# cilium-kind-lab

This repo creates two local [kind](https://kind.sigs.k8s.io/) clusters and uses [Cilium](https://cilium.io/) 
as their CNI.

I'm trying to use Cilium as much as possible to implement Service Mesh, Cluster 
Mesh, Gateway API, monitoring and observability

For now, these cluster hold no particular application.

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

## The clusters

Each cluster is made of 1 control-plane node and 2 worker nodes.

In order to create the clusters, just run `./setup.sh`.

```bash
$ ./setup.sh
```

## TODO

- [X] replace `kube-proxy` with Cilium
- [X] create more than one `kind` cluster and make them communicate via Cilium Cluster Mesh
- [ ] install k8s dashboard
- [ ] install Hubble 
- [ ] enable Cilium Service Mesh
- [ ] expose Services by using Cilium Gateway API