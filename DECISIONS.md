# Design decisions

Why this deployment looks the way it does, what went wrong along the way,
and what it deliberately does not do.

---

## Terraform, and Terragrunt on top of it

### Why Terraform rather than plain Helm

Helm installs charts but keeps no view of desired versus actual state:
`helm upgrade` applies changes and only then shows the result. Terraform keeps
state, so `plan` renders the diff before anything is touched.

It also manages heterogeneous things in one description — a namespace, a
release, and later networks or VMs — with an explicit dependency graph rather
than a documented order someone has to remember.

### Why Terragrunt on top of Terraform

The first iteration was a single Terraform root module with one state file
holding the namespace and one chart. That does not scale past a couple of
components:

- **One state for everything.** Any change re-evaluates the whole stack, and a
  failure in one component blocks the rest.
- **Duplication.** Each new root module needs its own copy of the provider
  block and backend configuration, and those copies drift.
- **Backend config cannot use variables.** Terraform evaluates the `backend`
  block before anything else, so the state path has to be hardcoded per module.

Terragrunt addresses all three. `root.hcl` generates `providers.tf` and the
backend block into every unit, so provider versions exist in exactly one place.
Each unit under `live/` gets its own state file, derived from its path. Units
reference each other with `dependency` blocks, and Terragrunt computes the run
order from them.

### Generic helm-release module

Rather than a `helm_release` resource per chart, there is one module taking
release name, repository, chart, version, values file and sensitive values.
Three charts are deployed from it with no duplicated resource code.

Sensitive values use a `dynamic "set_sensitive"` block driven by a map: for
Prometheus the map holds the Grafana password, for Loki and Alloy it is empty
and no block is generated at all.

### Migration from the single-state layout

Splitting one state into four meant either `terraform state mv` surgery or a
clean redeploy. The old stack was destroyed with the old code and recreated
under the new structure — the destroy/apply cycle had already been verified, so
this carried less risk than editing state by hand.

---

## Chart configuration

### Disabled kube-prometheus-stack components

`kubeControllerManager`, `kubeScheduler`, `kubeEtcd` and `kubeProxy` are
disabled. K3s packs the control plane into a single binary and exposes no
separate metrics endpoints for them; the chart defaults would create
ServiceMonitors pointing at addresses that do not exist.

The result would be permanently DOWN targets and empty control-plane
dashboards. That is worse than cosmetic: when some targets are always red, a
real failure hides among them. With these disabled, `up == 0` returns nothing,
so any single red target means an actual problem.

`alertmanager` is disabled to save roughly 200 Mi. Alerting was out of scope,
and on 4 GB nodes that memory is better kept as headroom. Re-enabling is a
one-line change.

### Loki in SingleBinary mode

The chart's default is `SimpleScalable`, which — per the chart's own
documentation — **requires object storage**. This cluster has none, so
SingleBinary with filesystem storage is the only workable mode.

Default caches (`chunksCache`, `resultsCache`) request several GB and were
disabled; `gateway`, `lokiCanary`, `minio` and the microservice replicas are
disabled for the same reason.

Retention is 72h, matching the short-lived nature of the lab.

### Loki needs a PVC — Prometheus does not

The first Loki deployment failed with:

```
mkdir /var/loki: read-only file system
error initialising module: ruler-storage
```

Loki's pod runs with a read-only root filesystem, which is a sensible hardening
default: all writes are expected to go to a mounted volume. With
`persistence.enabled: false` there was no writable location at all, and the
process died during module initialisation, before ever serving traffic.

Prometheus behaves differently: without a PVC its chart falls back to an
`emptyDir`, a volume that is temporary but does exist.

So the two components are configured differently on purpose:

- **Prometheus** — no PVC, metrics lost on pod restart, accepted trade-off
- **Loki** — 5 Gi PVC via the `local-path` StorageClass that K3s ships by
  default, so logs survive a restart

The lesson generalises: "just disable persistence" is not a portable
simplification. Whether it works depends on how the specific chart handles the
absence of a volume.

### Alloy reads logs through the Kubernetes API

Alloy runs as a DaemonSet — one pod per node, so new nodes are covered
automatically.

Log collection uses `loki.source.kubernetes`, which reads container logs
through the Kubernetes API, rather than mounting `/var/log` from the host. This
avoids hostPath mounts and the privileges they require, at the cost of some
load on the API server. Acceptable at this cluster size; a large cluster would
use file-based collection to keep that load off the control plane.

