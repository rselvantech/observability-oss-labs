# Demo 03: Exporters — Node Exporter, kube-state-metrics & Pushgateway

## Overview

Prometheus can only scrape what exposes a `/metrics` endpoint in OpenMetrics
text format. Exporters are the bridge between systems that do not natively
speak Prometheus and the Prometheus scrape model. They translate — taking
OS kernel data, Kubernetes API state, or application telemetry, and converting
it into the format Prometheus understands.

This demo covers the three most important exporters in the Kubernetes
observability stack, plus the pattern for building your own:

- **Node Exporter** — translates Linux kernel metrics from `/proc` and `/sys`
  into Prometheus format. Every Kubernetes node needs one.
- **kube-state-metrics** — translates Kubernetes API object state (deployments,
  pods, PVCs, quotas) into Prometheus format. The cluster needs one.
- **Pushgateway** — a metrics store for short-lived jobs that finish before
  Prometheus can scrape them. Used by batch jobs, CI pipelines, and Lambda-style
  ephemeral workloads.

**Real-world scenario:**
Your e-commerce platform runs on Kubernetes. The SRE team needs:
- Host-level CPU, memory, and disk metrics from every node to detect saturation
- Kubernetes object state metrics to know when deployments are unhealthy
- Metrics from nightly batch jobs (database backups, report generation) that
  complete in minutes — too fast for Prometheus to pull from directly

Each of these requires a different exporter. By the end of this demo you will
understand exactly which exporter covers which signal, how to configure each
one, and how to write your own simple exporter for a custom metric source.

**What this demo covers:**

- The exporter pattern — what an exporter is, why it exists, and how it works
- Node Exporter — collectors, host access requirements, key metric categories,
  important metrics, filtering, and production configuration
- kube-state-metrics — how it differs from Node Exporter, what it covers, its
  RBAC requirements, sharding for large clusters, and key metrics
- Pushgateway — the push model, when to use it, how it works, its pitfalls
  (stale metrics, grouping keys), and production best practices
- Custom exporters — the textfile collector pattern for simple cases without
  writing Go code
- Relabeling — how to drop metrics, rename labels, and filter targets at scrape time
- The four golden signals applied across all three exporters

---

## Prerequisites

**Demo 01 must be complete.** This demo uses the monitoring stack installed in
Demo 01 and the test-app from Demo 01.

**Verify the environment before starting:**

```bash
# All monitoring pods running
kubectl get pods -n monitoring

# kube-prometheus-stack installed
helm list -n monitoring

# Port-forward Prometheus
kubectl port-forward -n monitoring \
  svc/kube-prometheus-stack-prometheus 9090:9090 &
```

---

## Versions Used in This Demo

| Component | Version | Notes |
|---|---|---|
| kube-prometheus-stack Helm chart | **84.5.0** | from Demo 01 installation |
| Node Exporter | **1.11.1** | bundled via node-exporter chart 4.55.0 |
| kube-state-metrics | **2.18.0** | bundled via kube-state-metrics chart 7.3.0 |
| Pushgateway | **1.11.1** | deployed separately via Helm |
| prometheus-pushgateway Helm chart | **2.14.0** | prometheus-community/prometheus-pushgateway |
| podinfo (test-app) | **6.7.1** | from Demo 01 |

> **Note on Node Exporter version:** The latest standalone release is v1.10.2
> kube-prometheus-stack 84.5.0 bundles Node Exporter v1.11.1 via chart 4.55.0. When the
> Helm chart is upgraded to a newer version it will pull v1.10.x automatically.
> All concepts in this demo apply equally to all 1.x Node Exporter versions.

---

## Lab Objectives

By the end of this demo you will be able to:

1. ✅ Explain what an exporter is and why the pull model requires them
2. ✅ List Node Exporter's collector categories and what each covers
3. ✅ Explain why Node Exporter needs `hostPID`, `hostNetwork`, and host volume mounts
4. ✅ Write PromQL for CPU, memory, disk, and network saturation using Node Exporter metrics
5. ✅ Explain the difference between Node Exporter metrics and kube-state-metrics
6. ✅ Identify the key kube-state-metrics signals for deployment health and pod stability
7. ✅ Deploy and configure Pushgateway for batch job metrics
8. ✅ Push metrics to Pushgateway from a shell script and a Kubernetes Job
9. ✅ Explain the Pushgateway grouping key model and stale metric risk
10. ✅ Use the textfile collector to expose custom metrics without writing Go code
11. ✅ Apply metric relabeling to drop high-cardinality metrics at scrape time

---

## Directory Structure

```
03-exporters/
├── README.md                              ← this file
└── src/
    ├── node-exporter/
    │   └── node-exporter-values.yaml      ← standalone Node Exporter Helm values
    ├── kube-state-metrics/
    │   └── ksm-values.yaml                ← standalone kube-state-metrics Helm values
    ├── pushgateway/
    │   ├── pushgateway-values.yaml        ← Pushgateway Helm values
    │   ├── pushgateway-servicemonitor.yaml ← ServiceMonitor for Pushgateway
    │   └── batch-job.yaml                 ← sample Kubernetes Job that pushes metrics
    └── custom-app/
        ├── textfile-configmap.yaml        ← textfile collector ConfigMap
        └── custom-metrics-cronjob.yaml    ← CronJob writing custom textfile metrics
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           Minikube Node                                      │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     monitoring namespace                            │    │
│  │                                                                     │    │
│  │  ┌──────────────────────────────┐                                   │    │
│  │  │  Prometheus (StatefulSet)    │                                   │    │
│  │  │                              │  ① Scrapes all exporters          │    │
│  │  │  Pulls /metrics every 15s   │     via HTTP GET (pull model)     │    │
│  │  │  from all discovered targets │                                   │    │
│  │  └──────────────┬───────────────┘                                   │    │
│  │                 │                                                   │    │
│  │    ┌────────────┼────────────────────────────────────┐             │    │
│  │    │            │                                    │             │    │
│  │    ▼            ▼                                    ▼             │    │
│  │  ┌──────────┐ ┌─────────────────┐  ┌─────────────────────────┐    │    │
│  │  │   Node   │ │ kube-state-     │  │     Pushgateway          │    │    │
│  │  │ Exporter │ │ metrics         │  │     Port 9091            │    │    │
│  │  │(DaemonSet│ │ (Deployment)    │  │                          │    │    │
│  │  │Port 9100)│ │ Port 8080       │  │  ◄── Batch Job pushes   │    │    │
│  │  │          │ │                 │  │       metrics via HTTP   │    │    │
│  │  │ Reads:   │ │ Reads:          │  │  ◄── CronJob pushes     │    │    │
│  │  │ /proc    │ │ Kubernetes      │  │       textfile metrics   │    │    │
│  │  │ /sys     │ │ API server      │  │                          │    │    │
│  │  │          │ │ (kube objects)  │  │  Stores metrics in RAM   │    │    │
│  │  └──────────┘ └─────────────────┘  │  until Prometheus pulls  │    │    │
│  │  Host OS       K8s state           └─────────────────────────┘    │    │
│  │  metrics       metrics                                             │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌──────────────────────────────┐                                            │
│  │   Kubernetes Job (batch)     │ ② Push metrics → Pushgateway              │
│  │   Runs, completes, exits     │    POST /metrics/job/backup               │
│  └──────────────────────────────┘                                            │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

Signal sources:
  Node Exporter  → host OS signal: CPU time, memory pages, disk I/O, network bytes
  kube-state-metrics → K8s API signal: pod phase, replica counts, resource requests
  Pushgateway    → batch job signal: job duration, records processed, success/failure

All three feed into Prometheus → Grafana dashboard → SRE visibility
```

---

## Part 1: The Exporter Pattern — What and Why

### What Is an Exporter

An exporter is any process that:
1. Reads metrics from a source that does not natively speak Prometheus
2. Converts them to the OpenMetrics text format
3. Exposes them on a `/metrics` HTTP endpoint
4. Lets Prometheus pull them on its scrape interval

