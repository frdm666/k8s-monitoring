# Kubernetes monitoring stack via Terraform

Deploys `kube-prometheus-stack` (Prometheus, Grafana, node-exporter,
kube-state-metrics, Prometheus Operator) into an existing Kubernetes cluster
using Terraform and the Helm provider.

Design rationale and known limitations live in [DECISIONS.md](DECISIONS.md).

## Environment

Two OpenStack VMs, Ubuntu 24.04, 2 vCPU / 4 GB RAM / 40 GB disk, and one (k8s-1) OpenStack VMs, Ubuntu 24.04, 4 vCPU / 8 GB RAM / 40 GB disk
private subnet `192.168.200.0/24`:

| Host  | Address          | Role                                          |
|-------|------------------|-----------------------------------------------|
| k8s-1 | 192.168.200.91   | Rancher (K3s on host + Rancher via Helm), management only |
| k8s-2 | 192.168.200.81   | etcd + control plane + worker                 |
| k8s-3 | 192.168.200.76   | worker                                        |

Target cluster: K3s v1.36.2, provisioned by Rancher as a Custom cluster.
Only `k8s-1` has a floating IP; the other two are reachable through it.

## What gets deployed

- **Prometheus Operator** — manages Prometheus through Kubernetes objects
  (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`)
- **Prometheus** — metric collection and storage
- **Grafana** — visualization, with the chart's bundled dashboards
- **node-exporter** — per-node OS metrics, deployed as a DaemonSet
- **kube-state-metrics** — metrics about Kubernetes objects: pod phases,
  deployment replicas, node conditions

## Repository layout

```
.
├── providers.tf              # terraform block, helm and kubernetes providers
├── main.tf                   # namespace + helm_release
├── variables.tf              # input variables
├── values/monitoring.yaml    # chart values, templated
├── .gitignore
├── README.md
└── DECISIONS.md
```

## Prerequisites

- Terraform >= 1.5 (tested on 1.15.8)
- A kubeconfig for the target cluster at `/root/.kube/lab-cluster.yaml`
  (path overridable via `kubeconfig_path`)
- Network access from the machine running Terraform to the cluster API

## Usage

Create `terraform.tfvars` (not committed — see `.gitignore`):

```hcl
chart_version          = "88.1.5"
grafana_admin_password = "<password>"
```

Then:

```
terraform init
terraform plan
terraform apply
```

To tear everything down:

```
terraform destroy
```

## Input variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `kubeconfig_path` | string | `/root/.kube/lab-cluster.yaml` | Path to the target cluster kubeconfig |
| `namespace` | string | `monitoring` | Namespace for the stack |
| `chart_version` | string | — | Pinned chart version, required |
| `grafana_admin_password` | string | — | Grafana admin password, required, sensitive |
| `grafana_node_port` | number | `30300` | NodePort exposing Grafana |

## Accessing Grafana

Cluster nodes have no floating IP and the NodePort range is only open inside
the subnet, so access goes through an SSH tunnel via `k8s-1`:

```
ssh -L 3000:192.168.200.81:30300 root@<k8s-1-floating-ip>
```

Then open `http://localhost:3000` and log in as `admin` with the password from
`terraform.tfvars`.

## Verifying the deployment

```
kubectl -n monitoring get pods
kubectl -n monitoring get svc
```

In Grafana, the relevant bundled dashboards are:

- **Kubernetes / Compute Resources / Cluster**
- **Kubernetes / Compute Resources / Namespace (Pods)**
- **Kubernetes / Compute Resources / Node (Pods)**
- **Node Exporter / Nodes**

To confirm there are no dead scrape targets, run this query in Explore:

```
up == 0
```

An empty result means every configured target is being scraped successfully.

Sample queries backed by kube-state-metrics:

```
kube_pod_status_phase
kube_deployment_status_replicas_available
kube_node_status_condition{condition="Ready"}
```