### Label cardinality

Only low-cardinality labels are attached: `namespace`, `pod`, `container`,
`node`, `app`. Loki indexes labels and stores content as compressed chunks, so
high-cardinality labels (pod UIDs, request IDs, trace IDs) inflate the index
and defeat the storage model. Content is searched with filter expressions
(`|= "error"`) instead.

### Grafana datasource declared in code

Loki is registered as a Grafana datasource through
`grafana.additionalDataSources` in the chart values, not by clicking through
the UI. Grafana has no persistence in this setup, so a UI-created datasource
would disappear on the next pod restart.

---

## Operational findings

### Rancher rewrites namespace annotations

After the namespace was created, every `apply` showed a diff removing
`cattle.io/status` and `lifecycle.cattle.io/create.namespace-auth`. Rancher's
controller adds these; Terraform considers them drift and strips them; Rancher
adds them back.

Fixed with `lifecycle { ignore_changes = [metadata[0].annotations] }` on the
namespace resource. This is the general shape of the problem whenever Terraform
and an in-cluster controller both own parts of the same object.

### An interrupted apply leaves orphans

Killing `terraform apply` mid-flight left the Helm release installed in the
cluster while Terraform's state had no record of it. The next apply failed
with `cannot re-use a name that is still in use`.

Diagnosis: `helm list -a` — the `-a` flag matters, as a failed release is
invisible without it. Resolution: `helm uninstall`, then apply again.

The rule that follows: do not interrupt an apply, and if it is interrupted,
reconcile real state against Terraform state before retrying.

### State locking

A suspended Terraform process (Ctrl+Z rather than Ctrl+C) held the state lock,
and subsequent runs refused to start. `terraform force-unlock <id>` clears it,
but only after confirming no live process is running — `ps aux | grep terraform`
showed the process in state `T`, suspended rather than dead.

With local state, locking is per-machine only. A team would need a remote
backend with shared locking.

### wait = true is deliberate

The `helm_release` resource sets `wait = true`, which is why apply blocks for
minutes. Without it Terraform would report success as soon as manifests were
accepted by the API server, and a crash-looping pod would only be discovered by
looking manually. The Loki failure above surfaced immediately because of this.

---

## Secrets

The Grafana admin password comes from the `GRAFANA_ADMIN_PASSWORD` environment
variable via `get_env`, and is passed to Helm through `set_sensitive`. It
therefore appears in no file in the repository, and in no plan or apply output.

It does still land in `terraform.tfstate` in plaintext — a documented property
of Terraform that the `sensitive` flag does not change. State, `.env` and
`.terraform/` are gitignored, and state never leaves the machine.

`.terraform.lock.hcl` **is** committed: it pins provider versions and their
checksums so `init` resolves identically everywhere.

Note also that Kubernetes Secrets are base64-encoded, not encrypted — anyone
with cluster API access can read them with a single command. Real secret
management (Vault, SOPS, a cloud secret manager) is out of scope here.

---

## Known limitations

- **Local Terraform state.** No remote backend, no shared locking, no
  encryption at rest.
- **No alerting.** Alertmanager is disabled; no PrometheusRule objects beyond
  chart defaults.
- **Prometheus has no persistent storage.** Metrics do not survive a pod
  restart.
- **Single etcd node in the target cluster.** k8s-2 carries etcd alone, so
  there is no quorum and no high availability. Three members would be the
  minimum for real redundancy.
- **Self-signed Rancher certificate.** Nodes were registered with `--insecure`
  for the install script download; the agent still validates the CA fingerprint
  via `--ca-checksum`.
- **Kubeconfig is a Rancher-issued user token with a 30-day TTL.** A dedicated
  ServiceAccount with a scoped role would be more appropriate for automation.
- **Grafana has no persistence.** Manually created dashboards are lost on
  restart; only chart-provided ones survive.
- **Helm does not remove CRDs on uninstall.** `destroy` leaves the
  `monitoring.coreos.com` CRDs behind. This is intentional on Helm's side —
  CRDs are cluster-scoped and deleting them would destroy every object of those
  kinds. It means `destroy` does not return the cluster to a clean state, and a
  chart upgrade changing CRD schemas needs them applied separately.