```
Without exporter — Prometheus cannot talk to these:
  Linux kernel (/proc, /sys)   → no HTTP endpoint, binary data format
  Kubernetes API server        → JSON REST API, wrong format
  MySQL database               → MySQL protocol, no /metrics
  Redis                        → Redis protocol, no /metrics
  HAProxy                      → stats socket, no /metrics

With exporter — Prometheus can now scrape:
  Linux kernel → Node Exporter → /metrics (OpenMetrics text) → Prometheus
  K8s API      → kube-state-metrics → /metrics               → Prometheus
  MySQL        → mysqld_exporter → /metrics                  → Prometheus
  Redis        → redis_exporter → /metrics                   → Prometheus
  HAProxy      → haproxy_exporter → /metrics                 → Prometheus
```

### Three Types of Exporters

```
Type 1: Sidecar exporter
  Runs alongside the monitored process in the same pod
  Reads metrics via localhost (Unix socket, HTTP, or shared memory)
  Example: mysqld_exporter sidecar reading MySQL performance_schema

Type 2: DaemonSet exporter
  Runs one pod per node with host-level access
  Reads from the host OS (/proc, /sys) not just the container
  Example: Node Exporter — must see the real host, not just the container view

Type 3: Singleton exporter
  Runs once per cluster, talks to an API
  Example: kube-state-metrics — one instance queries the Kubernetes API
           AWS CloudWatch exporter — one instance queries CloudWatch API

Type 4: Pushgateway (special case)
  Not a traditional exporter — it is a push receiver + pull proxy
  Batch jobs push to it; Prometheus pulls from it
  Covered in Part 4
```

### The Official Prometheus Exporter List

Prometheus maintains a curated list of exporters for hundreds of systems:

```
Official (prometheus-maintained):
  Node Exporter     → Linux/Unix host OS metrics
  Windows Exporter  → Windows host OS metrics (recommended replacement for WMI)
  Blackbox Exporter → HTTP/TCP/ICMP endpoint probing (Demo 19)
  Pushgateway       → Batch job push receiver (this demo)
  Alertmanager      → Self-monitoring

Community (widely-used, production-proven):
  mysqld_exporter       → MySQL and MariaDB
  postgres_exporter     → PostgreSQL
  redis_exporter        → Redis
  mongodb_exporter      → MongoDB
  elasticsearch_exporter → Elasticsearch / OpenSearch
  kafka_exporter        → Apache Kafka
  jmx_exporter          → JVM-based apps (Java, Scala, Kotlin)
  nginx-prometheus-exporter → NGINX
  haproxy_exporter      → HAProxy
  cloudwatch_exporter   → AWS CloudWatch metrics → Prometheus
  azure_metrics_exporter → Azure Monitor → Prometheus

Full list: https://prometheus.io/docs/instrumenting/exporters/
```

---

## Part 2: Node Exporter — Host OS Metrics Deep Dive

### What Node Exporter Is and How It Works

Node Exporter is a single Go binary that reads Linux kernel telemetry from
the `/proc` and `/sys` virtual filesystems and exposes it as Prometheus metrics.
It is deployed as a DaemonSet — one pod per Kubernetes node — so every node
in the cluster is covered automatically.

```
Node Exporter data flow:

  Linux kernel → /proc/stat           → node_cpu_seconds_total
  Linux kernel → /proc/meminfo        → node_memory_*
  Linux kernel → /proc/diskstats      → node_disk_*
  Linux kernel → /proc/net/dev        → node_network_*
  Linux kernel → /sys/class/hwmon     → node_hwmon_* (temperature, fans)
  Linux kernel → /proc/mounts         → node_filesystem_*
  Linux kernel → /proc/sys/fs         → node_filefd_* (open file descriptors)
  Linux kernel → /proc/loadavg        → node_load1, node_load5, node_load15
  Linux kernel → /proc/pressure       → node_pressure_* (PSI metrics)
  Systemd DBus → systemd units        → node_systemd_unit_state

Node Exporter reads these → formats as OpenMetrics text → serves on :9100/metrics
Prometheus scrapes :9100/metrics every 15 seconds
```

### Why Node Exporter Needs Special Host Access

Node Exporter must see the real host OS, not the container's view of it.
This requires special Kubernetes pod configuration:

```yaml
# From the kube-prometheus-stack DaemonSet spec (simplified)
spec:
  hostPID: true        # ← mount host /proc namespace
                       #   Without this: /proc shows only container processes
                       #   With this: /proc shows ALL host processes
                       #   Required for: process collector, interrupts collector

  hostNetwork: true    # ← use host network namespace
                       #   Without this: network metrics show only pod veth interface
                       #   With this: network metrics show real physical interfaces (eth0)
                       #   Required for: netdev collector, sockstat collector

  volumes:
    - name: proc
      hostPath:
        path: /proc    # ← mount real /proc from the host node
    - name: sys
      hostPath:
        path: /sys     # ← mount real /sys from the host node
    - name: root
      hostPath:
        path: /        # ← mount root filesystem (for filesystem collector)
```

```
Why these are safe despite looking privileged:

  hostPID: allows reading /proc/<pid>/status for any process
           does NOT allow killing, pausing, or signalling other processes
           does NOT allow attaching a debugger to other processes
           read-only visibility is all Node Exporter needs

  All volumes mounted read-only (ro flag on every hostPath volume)
           Node Exporter can read /proc but cannot write to it
           /proc is a virtual filesystem — writing to it would change kernel state
           The ro mount prevents this completely

  No capabilities required
           Node Exporter does not need CAP_SYS_ADMIN or any elevated capability
           It reads public kernel interfaces that any process can read
```

### Node Exporter Collector Categories

Node Exporter is modular — it has individual collectors per metric category.
All enabled collectors contribute to the `/metrics` output on every scrape.

```
ENABLED by default (no flags needed):
┌──────────────────────────────────────────────────────────────────────────────┐
│  Collector        Port   Source            Key metrics                       │
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  cpu              │       │ /proc/stat       │ node_cpu_seconds_total         │
│                   │       │                  │ (per mode: idle/user/system/  │
│                   │       │                  │  iowait/irq/softirq/steal)    │
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  meminfo          │       │ /proc/meminfo    │ node_memory_MemTotal_bytes     │
│                   │       │                  │ node_memory_MemAvailable_bytes │
│                   │       │                  │ node_memory_Cached_bytes       │
│                   │       │                  │ node_memory_SwapTotal_bytes    │
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  filesystem       │       │ /proc/mounts     │ node_filesystem_size_bytes     │
│                   │       │ + statfs()       │ node_filesystem_avail_bytes    │
│                   │       │                  │ node_filesystem_files_free     │
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  diskstats        │       │ /proc/diskstats  │ node_disk_read_bytes_total     │
│                   │       │                  │ node_disk_write_bytes_total    │
│                   │       │                  │ node_disk_io_time_seconds_total│
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  netdev           │       │ /proc/net/dev    │ node_network_receive_bytes_total│
│                   │       │                  │ node_network_transmit_bytes_t  │
│                   │       │                  │ node_network_receive_errs_total│
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  loadavg          │       │ /proc/loadavg    │ node_load1, node_load5         │
│                   │       │                  │ node_load15                    │
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  pressure         │       │ /proc/pressure/  │ node_pressure_cpu_waiting_secs │
│                   │       │ (PSI — Linux 4.20│ node_pressure_memory_waiting  │
│                   │       │  and newer)      │ node_pressure_io_waiting       │
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  uname            │       │ uname() syscall  │ node_uname_info (kernel version│
│                   │       │                  │ hostname, architecture)        │
├───────────────────┼───────┼──────────────────┼───────────────────────────────┤
│  textfile         │       │ /var/lib/node-   │ any metrics in .prom files     │
│                   │       │ exporter/textfile│ (covered in Part 5)           │
└───────────────────┴───────┴──────────────────┴───────────────────────────────┘

DISABLED by default (must enable explicitly):
  systemd   → node_systemd_unit_state (requires D-Bus socket mount)
  perf      → CPU performance counters (requires kernel config)
  hwmon     → hardware sensors: temperature, fan speed, voltage
  processes → node_processes_* (requires hostPID, high cardinality risk)
  tcpstat   → TCP connection state counts (requires hostNetwork)
  wifi      → wireless interface metrics
```

