# Kubernetes observability stack via Terragrunt

Deploys a full observability stack into an existing Kubernetes cluster,
described as code and managed with Terragrunt on top of Terraform:

- **kube-prometheus-stack** — Prometheus, Grafana, node-exporter,
  kube-state-metrics, Prometheus Operator
- **Loki** — log aggregation
- **Grafana Alloy** — log collection from every container in the cluster

Metrics and logs are both queryable from the same Grafana instance.

Design rationale and known limitations: [DECISIONS.md](DECISIONS.md).

## Environment

Three OpenStack VMs (Warsaw region), Ubuntu 24.04, 2 vCPU / 4 GB RAM / 40 GB disk,
private subnet `192.168.200.0/24`:

| Host  | Address        | Role                                                 |
|-------|----------------|------------------------------------------------------|
| k8s-1 | 192.168.200.91 | Rancher (K3s on host + Rancher via Helm), management |
| k8s-2 | 192.168.200.81 | etcd + control plane + worker                        |
| k8s-3 | 192.168.200.76 | worker                                               |

Target cluster: K3s v1.36.2, provisioned by Rancher as a Custom cluster.
Only `k8s-1` has a floating IP; the other two are reached through it.

Terragrunt runs on `k8s-1` and talks to the target cluster via kubeconfig.

## Repository layout

```
.
├── root.hcl                    shared config: backend + provider generation
├── templates/
│   └── providers.tf            provider block generated into every unit
├── modules/
│   ├── namespace/              creates the target namespace
│   └── helm-release/           generic module for any Helm chart
├── live/
│   ├── namespace/
│   ├── kube-prometheus-stack/
│   ├── loki/
│   └── alloy/
├── state/                      local state, one per unit
├── README.md
└── DECISIONS.md
```

Each directory under `live/` is a **unit**: its own state file, its own
lifecycle, wired to others through `dependency` blocks. Terragrunt derives
the apply order from those dependencies:

```
namespace
├── kube-prometheus-stack
└── loki
    └── alloy
```

## Prerequisites

- **Terragrunt 1.1.2 or later.** The CLI was redesigned in 1.0: `run-all`
  became `run --all`. Most guides online still use the old syntax.
- Terraform >= 1.5 (tested on 1.15.8)
- A kubeconfig for the target cluster at `/root/.kube/lab-cluster.yaml`

## Usage

The Grafana admin password is read from the environment, not from a file
in the repository:

```
cat > .env <<'EOF'
export GRAFANA_ADMIN_PASSWORD="<password>"
EOF
chmod 600 .env
```

Then:

```
source .env
cd live
terragrunt run --all plan
terragrunt run --all apply
```

To work on a single unit:

```
cd live/loki
terragrunt plan
terragrunt apply
```

To tear everything down:

```
cd live
terragrunt run --all destroy
```

## Chart versions

| Chart                 | Version | Notes                                 |
|-----------------------|---------|---------------------------------------|
| kube-prometheus-stack | 88.1.5  | metrics, Grafana, exporters           |
| loki                  | 7.2.0   | SingleBinary mode, filesystem storage |
| alloy                 | 1.11.1  | DaemonSet, log collection             |

Versions are pinned explicitly in each unit's `terragrunt.hcl`. Provider
versions are pinned in `templates/providers.tf` and locked per unit by
`.terraform.lock.hcl`.

## Accessing Grafana

Cluster nodes have no floating IP and the NodePort range is only reachable
from inside the subnet, so access goes through an SSH tunnel via `k8s-1`:

```
ssh -L 3000:192.168.200.81:30300 root@<k8s-1-floating-ip>
```

Open `http://localhost:3000`, log in as `admin` with the password from `.env`.

## Verifying the deployment

```
kubectl -n monitoring get pods
kubectl -n monitoring get svc
kubectl -n monitoring get pvc
```

Expected: Prometheus, Grafana, the operator, kube-state-metrics, two
node-exporter pods, one Loki pod with a bound PVC, and two Alloy pods
(one per node).

### Metrics

The chart's bundled dashboards cover the cluster:

- **Kubernetes / Compute Resources / Cluster**
- **Kubernetes / Compute Resources / Namespace (Pods)**
- **Node Exporter / Nodes**

To confirm no scrape target is broken, query `up == 0` in Explore. An empty
result means everything is being scraped.

Sample queries backed by kube-state-metrics:

```
kube_pod_status_phase
kube_deployment_status_replicas_available
kube_node_status_condition{condition="Ready"}
```

### Logs

In Explore, switch the datasource to **Loki**:

```
{namespace="monitoring"}
{namespace="kube-system"} |= "error"
{container="grafana"}
```

Labels available on every line: `namespace`, `pod`, `container`, `node`, `app`.
