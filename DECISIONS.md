# Design decisions

Why this deployment looks the way it does, and what it deliberately does not do.

## Terraform on top of Helm

Helm installs the chart, but it has no concept of desired versus actual state:
`helm upgrade` applies changes without showing what will differ beforehand.

Terraform keeps state, so `terraform plan` renders the diff before anything is
touched. It also manages the namespace and the release as a single unit with an
explicit dependency between them — the namespace is referenced as
`kubernetes_namespace.monitoring.metadata[0].name` rather than a hardcoded
string, so Terraform derives the creation order itself and reverses it on
destroy.

The wider reason is consistency: the same tool and the same language later cover
networks, VMs and security groups, instead of one tool per layer.

## Pinned chart version

`chart_version` has no default and must be supplied explicitly. An unpinned
chart means a later `apply` can silently pull a new major version with different
values schema and different resource requirements. The provider versions are
pinned for the same reason, and `.terraform.lock.hcl` is committed so that
`terraform init` resolves identically everywhere.

The Helm provider is constrained to `~> 2.17`: version 3.x changed the syntax of
the `kubernetes` block inside the provider configuration, and this code targets
the 2.x form.

## Disabled chart components

`kubeControllerManager`, `kubeScheduler`, `kubeEtcd` and `kubeProxy` are
disabled.

K3s packs the control plane into a single binary and does not expose these
components as separate metrics endpoints. Leaving the chart defaults in place
creates ServiceMonitors pointing at endpoints that do not exist, which shows up
as permanently DOWN targets in Prometheus and empty panels in the bundled
control-plane dashboards. Disabling them keeps `up == 0` empty, so a genuinely
broken target is immediately visible instead of being lost among known-broken
ones.

`alertmanager` is disabled as well. Alerting was not part of the task, and on
4 GB nodes its footprint (~200 Mi including its StatefulSet and config reloader)
is better spent on headroom. Re-enabling it is a one-line change in
`values/monitoring.yaml`.

## Retention and storage

```yaml
retention: 3d
retentionSize: 4GB
storageSpec: {}
```

No PersistentVolumeClaim is requested, so Prometheus writes to the pod's
ephemeral storage. **Metrics are lost whenever the pod is rescheduled or
restarted.**

This is an accepted trade-off for a lab: the cluster has no configured
StorageClass, and provisioning one on top of two nodes with local disks would
add a storage layer that is not what this task is about. Retention is kept short
to match — three days of data on ephemeral storage, with a size cap so a burst
of series cannot fill the node's disk.

Production would require a PVC backed by a real StorageClass, retention sized to
the actual query window, and either Thanos or remote write for anything longer.

## Resource requests and limits

Every component carries explicit `requests` and `limits`.

Requests are what the scheduler uses to decide placement; without them the
scheduler treats a pod as costing nothing and will happily overcommit a node.
Limits cap the damage a single component can do — a Prometheus that grows
unbounded on a 4 GB node would otherwise trigger the kernel OOM killer, which
may pick a different pod entirely.

Values were sized against observed usage rather than guessed: after deployment
`kubectl top nodes` reported roughly 63% memory on k8s-2 (which also carries the
control plane) and 48% on k8s-3. That leaves working room but not much, which is
also why Alertmanager stays off.

## Grafana exposure

Grafana is published as a `NodePort` on 30300. The cluster nodes have no
floating IPs, and the NodePort range in the security group is only open to
`192.168.200.0/24`, so the port is unreachable from outside the private network.

Access goes through an SSH tunnel via `k8s-1`, which is the only host with a
public address:

```
ssh -L 3000:192.168.200.81:30300 root@<k8s-1-floating-ip>
```

The alternatives were considered and rejected for this environment:

- **Opening the NodePort publicly** would place Grafana on the open internet
  behind nothing but a password.
- **An Ingress with TLS** is the production answer, but it needs a real domain
  and a certificate; the cluster currently has neither.

The tunnel grants access only to the person holding the SSH key, and only while
the session is open.

## Secrets

The Grafana admin password is passed through `set_sensitive` in the
`helm_release` resource rather than being written into `values/monitoring.yaml`.
As a result it appears in neither the values file nor Terraform's plan and apply
output.

It does still land in `terraform.tfstate` in plaintext — this is a documented
property of Terraform, not something the `sensitive` flag changes. Consequently
`*.tfstate`, `*.tfvars` and `.terraform/` are all gitignored, and the state file
never leaves the machine.

## Known limitations

- **Local Terraform state.** No remote backend, no locking, no encryption at
  rest. A single operator on a single machine makes this survivable; a team
  would need S3 with DynamoDB locking or an equivalent.
- **No persistent storage for Prometheus.** Metrics do not survive a pod
  restart.
- **No alerting.** Alertmanager is disabled; there are no PrometheusRule objects
  beyond the chart defaults.
- **Single etcd node in the target cluster.** k8s-2 carries etcd alone, so there
  is no quorum and no high availability — losing that node loses the cluster.
  Three etcd members would be the minimum for real redundancy.
- **Self-signed Rancher certificate.** Nodes were registered with `--insecure`
  for the install script download; the agent still validates the CA fingerprint
  via `--ca-checksum`, but a proper certificate would remove the flag entirely.
- **Kubeconfig is a Rancher-issued user token with a 30-day TTL.** For
  automation a dedicated ServiceAccount with a scoped role would be more
  appropriate than a personal credential that silently expires.
- **Secrets are not managed.** The password lives in a local tfvars file; a real
  setup would source it from Vault, SOPS or a cloud secret manager.