### The Most Important Node Exporter Metrics

```
CPU:
  node_cpu_seconds_total{cpu="0", mode="idle"}      ← counter, use rate()
  node_cpu_seconds_total{cpu="0", mode="user"}      ← user space CPU time
  node_cpu_seconds_total{cpu="0", mode="system"}    ← kernel CPU time
  node_cpu_seconds_total{cpu="0", mode="iowait"}    ← waiting for I/O
  node_cpu_seconds_total{cpu="0", mode="steal"}     ← stolen by hypervisor (VMs)

  ⚠️  There is one set of these series PER CPU core.
     On a 32-core node: 32 × 8 modes = 256 series just for CPU.
     Always use avg by (instance) to aggregate across cores.

Memory:
  node_memory_MemTotal_bytes      ← total physical RAM (gauge)
  node_memory_MemAvailable_bytes  ← available for allocation (gauge)
                                     NOT the same as MemFree
                                     MemAvailable includes reclaimable cache
                                     Use MemAvailable for memory pressure alerts
  node_memory_Cached_bytes        ← page cache (reclaimable)
  node_memory_Buffers_bytes       ← kernel I/O buffers (reclaimable)
  node_memory_SwapUsed_bytes      ← swap in use (computed: Total - Free)
                                     If > 0 sustained: memory pressure is real

Filesystem:
  node_filesystem_size_bytes{device="/dev/sda1", mountpoint="/"}
  node_filesystem_avail_bytes{device="/dev/sda1", mountpoint="/"}
  node_filesystem_files{mountpoint="/"}       ← total inodes
  node_filesystem_files_free{mountpoint="/"}  ← free inodes
  ⚠️  Always filter out tmpfs and overlay:
      {fstype!~"tmpfs|overlay|squashfs|devtmpfs"}
      These are virtual filesystems — alerting on them gives false positives

Disk I/O:
  node_disk_read_bytes_total{device="sda"}    ← counter
  node_disk_write_bytes_total{device="sda"}   ← counter
  node_disk_io_time_seconds_total{device="sda"} ← time spent doing I/O (counter)
  node_disk_reads_completed_total             ← IOPS (use rate())
  node_disk_read_time_seconds_total           ← read latency (use rate())

Network:
  node_network_receive_bytes_total{device="eth0"}    ← counter
  node_network_transmit_bytes_total{device="eth0"}   ← counter
  node_network_receive_errs_total{device="eth0"}     ← receive errors
  node_network_transmit_errs_total{device="eth0"}    ← transmit errors
  node_network_receive_drop_total{device="eth0"}     ← dropped packets (rx)
  ⚠️  Filter out virtual interfaces:
      {device!~"lo|docker.*|veth.*|br.*|cni.*|flannel.*|calico.*"}

Load:
  node_load1   ← 1-minute load average (gauge)
  node_load5   ← 5-minute load average (gauge)
  node_load15  ← 15-minute load average (gauge)
  ⚠️  Load average means different things on different CPU counts.
      On a 4-core node: load 4.0 = 100% saturation
      On a 32-core node: load 4.0 = 12.5% saturation
      Always normalise: node_load1 / count by (instance)(node_cpu_seconds_total{mode="idle"})
```

### Key Node Exporter PromQL Queries

```promql
# ── CPU ──────────────────────────────────────────────────────────────────────

# CPU busy % per node (aggregated across all cores)
100 - (
  avg by (instance) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  ) * 100
)

# CPU iowait % — high iowait = disk I/O bottleneck
avg by (instance) (
  rate(node_cpu_seconds_total{mode="iowait"}[5m])
) * 100

# CPU steal % — if > 5%: VM is CPU-starved by hypervisor (check cloud billing)
avg by (instance) (
  rate(node_cpu_seconds_total{mode="steal"}[5m])
) * 100

# Normalised load (load per CPU core — 1.0 = fully saturated)
node_load5
/
count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})

# ── Memory ───────────────────────────────────────────────────────────────────

# Memory used % (use MemAvailable — accounts for reclaimable cache)
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Swap usage % — any sustained swap usage is a memory pressure warning
(
  (node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes)
  / node_memory_SwapTotal_bytes
) * 100

# Predict memory exhaustion — hours until OOM at current rate
predict_linear(node_memory_MemAvailable_bytes[30m], 4 * 3600) < 0

# ── Disk ─────────────────────────────────────────────────────────────────────

# Disk used % per mountpoint (excluding virtual filesystems)
(
  1 - (
    node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|devtmpfs"}
    /
    node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|devtmpfs"}
  )
) * 100

# Disk I/O throughput in MB/s (read + write)
(
  rate(node_disk_read_bytes_total[5m]) +
  rate(node_disk_write_bytes_total[5m])
) / 1024 / 1024

# Disk I/O utilisation % (time the disk was busy — 100% = saturated)
rate(node_disk_io_time_seconds_total[5m]) * 100

# Predict disk full — predict remaining hours at current fill rate
(
  node_filesystem_avail_bytes{mountpoint="/"}
  /
  (-rate(node_filesystem_avail_bytes{mountpoint="/"}[1h]))
) / 3600

# ── Network ──────────────────────────────────────────────────────────────────

# Network receive throughput in MB/s per interface
rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*"}[5m]) / 1024 / 1024

# Network errors (should always be 0 — any nonzero is a hardware/driver issue)
rate(node_network_receive_errs_total[5m]) > 0

# Network dropped packets (packet drops = saturation or hardware problem)
rate(node_network_receive_drop_total{device!~"lo|veth.*|docker.*"}[5m]) > 0
```

### Verify Node Exporter Is Running and Scraping

```bash
# Check the DaemonSet is running on all nodes
kubectl get daemonset -n monitoring kube-prometheus-stack-prometheus-node-exporter

# Check pods are Running
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter

# Port-forward directly to Node Exporter for raw metric inspection
NODE_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus-node-exporter \
  -o jsonpath='{.items[0].metadata.name}')

kubectl port-forward -n monitoring pod/$NODE_POD 9100:9100 &
NEPF=$!
sleep 2

# Count total metrics exposed
curl -s http://localhost:9100/metrics | grep -v "^#" | wc -l

# View CPU metrics
curl -s http://localhost:9100/metrics | grep "^node_cpu_seconds_total"

# View memory metrics
curl -s http://localhost:9100/metrics | grep "^node_memory_"

# View filesystem metrics (first 20 lines)
curl -s http://localhost:9100/metrics | grep "^node_filesystem_avail" | head -20

kill $NEPF 2>/dev/null && wait $NEPF 2>/dev/null
```

**Expected output for metrics count:** 800–1200 metrics depending on collectors enabled and hardware.

Now verify Prometheus is scraping Node Exporter:

```bash
# Query in Prometheus UI (http://localhost:9090)
# Check Node Exporter target is UP
up{job="node-exporter"}

# Verify CPU metric is available
node_cpu_seconds_total{mode="idle"} | head -5

# Check when Node Exporter was last scraped
scrape_duration_seconds{job="node-exporter"}
```

### Node Exporter Metric Relabeling — Dropping High-Cardinality Metrics

Some Node Exporter metrics are noisy or high-cardinality and not needed
in most environments. You can drop them at scrape time using `metricRelabelings`
in the ServiceMonitor. This reduces TSDB size without disabling whole collectors.

Create `src/node-exporter/node-exporter-relabel.yaml`:

