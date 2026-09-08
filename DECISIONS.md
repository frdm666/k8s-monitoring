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

## Object storage: MinIO

Both Loki and Thanos need S3-compatible storage. There is no cloud object
store available here, so MinIO runs inside the cluster and serves both.

**Standalone, not distributed.** The MinIO chart defaults to a 16-replica
distributed deployment requesting 16Gi of memory per pod. On 4Gi nodes
none of those pods ever schedule. `mode: standalone` with one replica and
explicit `resources` is the only thing that fits. This trades MinIO's own
redundancy away — acceptable for a lab, not for production.

**Pinned to k8s-3.** k8s-2 runs etcd, which is sensitive to disk write
latency (measured earlier with fio when debugging the Rancher `raft:
stopped` failure). An object store that grows continuously with logs and
metrics on the same disk risks degrading the control plane. k8s-3 is a
plain worker, so MinIO goes there.

## Loki: filesystem to S3

Loki previously stored chunks and index on a `local-path` PVC — a
directory on whichever node the pod happened to run on. A reschedule
meant losing log history.

Moving to `storage.type: s3` decouples data from the node. Two details
that are specific to MinIO rather than real S3:

- `s3ForcePathStyle: true` is required. Without it the client builds
  bucket-as-subdomain URLs (`loki.minio.minio.svc...`) the way AWS S3
  expects, and those do not resolve inside the cluster.
- `insecure: true` — MinIO is served over plain HTTP inside the cluster.
  Fine for pod-to-pod traffic here; a real deployment would terminate TLS.

The access key goes through `values_vars`, the secret key through
`sensitive_values`. Neither ends up in the repository.

## Thanos: long-term metric storage

Prometheus keeps 3 days of metrics on local disk with no PVC. Thanos moves
long-term storage off the pod entirely: the sidecar uploads completed
blocks to the `thanos` bucket, Store Gateway serves them back, and Query
merges live data from the sidecar with historical blocks so Grafana sees
one continuous history.

**Custom module instead of the Bitnami chart.** The Bitnami chart was the
first attempt. It installs cleanly, but every pod lands in
`ImagePullBackOff`: the chart references
`docker.io/bitnami/thanos:0.39.2-debian-12-r2`, and that tag no longer
exists — Bitnami removed most versioned tags from their public registry.
Pinning an older chart version would only postpone the same failure, since
the images themselves are gone.

The module in `modules/thanos/` uses `quay.io/thanos/thanos`, published by
the Thanos project itself. It is more code than a `values.yaml`, but it
does not depend on a third party's image policy.

**Constraints worth recording:**

- `disableCompaction: true` on Prometheus is mandatory once the Compactor
  runs. Two components compacting the same blocks corrupt them.
- The Compactor runs exactly one replica for the same reason. This is a
  hard constraint from Thanos, not a lab shortcut.
- `thanosService.enabled: true` is needed in `kube-prometheus-stack`. It is
  off by default, and without it the sidecar has no service to be
  discovered through — Query logs `no such host` forever while looking for
  `kube-prometheus-stack-thanos-discovery`.
- Store Gateway sits behind a headless service because Query finds it via
  SRV records (`dnssrv+`), which need per-pod addresses rather than one
  virtual IP.

**Retention and downsampling** are set on the Compactor: raw data 7 days,
5-minute resolution 30 days, 1-hour resolution 90 days. A year-long graph
does not need per-second points, and reading them would be needlessly
expensive.
## Alerting

Alertmanager is enabled and routes to a Telegram channel. Alert rules come
from two sources: the chart's defaults, and a small custom group defined via
`additionalPrometheusRulesMap`.

### Secret handling

The bot token lives in a Kubernetes Secret created by its own Terragrunt unit
from the `TELEGRAM_BOT_TOKEN` environment variable. Alertmanager mounts the
secret and reads the value with `bot_token_file`, so the token appears in no
values file, no plan output and no git history. The chat ID is injected into
the values template from `TELEGRAM_CHAT_ID` for the same reason — it is not
strictly a secret, but a private channel should not be exposed in the
repository.

### Watchdog and the dead man's switch

The chart ships a `Watchdog` alert that fires permanently by design. It is
routed to a null receiver rather than to Telegram, where it would be constant
noise.

Its purpose is inverted alerting: an external system should watch for the
signal and raise an alarm when it **stops** arriving. A monitoring stack that
has died looks exactly like a monitoring stack with nothing to report, and
this is the only way to tell the two apart. Forwarding Watchdog to an external
service is not configured here and remains a known gap.

### Noise reduction

Several measures, in order of how much they matter:

- Rule groups for components k3s does not run (etcd, scheduler,
  controller-manager, kube-proxy) are disabled at the source
- `CPUThrottlingHigh` is disabled: throttling is expected with the tight CPU
  limits used here
- `InfoInhibitor`, which exists only to suppress other alerts, goes to the
  null receiver
- An inhibit rule suppresses warnings for an instance that already has a
  critical alert
- `group_by` on alertname and severity, with a 45s `group_wait`, so a burst
  arrives as one message rather than a wall

### Custom rules and their `for` durations

The chart's defaults use `for` durations of 10-15 minutes. That is correct for
production — a brief blip should not page anyone — but makes verification
impractical. The custom `lab.rules` group uses 2-5 minutes instead. This is a
deliberate lab trade-off, not a recommendation.

### A false positive, and what it taught

`LabPodNotReady` initially fired for completed Helm install Jobs left over
from cluster provisioning. Formally they were "not ready"; in practice they
had finished successfully eight days earlier.

Fixed with `unless on(namespace, pod) kube_pod_status_phase{phase="Succeeded"} == 1`.

The general lesson: a rule that is technically correct can still be useless.
Readiness is meaningless for Jobs, and any rule over pod state needs to
exclude workloads that are supposed to terminate.

### Testing alerts is harder than writing them

Kubernetes actively resists being broken, which makes verification tricky:

- Scaling a Deployment to zero does **not** produce `up == 0`. The pod
  disappears, the endpoint disappears, and Prometheus drops the target
  entirely — the metric is absent, not zero.
- Replacing the image with a broken one does not help either: the rolling
  update keeps the healthy pod running until the new one becomes ready, so
  the endpoint stays valid.

What worked was letting the failing pod coexist with the healthy one, which
triggered the pod-level rules while `up` stayed at 1 for the service.

The takeaway is architectural: rules built on `up` detect "the service is
there but not responding". They do not detect "the service is gone". Those
need object-level metrics from kube-state-metrics, which is also why
kube-state-metrics cannot be the only thing you monitor with.