```yaml
# Add this to your values.yaml under nodeExporter section
# to drop metrics that are rarely used and add significant cardinality

nodeExporter:
  serviceMonitor:
    metricRelabelings:
      # Drop per-CPU individual metrics (we only need aggregated views)
      # These are kept in the default setup but can add 200+ series per node
      # Comment this out if you need per-CPU breakdown in dashboards
      # - sourceLabels: [__name__]
      #   regex: 'node_cpu_guest_seconds_total'
      #   action: drop

      # Drop filesystem metrics for virtual/container filesystems
      # These are always present but rarely useful for real disk monitoring
      - sourceLabels: [__name__, fstype]
        regex: 'node_filesystem_.+;(tmpfs|overlay|squashfs|devtmpfs|proc|sysfs|cgroup)'
        action: drop

      # Drop network metrics for virtual interfaces (Docker, CNI, loopback)
      - sourceLabels: [__name__, device]
        regex: 'node_network_.+;(lo|docker\d+|veth.+|br-.+|cni.+|flannel.+)'
        action: drop

      # Drop mdadm (software RAID) metrics if not using software RAID
      - sourceLabels: [__name__]
        regex: 'node_md_.+'
        action: drop
```

---

## Part 3: kube-state-metrics — Kubernetes Object State

### What kube-state-metrics Is and How It Differs from Node Exporter

This is the most important conceptual distinction for Kubernetes monitoring:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Node Exporter                    │  kube-state-metrics                     │
├───────────────────────────────────┼─────────────────────────────────────────┤
│  Measures: resource CONSUMPTION   │  Measures: object STATE                 │
│  "How much CPU is the node using?"│  "How many replicas does the deploy have?"│
│                                   │                                         │
│  Source: /proc and /sys           │  Source: Kubernetes API server          │
│          (OS kernel interfaces)   │          (kube-apiserver)               │
│                                   │                                         │
│  Deployment: DaemonSet            │  Deployment: single Deployment          │
│  (one pod per node)               │  (one instance per cluster)             │
│                                   │                                         │
│  Examples:                        │  Examples:                              │
│  node_cpu_seconds_total           │  kube_deployment_status_replicas        │
│  node_memory_MemAvailable_bytes   │  kube_pod_status_phase                  │
│  node_filesystem_avail_bytes      │  kube_pod_container_status_restarts_total│
│  node_network_receive_bytes_total │  kube_node_status_condition             │
│                                   │  kube_persistentvolumeclaim_status_phase│
│                                   │  kube_resourcequota_hard                │
└───────────────────────────────────┴─────────────────────────────────────────┘

You need BOTH for complete Kubernetes monitoring:
  Node Exporter → "the node is using 85% CPU"
  kube-state-metrics → "the payment-api deployment has 0 of 3 replicas available"
  Together → "the payment-api deployment is down AND the node it ran on is CPU-saturated"
```

### How kube-state-metrics Works

```
kube-state-metrics process:

  1. Connects to Kubernetes API server via in-cluster service account
  2. Establishes a long-lived Watch on every supported resource type
     (pods, deployments, statefulsets, nodes, PVCs, services, etc.)

  3. Kubernetes API sends Watch events as objects change:
     - ADDED:    new deployment created → new metrics appear
     - MODIFIED: deployment scaled → replica count metrics update
     - DELETED:  pod evicted → pod metrics disappear from /metrics

  4. kube-state-metrics maintains an in-memory cache of all K8s objects
  5. When Prometheus scrapes /metrics (port 8080):
     Generates current metrics from the in-memory cache
     Returns OpenMetrics text format

  This design means:
    kube-state-metrics metrics are eventually consistent with the K8s API
    Deleted objects: disappear from /metrics on next scrape → Prometheus sees no new data
    Created objects: appear in /metrics within the next scrape cycle (≤ 15s)
```

### kube-state-metrics RBAC Requirements

kube-state-metrics needs broad read access to the Kubernetes API.
This is intentional — it needs to see all objects to expose all metrics.

```
ClusterRole permissions (partial list):
  Pods:          list, watch
  Nodes:         list, watch
  Deployments:   list, watch
  ReplicaSets:   list, watch
  StatefulSets:  list, watch
  DaemonSets:    list, watch
  Services:      list, watch
  Endpoints:     list, watch
  PVCs:          list, watch
  PVs:           list, watch
  Namespaces:    list, watch
  ResourceQuotas: list, watch
  LimitRanges:   list, watch
  Jobs:          list, watch
  CronJobs:      list, watch
  ConfigMaps:    list, watch
  Secrets:       list, watch  ← metadata only — not data
  Ingresses:     list, watch
  HPA:           list, watch

NO write permissions on any resource.
Secrets: kube-state-metrics only reads metadata (name, namespace, labels)
         NOT the secret data — it cannot read your TLS certificates or passwords.
```

### The Most Important kube-state-metrics Metrics

```
Deployment health:
  kube_deployment_status_replicas_available{namespace="...", deployment="..."}
    ← how many replicas are currently available (ready to serve traffic)
    alert: kube_deployment_spec_replicas - kube_deployment_status_replicas_available > 0
    "The deployment has fewer available replicas than specified"

  kube_deployment_status_replicas_ready
    ← how many replicas have passed their readiness probe

  kube_deployment_status_observed_generation vs kube_deployment_metadata_generation
    ← if observed < metadata: a rollout is stuck (controller not processing it)

Pod health:
  kube_pod_status_phase{phase="Running"}   ← how many pods are Running
  kube_pod_status_phase{phase="Pending"}   ← how many pods are stuck Pending
  kube_pod_status_phase{phase="Failed"}    ← how many pods have Failed

  kube_pod_container_status_restarts_total ← restart counter (use increase over time)
    alert: increase(kube_pod_container_status_restarts_total[1h]) > 3
    "Container has restarted more than 3 times in the last hour"

  kube_pod_status_ready{condition="true"}  ← 1 if pod passed readiness probe
  kube_pod_status_ready{condition="false"} ← 1 if pod FAILED readiness probe

  kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}
    ← critical alert: pod in crash loop
  kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"}
    ← image not found or registry unavailable
  kube_pod_container_status_waiting_reason{reason="OOMKilled"}
    ← pod was killed for using too much memory

Node health:
  kube_node_status_condition{condition="Ready", status="true"}   ← 1 = node is Ready
  kube_node_status_condition{condition="Ready", status="false"}  ← 1 = node NotReady
  kube_node_status_condition{condition="MemoryPressure", status="true"} ← memory low
  kube_node_status_condition{condition="DiskPressure", status="true"}   ← disk low
  kube_node_info  ← labels: kernel version, container runtime, OS image

Resource requests vs limits vs allocatable:
  kube_pod_container_resource_requests{resource="cpu", unit="core"}
    ← CPU cores requested by this container (from requests: cpu: 100m)
  kube_pod_container_resource_limits{resource="memory", unit="byte"}
    ← memory limit for this container (from limits: memory: 256Mi)
  kube_node_status_allocatable{resource="cpu", unit="core"}
    ← total CPU available on the node for scheduling

  Capacity planning query:
    sum by (node) (kube_pod_container_resource_requests{resource="cpu"})
    /
    sum by (node) (kube_node_status_allocatable{resource="cpu"})
    → fraction of CPU allocated per node (> 0.8 = node almost full)

PVC status:
  kube_persistentvolumeclaim_status_phase{phase="Bound"}    ← PVC has storage
  kube_persistentvolumeclaim_status_phase{phase="Pending"}  ← waiting for storage
  kube_persistentvolumeclaim_status_phase{phase="Lost"}     ← storage was deleted

Resource quotas:
  kube_resourcequota_used{resource="pods"}
  kube_resourcequota_hard{resource="pods"}
    → fraction used = used / hard
    alert when > 0.9 (namespace is about to hit quota)
```

### Key kube-state-metrics PromQL Queries

```promql
# Pods not running by namespace
count by (namespace, phase) (
  kube_pod_status_phase{phase!="Running", phase!="Succeeded"}
)

# Deployments with unavailable replicas
(
  kube_deployment_spec_replicas
  -
  kube_deployment_status_replicas_available
) > 0

# Containers in CrashLoopBackOff
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1

# Container restart rate (restarts per hour per container)
rate(kube_pod_container_status_restarts_total[1h]) * 3600

# Node CPU allocation pressure (fraction of allocatable CPU requested)
sum by (node) (
  kube_pod_container_resource_requests{resource="cpu", unit="core"}
)
/
sum by (node) (
  kube_node_status_allocatable{resource="cpu", unit="core"}
)

# Nodes not Ready
kube_node_status_condition{condition="Ready", status="true"} == 0

# PVCs not Bound (waiting for storage or lost)
kube_persistentvolumeclaim_status_phase{phase!="Bound"} == 1

# Namespace quota usage above 80%
kube_resourcequota_used / kube_resourcequota_hard > 0.8
```

### Verify kube-state-metrics Is Running and Scraping

```bash
# Check the deployment
kubectl get deployment -n monitoring \
  kube-prometheus-stack-kube-state-metrics

# Port-forward for raw metric inspection
KSM_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=kube-state-metrics \
  -o jsonpath='{.items[0].metadata.name}')

kubectl port-forward -n monitoring pod/$KSM_POD 8080:8080 &
KSMPF=$!
sleep 2

# Count total metrics
curl -s http://localhost:8080/metrics | grep -v "^#" | wc -l

# View pod phase metrics for the test-app
curl -s http://localhost:8080/metrics | \
  grep 'kube_pod_status_phase{.*test-app.*}'

# View deployment replica metrics
curl -s http://localhost:8080/metrics | \
  grep 'kube_deployment_status_replicas_available{.*default.*}'

kill $KSMPF 2>/dev/null && wait $KSMPF 2>/dev/null
```

**Expected kube-state-metrics metrics count:** 2,000–8,000 metrics depending on cluster size.

---

## Part 4: Pushgateway — Metrics for Short-Lived Jobs

### The Problem Pushgateway Solves

The Prometheus pull model assumes targets are long-lived and reachable.
Batch jobs violate both assumptions:

```
Problem: Kubernetes Job lifecycle vs Prometheus scrape lifecycle

  Kubernetes Job starts     t=0s
  Job completes            t=45s  (faster than scrape interval)
  Job pod is deleted       t=75s  (gone before Prometheus could scrape it)
  Prometheus next scrape   t=120s (target no longer exists)

  Result: no metrics captured at all

  Alternative attempt — scrape during execution:
  Job starts               t=0s
  Prometheus scrape        t=15s  (gets partial results)
  Job completes            t=45s
  Prometheus scrape        t=30s  (may or may not complete in time)
  Job pod deleted          t=75s
  Prometheus scrape        t=75s  (connection refused — pod gone)

  Result: incomplete, inconsistent data
```

### How Pushgateway Works

```
Solution architecture:

  Kubernetes Job (ephemeral)
       │
       │  ① Job runs — completes its work
       │  ② At completion: pushes metrics to Pushgateway via HTTP PUT/POST
       │     curl -s --data-binary @- http://pushgateway:9091/metrics/job/backup
       │     (takes milliseconds — job can exit immediately after)
       ▼
  Pushgateway (long-lived Deployment)
       │     Stores metrics in memory
       │     Groups metrics by job + optional instance label
       │     Metrics persist until Prometheus scrapes them
       │     (or until explicitly deleted via DELETE request)
       │
       │  ③ Prometheus scrapes Pushgateway on regular 15s interval
       │     Gets all stored metric groups
       ▼
  Prometheus TSDB
       Stores the batch job metrics alongside all other metrics
       Now queryable: "did last night's backup succeed?"
```

### Installing Pushgateway

```bash
# Add chart repository (already added in Demo 01)
helm repo update

# Install Pushgateway
helm install pushgateway \
  prometheus-community/prometheus-pushgateway \
  --version 2.14.0 \
  --namespace monitoring \
  --values src/pushgateway/pushgateway-values.yaml \
  --wait
```

Create `src/pushgateway/pushgateway-values.yaml`:

```yaml
# src/pushgateway/pushgateway-values.yaml
# prometheus-pushgateway Helm chart values
# Chart: 2.14.0 | Pushgateway: 1.11.1

# Pushgateway does NOT persist metrics to disk by default.
# If the pod restarts, all pushed metrics are lost.
# For critical batch job metrics, use --persistence.file (see below).
persistence:
  enabled: false   # for this demo — enable in production

# Resource limits
resources:
  requests:
    cpu: 50m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 64Mi

# Service configuration
service:
  type: ClusterIP
  port: 9091        # Pushgateway listens on 9091 (not 9090 — Prometheus's port)

# ServiceMonitor for Prometheus to scrape Pushgateway
serviceMonitor:
  enabled: true     # creates a ServiceMonitor automatically
  namespace: monitoring
  interval: 15s
  # IMPORTANT: honor_labels = true is required for Pushgateway
  # Without it: Prometheus replaces the job label from pushed metrics
  # with the Pushgateway scrape job name — losing the original job context
  honorLabels: true

# Pushgateway stores metric groups indexed by a "grouping key"
# The grouping key is the combination of labels in the push URL path
# Default grouping key label: job
# Additional grouping key labels can be added in the push URL
```

Create `src/pushgateway/pushgateway-servicemonitor.yaml`:

```yaml
# src/pushgateway/pushgateway-servicemonitor.yaml
# Explicit ServiceMonitor for Pushgateway
# Only needed if serviceMonitor.enabled=false in Helm values
# If using serviceMonitor.enabled=true above, skip this file

apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: pushgateway
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus-pushgateway
  endpoints:
    - port: http
      interval: 15s
      # CRITICAL: honor_labels must be true for Pushgateway
      # Without it: Prometheus overwrites the 'job' label from pushed metrics
      # with "monitoring/pushgateway/0" — losing your batch job identity
      honorLabels: true
  namespaceSelector:
    matchNames:
      - monitoring
```

Verify Pushgateway is running:

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-pushgateway

# Expected:
# NAME                         READY   STATUS    RESTARTS   AGE
# pushgateway-xxxxx-yyyyy      1/1     Running   0          30s
```

### Understanding the Grouping Key Model

The grouping key is the most important concept to understand for Pushgateway.

```
Grouping key = the labels in the push URL path

Push URL format:
  http://pushgateway:9091/metrics/job/<job_name>/[<label_name>/<label_value>...]

Examples:
  /metrics/job/nightly-backup
    Grouping key: {job="nightly-backup"}

  /metrics/job/nightly-backup/instance/db-primary
    Grouping key: {job="nightly-backup", instance="db-primary"}

  /metrics/job/report-generator/environment/production/region/us-east-1
    Grouping key: {job="report-generator", environment="production", region="us-east-1"}

Why grouping keys matter:
  All metrics pushed with the SAME grouping key are stored as a GROUP.
  Pushing to the same grouping key REPLACES the entire previous group.
  This means the latest push always wins — no accumulation.

  Correct: each job run pushes to its own unique grouping key
    /metrics/job/backup/instance/db-primary → overwrites last backup run metrics ✅
    /metrics/job/backup/instance/db-replica → separate group for replica ✅

  Incorrect: multiple different jobs push to the same grouping key
    /metrics/job/batch → all batch jobs overwrite each other ❌
    Last one to push wins — earlier jobs' metrics disappear
```

### Pushing Metrics from a Shell Script

Port-forward to Pushgateway for testing:

```bash
kubectl port-forward -n monitoring svc/pushgateway-prometheus-pushgateway 9091:9091 &
PGPF=$!
sleep 2
```

**Push a single metric:**

```bash
cat <<EOF | curl -s --data-binary @- http://localhost:9091/metrics/job/demo-job
# HELP demo_test_metric A test metric pushed from shell
# TYPE demo_test_metric gauge
demo_test_metric{environment="dev"} 42
EOF
```

**Push multiple metrics for a simulated backup job:**

```bash
# Simulate a successful backup run
BACKUP_START=$(date +%s)
sleep 1  # simulate backup running for 1 second
BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

cat <<EOF | curl -s --data-binary @- \
  http://localhost:9091/metrics/job/nightly-backup/instance/db-primary
# HELP backup_last_success_timestamp_seconds Unix timestamp of last successful backup
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds $(date +%s)

# HELP backup_duration_seconds Duration of the last backup run in seconds
# TYPE backup_duration_seconds gauge
backup_duration_seconds{database="orders"} $BACKUP_DURATION

# HELP backup_rows_processed_total Total rows processed in last backup
# TYPE backup_rows_processed_total gauge
backup_rows_processed_total{database="orders"} 48291

# HELP backup_success Boolean: 1 if last backup succeeded, 0 if failed
# TYPE backup_success gauge
backup_success{database="orders"} 1
EOF

echo "Metrics pushed successfully"
```

**Verify the metrics are stored in Pushgateway:**

```bash
# View all stored metrics via the Pushgateway API
curl -s http://localhost:9091/metrics | grep "backup_"

# View the Pushgateway web UI to see all groups
# Open: http://localhost:9091
```

**Verify Prometheus is scraping the pushed metrics:**

Wait 15–30 seconds, then in Prometheus UI (http://localhost:9090):

```promql
# The backup metrics should now be queryable in Prometheus
backup_success{database="orders"}
backup_duration_seconds{database="orders"}
backup_last_success_timestamp_seconds
```

**Delete a metric group after the job is done:**

```bash
# DELETE request removes the entire group from Pushgateway
curl -s -X DELETE \
  http://localhost:9091/metrics/job/nightly-backup/instance/db-primary
echo "Metrics group deleted"
```

### Deploying a Real Kubernetes Job That Pushes Metrics

Create `src/pushgateway/batch-job.yaml`:

```yaml
# src/pushgateway/batch-job.yaml
#
# A realistic Kubernetes Job that:
#   1. Does some work (simulated here with sleep and a counter)
#   2. Pushes job completion metrics to Pushgateway
#   3. Deletes its own metric group when done (cleanup)
#
# In production: replace the "work" section with your actual batch task
# (database backup, report generation, data export, etc.)

apiVersion: batch/v1
kind: Job
metadata:
  name: demo-batch-job
  namespace: default
  labels:
    app: demo-batch-job
spec:
  # Job retries on failure (default: 6 — set to 1 for batch jobs that should not retry)
  backoffLimit: 1

  template:
    spec:
      restartPolicy: Never  # Job pods should not restart — failure is final

      containers:
        - name: batch-worker
          image: curlimages/curl:8.11.1    # lightweight container with curl
          command:
            - /bin/sh
            - -c
            - |
              #!/bin/sh
              set -e

              PUSHGATEWAY_URL="http://pushgateway-prometheus-pushgateway.monitoring:9091"
              JOB_NAME="demo-batch-job"
              INSTANCE="worker-$(hostname)"
              START_TIME=$(date +%s)

              echo "Starting batch job at $START_TIME"

              # ── Simulate work ─────────────────────────────────────────────
              # Replace this section with real work in production:
              # database backup, report generation, data export, etc.
              RECORDS_PROCESSED=0
              for i in $(seq 1 5); do
                echo "Processing batch $i of 5..."
                sleep 1
                RECORDS_PROCESSED=$((RECORDS_PROCESSED + 1000))
              done

              END_TIME=$(date +%s)
              DURATION=$((END_TIME - START_TIME))
              echo "Work completed: $RECORDS_PROCESSED records in ${DURATION}s"

              # ── Push completion metrics to Pushgateway ────────────────────
              # Use the job name and instance as the grouping key
              # This ensures each job run overwrites only its own previous metrics

              cat <<METRICS | curl -s --fail \
                --data-binary @- \
                "${PUSHGATEWAY_URL}/metrics/job/${JOB_NAME}/instance/${INSTANCE}"
              # HELP batch_job_last_success_timestamp Timestamp of last successful run
              # TYPE batch_job_last_success_timestamp gauge
              batch_job_last_success_timestamp{job_name="demo-batch-job"} $(date +%s)

              # HELP batch_job_duration_seconds Duration of the last batch run
              # TYPE batch_job_duration_seconds gauge
              batch_job_duration_seconds{job_name="demo-batch-job"} ${DURATION}

              # HELP batch_job_records_processed Total records processed
              # TYPE batch_job_records_processed gauge
              batch_job_records_processed{job_name="demo-batch-job"} ${RECORDS_PROCESSED}

              # HELP batch_job_success 1 if last run succeeded, 0 if failed
              # TYPE batch_job_success gauge
              batch_job_success{job_name="demo-batch-job"} 1
              METRICS

              echo "Metrics pushed to Pushgateway successfully"

              # ── Note on metric cleanup ────────────────────────────────────
              # In production, decide whether to delete metrics after push:
              #
              # Option A: Keep metrics (recommended)
              #   Prometheus will scrape and store them.
              #   They persist in Pushgateway until next job run overwrites them.
              #   Useful for: "when did the last backup run?" queries
              #
              # Option B: Delete immediately after Prometheus scrapes
              #   Use a CronJob that runs: curl -X DELETE .../job/demo-batch-job/...
              #   after a scrape interval (15s+) has passed.
              #   Prevents stale metrics if the job stops running entirely.

              echo "Job completed successfully"
```

Deploy and run the job:

```bash
kubectl apply -f src/pushgateway/batch-job.yaml

# Watch job progress
kubectl get jobs -n default -w

# Watch pod logs
kubectl logs -n default -l app=demo-batch-job -f
```

**Expected output:**
```
Starting batch job at 1735689600
Processing batch 1 of 5...
Processing batch 2 of 5...
Processing batch 3 of 5...
Processing batch 4 of 5...
Processing batch 5 of 5...
Work completed: 5000 records in 5s
Metrics pushed to Pushgateway successfully
Job completed successfully
```

Query the pushed metrics in Prometheus UI:

```promql
# Was the last batch job run successful?
batch_job_success{job_name="demo-batch-job"}

# How long did it take?
batch_job_duration_seconds{job_name="demo-batch-job"}

# How many records were processed?
batch_job_records_processed{job_name="demo-batch-job"}

# Time since last successful run (in minutes)
(time() - batch_job_last_success_timestamp{job_name="demo-batch-job"}) / 60
```

### Pushgateway Production Pitfalls

```
Pitfall 1: Stale metrics after job permanently stops running
  Scenario: A CronJob stops running (misconfigured schedule, deleted)
  Problem:  The last pushed metrics stay in Pushgateway forever
  Alert:    batch_job_success{job_name="backup"} == 0  ← never fires
  Alert:    time() - batch_job_last_success_timestamp > 25 * 3600  ← fires!
  Fix:      Alert on staleness:
            (time() - batch_job_last_success_timestamp) > (expected_interval * 1.5)

Pitfall 2: Using a single grouping key for multiple concurrent job instances
  Scenario: 5 parallel backup workers all push to /metrics/job/backup
  Problem:  Each push overwrites the previous — 4 out of 5 job results are lost
  Fix:      Include instance in grouping key:
            /metrics/job/backup/instance/worker-$(hostname)

Pitfall 3: Job failure leaves previous success metrics in place
  Scenario: Backup fails → nothing is pushed → Prometheus reads last success
  Alert:    batch_job_success == 1  ← still reads 1 from last successful run
  Fix:      Job MUST push metrics even on failure:
            trap 'push_failure_metrics' EXIT
            push_failure_metrics() { push batch_job_success=0 ... }

Pitfall 4: Pushgateway pod restart loses all stored metrics
  Problem:  Pushgateway stores metrics in RAM by default
  Fix:      Enable file-based persistence in production:
            extraArgs:
              - --persistence.file=/data/pushgateway.metrics
            persistence:
              enabled: true
              size: 1Gi

Pitfall 5: honor_labels=false in the ServiceMonitor
  Problem:  Prometheus overwrites the 'job' label from pushed metrics
            Your metric that says job="nightly-backup" becomes
            job="monitoring/pushgateway/0"
  Fix:      Always set honorLabels: true in the ServiceMonitor
```

---

## Part 5: The Textfile Collector — Custom Metrics Without Go Code

The textfile collector is Node Exporter's mechanism for exposing custom
metrics without writing an exporter from scratch. It reads `.prom` files
from a directory and includes them in the `/metrics` output.

### How It Works

```
1. Node Exporter starts with --collector.textfile.directory=/var/lib/node_exporter/textfile
2. On every scrape, Node Exporter reads all *.prom files in that directory
3. Parses each file as OpenMetrics text format
4. Includes the metrics in /metrics output alongside regular node metrics

You write the .prom files via:
  - Shell scripts run by CronJob
  - Python scripts
  - Any process that can write a text file

Use cases:
  - Custom hardware sensors not in Node Exporter
  - License expiry dates
  - SSL certificate expiry (alternative to Blackbox Exporter)
  - Disk capacity quotas from a custom storage system
  - Business metrics from a legacy system that cannot be instrumented
  - Kernel parameter settings (sysctl values)
```

### Setting Up the Textfile Collector via Node Exporter DaemonSet

The kube-prometheus-stack Node Exporter DaemonSet can be configured to
enable the textfile collector and mount a volume for the .prom files.

Add to `src/values.yaml` in the `nodeExporter` section:

```yaml
nodeExporter:
  enabled: true
  extraArgs:
    # Enable textfile collector pointing to a hostPath directory
    - --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

  extraVolumes:
    - name: textfile-dir
      hostPath:
        path: /var/lib/node_exporter/textfile_collector
        type: DirectoryOrCreate    # create the directory if it doesn't exist

  extraVolumeMounts:
    - name: textfile-dir
      mountPath: /var/lib/node_exporter/textfile_collector
      readOnly: false              # Node Exporter needs to READ these files
                                   # Scripts on the host write to this directory
```

### Writing a Custom Metric Script

Create `src/custom-app/custom-metrics-cronjob.yaml`:

```yaml
# src/custom-app/custom-metrics-cronjob.yaml
#
# A CronJob that writes custom metrics to the Node Exporter textfile directory.
# Node Exporter picks them up automatically on the next scrape.
#
# This example monitors:
#   - Number of running Docker containers
#   - A simulated license expiry countdown
#   - Current server time (for demo purposes)

apiVersion: batch/v1
kind: CronJob
metadata:
  name: custom-metrics-writer
  namespace: monitoring
spec:
  # Run every 60 seconds
  # Note: CronJob minimum is 1 minute — for sub-minute updates use a Deployment loop
  schedule: "* * * * *"

  concurrencyPolicy: Replace   # replace running job if previous hasn't finished
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3

  jobTemplate:
    spec:
      template:
        spec:
          # Must run on the host — writes to host filesystem
          hostPID: false
          restartPolicy: OnFailure

          containers:
            - name: metrics-writer
              image: ubuntu:24.04
              command:
                - /bin/bash
                - -c
                - |
                  #!/bin/bash
                  set -e

                  TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
                  TMP_FILE="${TEXTFILE_DIR}/custom_metrics.prom.tmp"
                  FINAL_FILE="${TEXTFILE_DIR}/custom_metrics.prom"

                  # Write to a temp file first — prevents partial reads by Node Exporter
                  # Atomic write: mv is atomic on most filesystems
                  cat > "$TMP_FILE" << 'METRICS'
                  # HELP custom_demo_timestamp_seconds Current Unix timestamp (demo metric)
                  # TYPE custom_demo_timestamp_seconds gauge
                  METRICS

                  echo "custom_demo_timestamp_seconds $(date +%s)" >> "$TMP_FILE"

                  cat >> "$TMP_FILE" << 'METRICS'
                  # HELP custom_license_expiry_days Days until software license expires
                  # TYPE custom_license_expiry_days gauge
                  METRICS

                  # Simulate: license expires in 45 days from now
                  EXPIRY_DAYS=45
                  echo "custom_license_expiry_days{product=\"enterprise-monitoring\"} $EXPIRY_DAYS" >> "$TMP_FILE"

                  cat >> "$TMP_FILE" << 'METRICS'
                  # HELP custom_backup_file_count Number of backup files on disk
                  # TYPE custom_backup_file_count gauge
                  METRICS

                  # Simulate: 12 backup files
                  echo "custom_backup_file_count{backup_type=\"daily\",path=\"/backups\"} 12" >> "$TMP_FILE"

                  # Atomic move — prevents Node Exporter reading a partial file
                  mv "$TMP_FILE" "$FINAL_FILE"

                  echo "Custom metrics written to $FINAL_FILE"

              volumeMounts:
                - name: textfile-dir
                  mountPath: /var/lib/node_exporter/textfile_collector

          volumes:
            - name: textfile-dir
              hostPath:
                path: /var/lib/node_exporter/textfile_collector
                type: DirectoryOrCreate
```

After applying this CronJob, the custom metrics appear in Node Exporter's
output within 60 seconds and are scraped by Prometheus on its next cycle.

Query the custom metrics in Prometheus UI:

```promql
# License expiry alert: if < 30 days, alert
custom_license_expiry_days{product="enterprise-monitoring"} < 30

# How many backup files exist?
custom_backup_file_count{backup_type="daily"}
```

---

## Step-by-Step Lab

### Step 1: Verify Node Exporter and kube-state-metrics Are Healthy

```bash
# Both are already installed by kube-prometheus-stack from Demo 01

# Verify targets in Prometheus UI
# http://localhost:9090/targets
# Look for:
#   monitoring/kube-prometheus-stack-node-exporter/0    (1/1 up)
#   monitoring/kube-prometheus-stack-kube-state-metrics/0 (1/1 up)

# Run the four golden signals queries for host infrastructure
# Open Prometheus UI → Graph tab → run these:
```

**Four golden signals using Node Exporter:**

```promql
# Latency — disk I/O latency (saturation indicator)
rate(node_disk_read_time_seconds_total[5m])
/
rate(node_disk_reads_completed_total[5m])

# Traffic — network throughput (bytes/sec in+out)
rate(node_network_receive_bytes_total{device!~"lo|veth.*"}[5m]) +
rate(node_network_transmit_bytes_total{device!~"lo|veth.*"}[5m])

# Errors — network receive errors
rate(node_network_receive_errs_total{device!~"lo|veth.*"}[5m])

# Saturation — CPU busy %
100 - (avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

### Step 2: Install Pushgateway

```bash
helm install pushgateway \
  prometheus-community/prometheus-pushgateway \
  --version 2.14.0 \
  --namespace monitoring \
  --values src/pushgateway/pushgateway-values.yaml \
  --wait

kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-pushgateway
```

### Step 3: Push Test Metrics and Verify

```bash
# Port-forward to Pushgateway
kubectl port-forward -n monitoring \
  svc/pushgateway-prometheus-pushgateway 9091:9091 &
PGPF=$!
sleep 2

# Push backup job metrics
cat <<'EOF' | curl -s --data-binary @- \
  http://localhost:9091/metrics/job/nightly-backup/instance/db-primary
# HELP backup_last_success_timestamp_seconds Unix timestamp of last successful backup
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds 1735689600

# HELP backup_duration_seconds Duration of backup run in seconds
# TYPE backup_duration_seconds gauge
backup_duration_seconds{database="orders"} 127

# HELP backup_success 1 if last backup succeeded, 0 if failed
# TYPE backup_success gauge
backup_success{database="orders"} 1
EOF

# View Pushgateway metrics API
curl -s http://localhost:9091/api/v1/metrics | python3 -m json.tool | head -40

# Stop port-forward
kill $PGPF 2>/dev/null && wait $PGPF 2>/dev/null
```

Wait 15 seconds, then query in Prometheus UI:

```promql
backup_success{database="orders"}
# Expected: 1
```

### Step 4: Run the Kubernetes Batch Job

```bash
kubectl apply -f src/pushgateway/batch-job.yaml

# Watch job until completion
kubectl get jobs -n default demo-batch-job -w

# View logs
kubectl logs -n default \
  -l app=demo-batch-job \
  --tail=20

# After job completes, query metrics in Prometheus UI:
# batch_job_success{job_name="demo-batch-job"}
# batch_job_duration_seconds{job_name="demo-batch-job"}
```

### Step 5: Explore Alerting Opportunities

Generate some concerning conditions to see how the metrics respond:

```bash
# Scale the test-app down to 0 replicas — watch kube-state-metrics respond
kubectl scale deployment test-app --replicas=0

# In Prometheus UI, run:
# kube_deployment_status_replicas_available{deployment="test-app"}
# Expected: 0

# kube_pod_status_phase{namespace="default"}
# Expected: no Running pods for test-app

# Scale back up
kubectl scale deployment test-app --replicas=3
kubectl rollout status deployment/test-app
```

---

## Lessons Learned

### Node Exporter: MemAvailable Not MemFree

```
WRONG alert: node_memory_MemFree_bytes / node_memory_MemTotal_bytes < 0.1
  MemFree = memory not used by anything at all (including cache)
  On a healthy busy system, MemFree is often near zero — cache fills RAM
  This alert fires constantly on healthy systems → alert fatigue

CORRECT alert:
  node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1
  MemAvailable = memory actually available for new allocations
  Includes: MemFree + reclaimable page cache + reclaimable slab memory
  Only goes low when real memory pressure exists
  The kernel reports this directly — it is the authoritative number
```

### kube-state-metrics: Deleted Objects Disappear Immediately

```
Scenario: You are graphing kube_pod_status_restarts_total for a pod.
          The pod is deleted and recreated (rolling update or crash).

What happens: The old pod's metrics disappear from /metrics immediately.
              The new pod has a new unique name → new metric series.
              The old series: Prometheus sees no new data → staleness marker
              The new series: starts at 0 restarts.

Impact on alerts:
  Alert: increase(kube_pod_container_status_restarts_total[1h]) > 5
  When a pod is replaced: the counter resets to 0 on the new pod.
  A pod that crashed 4 times and was replaced might show 0 in the new series.

  Better alert: sum by (namespace, pod)(rate(kube_pod_container_status_restarts_total[15m])) > 0
  Or: watch for the waiting_reason metric which fires immediately:
      kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1
```

### Pushgateway: honor_labels Is Not Optional

```
Without honorLabels: true in the ServiceMonitor:
  You push: backup_success{job="nightly-backup", database="orders"} 1
  Prometheus scrapes Pushgateway with job="monitoring/pushgateway/0"
  Prometheus relabels: job → exported_job (renames pushed label)
                       job = "monitoring/pushgateway/0" (Prometheus scrape job)

  Your alert: backup_success{job="nightly-backup"} → never matches
  Your dashboard query: backup_success{job="nightly-backup"} → empty

With honorLabels: true:
  Prometheus respects the labels from the pushed metrics
  backup_success{job="nightly-backup", database="orders"} → correct
  Your alerts and dashboard queries work as expected
```

### Textfile Collector: Always Write Atomically

```
WRONG — Prometheus may scrape a partial file:
  echo "# TYPE my_metric gauge" > /textfile/my_metrics.prom
  sleep 5  # simulating slow metric collection
  echo "my_metric 42" >> /textfile/my_metrics.prom

CORRECT — write to temp file then atomically move:
  TMPFILE=$(mktemp /textfile/my_metrics.XXXXXX.prom)
  echo "# TYPE my_metric gauge" > $TMPFILE
  # ... all your metric generation ...
  echo "my_metric 42" >> $TMPFILE
  mv $TMPFILE /textfile/my_metrics.prom  # atomic on local filesystems

Why: mv is a single filesystem operation — it either succeeds completely
     or fails completely. Node Exporter never sees a half-written file.
     Direct writes with >> leave a window where the file has partial content.
```

---

## Quick Reference — Commands

| What | Command |
|---|---|
| List all exporters as Prometheus targets | `http://localhost:9090/targets` |
| View Node Exporter raw metrics | `kubectl port-forward -n monitoring pod/$NODE_POD 9100:9100` → `curl localhost:9100/metrics` |
| View kube-state-metrics raw metrics | `kubectl port-forward -n monitoring pod/$KSM_POD 8080:8080` → `curl localhost:8080/metrics` |
| View Pushgateway stored groups | `curl http://localhost:9091/api/v1/metrics` |
| Push metrics to Pushgateway | `cat metrics.prom \| curl --data-binary @- http://localhost:9091/metrics/job/myjob` |
| Delete Pushgateway metric group | `curl -X DELETE http://localhost:9091/metrics/job/myjob/instance/myinstance` |
| Run batch job | `kubectl apply -f src/pushgateway/batch-job.yaml` |
| Check job status | `kubectl get jobs -n default` |
| Scale down test-app (test KSM) | `kubectl scale deployment test-app --replicas=0` |

---

## Cleanup — Complete Teardown

```bash
# Step 1: Remove batch job
kubectl delete -f src/pushgateway/batch-job.yaml --ignore-not-found
kubectl delete job demo-batch-job -n default --ignore-not-found

# Step 2: Remove custom metrics CronJob
kubectl delete -f src/custom-app/custom-metrics-cronjob.yaml --ignore-not-found

# Step 3: Uninstall Pushgateway
helm uninstall pushgateway -n monitoring
kubectl delete pvc -n monitoring -l app.kubernetes.io/name=prometheus-pushgateway \
  --ignore-not-found

# Step 4: Stop any running port-forwards
pkill -f "kubectl port-forward" 2>/dev/null || true

# Step 5: Restore test-app replicas if scaled down
kubectl scale deployment test-app --replicas=3 2>/dev/null || true

# Step 6: Verify cleanup
kubectl get pods -n monitoring
kubectl get jobs -n default

# Step 7: If tearing down the full stack from Demo 01
# helm uninstall kube-prometheus-stack -n monitoring
# kubectl delete pvc -n monitoring --all
# kubectl delete namespace monitoring
# kubectl delete -f ../01-prometheus-fundamentals/src/test-app/ --ignore-not-found

# Step 8: Stop Minikube
minikube stop
```

---

## What's Next

**Demo 04 — Grafana Dashboards, Panels, Variables, and Provisioning**

With Prometheus collecting metrics from the stack (Demo 01), application
services (Demo 02 recording rules), Node Exporter (this demo), and
kube-state-metrics (this demo), Demo 04 builds real Grafana dashboards
from all these signals. You will learn panel types, dashboard variables
for dynamic filtering, template queries, dashboard provisioning via
ConfigMaps, and how to import and customise community dashboards.

---

## References

| Resource | URL |
|---|---|
| Node Exporter documentation | https://prometheus.io/docs/guides/node-exporter/ |
| Node Exporter collectors list | https://github.com/prometheus/node_exporter#collectors |
| Node Exporter releases | https://github.com/prometheus/node_exporter/releases |
| kube-state-metrics metrics list | https://github.com/kubernetes/kube-state-metrics/tree/main/docs/metrics |
| kube-state-metrics GitHub | https://github.com/kubernetes/kube-state-metrics |
| Pushgateway documentation | https://prometheus.io/docs/practices/pushing/ |
| Pushgateway GitHub | https://github.com/prometheus/pushgateway |
| Pushgateway Helm chart | https://artifacthub.io/packages/helm/prometheus-community/prometheus-pushgateway |
| Prometheus exporters list | https://prometheus.io/docs/instrumenting/exporters/ |
| Textfile collector guide | https://github.com/prometheus/node_exporter#textfile-collector |
| Writing exporters — best practices | https://prometheus.io/docs/instrumenting/writing_exporters/ |
| Google SRE — Four Golden Signals | https://sre.google/sre-book/monitoring-distributed-systems/#xref_monitoring_golden-signals |