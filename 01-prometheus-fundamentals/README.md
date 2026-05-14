# Demo 01: Prometheus Architecture, Data Model & First Scrape

## Overview

Every production outage investigation begins with the same question: *what changed,
and when?* Without a metrics system, you are operating blind — relying on user
complaints and guesswork to find problems that should have been visible minutes
before they became outages.

Prometheus answers that question by continuously pulling numeric measurements from
every component in your system, storing them in a purpose-built time-series database,
and making every measurement queryable within seconds. It is the foundation of
modern open-source observability and the backbone of the LGTM+ stack you will build
across this demo series.

**Real-world scenario:**
You have just joined a platform team. The company runs a microservices e-commerce
application on Kubernetes — an order-processing API, a product catalogue, and a
payment service. The team has no metrics visibility. When an incident occurs, everyone
logs into servers and runs `top` and `df` manually. Your first task: stand up Prometheus
so every service's CPU, memory, request rate, and error rate is visible in one place
before the next release goes out tonight.

**What this demo covers:**

- Why Prometheus was built the way it is — pull model vs push, and when each wins
- The TSDB — how data is physically stored on disk and what the write path looks like
- The four metric types — what they measure, when to use each, and the traps to avoid
- Labels and cardinality — the most powerful and most dangerous feature of Prometheus
- The `/metrics` text format — how to read it from any target
- `kube-prometheus-stack` Helm chart — what it installs and why each component exists
- The Prometheus Operator — why it exists and how it eliminates manual config
- Kubernetes service discovery — how Prometheus finds pods automatically
- The Prometheus UI — Targets, Graph, Service Discovery, TSDB Status pages
- `scrape_interval` vs `evaluation_interval` — two separate clocks with different jobs
- `promtool` — the official CLI for validating configs and rules in CI/CD pipelines
- The four golden signals — applied as PromQL queries to real running metrics

---

## Google's Four Golden Signals — The Framework Behind This Demo

Google's SRE Book defines four signals that, together, give you sufficient
visibility into any service. Every metric in this demo and every demo that follows
maps to one of these four. This is not theory — it is the framework Google uses
in production.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                  Google's Four Golden Signals                           │
├───────────────┬─────────────────────────────────────────────────────────┤
│  LATENCY      │ How long it takes to serve a request                    │
│               │ Prometheus: histogram_quantile(0.99, rate(bucket[5m]))  │
│               │ Key: distinguish successful vs failed request latency   │
│               │ A slow error is different from a fast error             │
├───────────────┼─────────────────────────────────────────────────────────┤
│  TRAFFIC      │ How much demand is on your system right now             │
│               │ Prometheus: sum(rate(http_requests_total[5m]))          │
│               │ Unit: requests/second, queries/second, writes/second    │
├───────────────┼─────────────────────────────────────────────────────────┤
│  ERRORS       │ Rate of requests that fail                              │
│               │ Prometheus: rate(requests_total{status=~"5.."}[5m])    │
│               │ Covers explicit (500 codes) and implicit (wrong content)│
├───────────────┼─────────────────────────────────────────────────────────┤
│  SATURATION   │ How full or overloaded the service is                   │
│               │ Prometheus: memory_bytes / memory_limit_bytes           │
│               │ Measure utilisation against capacity, not raw values    │
└───────────────┴─────────────────────────────────────────────────────────┘
```

> **Why this framework matters:** Teams that alert on symptoms (the four golden
> signals — things users actually experience) catch real problems. Teams that alert
> on causes alone get alert fatigue and miss the real issues. Monitor what users
> feel first, then drill into causes.

---

## Symptoms vs Causes in Observability

This distinction is one of the most important concepts in the Google SRE model
and one of the most frequently misunderstood by engineers new to monitoring.

### Symptom — What You Observe

A symptom is an externally visible signal that something is wrong. It surfaces
through your monitoring stack — metrics, logs, traces showing something has changed.

```
Examples of symptoms (alert on these):
  API p99 latency > 2 seconds
  Error rate > 1% of requests
  Pod restart count increasing
  Queue depth growing continuously
  CPU saturation > 90% for > 5 minutes
```

Key property: symptoms tell you **that** something is wrong, not **why**.

### Cause — Why It Happened

A cause is the underlying reason that produced the symptom.
You discover causes through investigation — logs, traces, profiling, code review.

```
Examples of causes (investigate to find these):
  Memory leak         → pod OOMKilled           → pod restarts (symptom)
  Slow database query → connection pool exhaust  → API latency spike (symptom)
  Bad deployment      → nil pointer exception    → 500 error rate (symptom)
  Missing index       → full table scan on DB    → high CPU + latency (symptom)
```

### Real-World Scenarios — Symptom → Cause Chain

```
Scenario 1: E-commerce checkout is slow
  Symptom : p99 checkout latency > 8 seconds  (alert fires)
  Signal  : Prometheus histogram_quantile shows spike
  Causes  : Payment service dependency timeout
            DB connection pool exhausted under Black Friday load
            Network partition between services

Scenario 2: Kubernetes pods restarting
  Symptom : kube_pod_container_status_restarts_total increasing
  Signal  : Prometheus kube-state-metrics shows restart counter climbing
  Causes  : OOMKilled — memory limit too low for actual usage
            Application crash loop — bug in new deployment
            Liveness probe misconfigured — killing healthy pods

Scenario 3: Order API errors spiking
  Symptom : HTTP 500 rate > 5% (SLO breach imminent)
  Signal  : Prometheus http_requests_total{status=~"5.."} rising
  Causes  : New buggy deployment 30 minutes ago
            Downstream inventory service returning errors
            Database schema migration breaking queries
```

### The Three Pillars Bridge the Gap

```
Metrics  → Detect symptoms     "p99 latency is 8 seconds — something is wrong"
Logs     → Provide context     "DB connection: timeout after 5000ms"
Traces   → Show request flow   "Request spent 7.9s waiting for DB connection"

Together → Infer the cause     "DB connection pool is exhausted"
```

### Common Mistakes

```
WRONG approach: alert on causes only
  "CPU > 80%"         → alert fires constantly on healthy bursts
  "Memory > 70%"      → fires on expected normal usage
  Result: alert fatigue, on-call team stops responding

RIGHT approach: alert on symptoms, investigate causes
  "p99 latency > 2s"  → users are feeling slowness — investigate
  "Error rate > 1%"   → users are seeing failures — investigate
  Result: every alert means a real user impact
```

> **The mental model:** Symptom = smoke (your monitoring shows it).
> Cause = fire (your engineering effort finds and fixes it).
> Prometheus shows you the smoke clearly. Finding the fire is the SRE's job.

---

## Prometheus in the Open-Source Observability Ecosystem

Before diving into how Prometheus works, understand where it fits in the
full LGTM+ stack you are building across all 25 demos.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                Open-Source Observability Stack (LGTM+)                   │
├───────────────────────────┬──────────────────────────────────────────────┤
│  Component                │  Role                                        │
├───────────────────────────┼──────────────────────────────────────────────┤
│  Prometheus (this demo)   │  Metrics: scrapes /metrics every 15 seconds  │
│                           │  Stores time-series in local TSDB (15d)      │
│                           │  Evaluates alerting and recording rules       │
├───────────────────────────┼──────────────────────────────────────────────┤
│  Grafana (Demo 04)        │  Dashboards: connects to Prometheus via API  │
│                           │  Renders PromQL queries as panels and graphs │
├───────────────────────────┼──────────────────────────────────────────────┤
│  Loki + Alloy (Demo 05–06)│  Logs: Alloy collects pod logs, sends to Loki│
│                           │  LogQL for searching and filtering log streams│
├───────────────────────────┼──────────────────────────────────────────────┤
│  Alertmanager (Demo 07–08)│  Routing: deduplicates and routes alerts     │
│                           │  Slack, PagerDuty, email receivers           │
├───────────────────────────┼──────────────────────────────────────────────┤
│  Tempo (Demo 09–10)       │  Traces: stores distributed spans            │
│                           │  TraceQL for trace analysis and correlation  │
├───────────────────────────┼──────────────────────────────────────────────┤
│  Mimir (Demo 22)          │  Long-term metrics: remote_write from Prom   │
│                           │  S3 backend — years of metric retention      │
├───────────────────────────┼──────────────────────────────────────────────┤
│  Pyroscope (Demo 23)      │  Profiling: CPU flame graphs, memory alloc   │
│                           │  The 4th observability pillar                │
└───────────────────────────┴──────────────────────────────────────────────┘
```

---

## Why Prometheus Uses a Pull Model — And When to Use Push Instead

The single most important architectural decision in Prometheus: it reaches
out to targets rather than targets sending data to Prometheus. This is called
the **pull model**.

### How Pull vs Push Work

```
Push model (traditional — StatsD, Graphite, many agents):

  App instance 1 ──────────────────────────────────────────► Monitoring server
  App instance 2 ──────────────────────────────────────────► Monitoring server
  App instance 3 ──────────────────────────────────────────► Monitoring server

  App decides: when to send, how often, what format
  If app is broken: it may still push — masking the failure
  Network failure: ambiguous — is the app down, or just not pushing?
  Thundering herd: 1000 pods restart simultaneously and flood the server


Pull model (Prometheus):

  Prometheus ─── HTTP GET /metrics every 15s ──► App instance 1
  Prometheus ─── HTTP GET /metrics every 15s ──► App instance 2
  Prometheus ─── HTTP GET /metrics every 15s ──► App instance 3

  Prometheus controls: when to scrape, how often, which targets exist
  If scrape fails: Prometheus knows immediately — sets up{instance="..."} = 0
  Network failure: explicit and visible — scrape fails with connection error
  Thundering herd: Prometheus paces the scrapes — targets cannot flood it
```

### Why Pull Wins for Kubernetes Monitoring

```
1. Prometheus controls the scrape rate
   One place to tune: scrape_interval in prometheus.yaml or values.yaml
   No risk of apps flooding the system during startup bursts

2. Failure is explicit and unambiguous
   Scrape failure → up{instance="..."} = 0  (you can alert on this)
   Push: absence of data is ambiguous — down or just no traffic?

3. Centralised instance discovery
   Prometheus uses Kubernetes API for service discovery via Operator
   New pod starts → Prometheus discovers it via ServiceMonitor in < 30s
   Pod terminates → scrape target disappears cleanly

4. Debug any target on demand
   Point Prometheus at any pod IP without changing the app
   Invaluable during incidents for investigating specific instances

5. Configuration lives in one place
   ServiceMonitor CRDs define what gets scraped — not scattered configs
```

### When Pull Is the Wrong Choice — Use Push Instead

```
Problem 1: Short-lived batch jobs
  A Kubernetes Job runs for 45 seconds then exits.
  Prometheus scrapes every 15 seconds — the job may complete between scrapes.
  Metrics are never captured.

  Solution: Pushgateway
  Job pushes metrics to Pushgateway when it completes.
  Prometheus scrapes Pushgateway (long-lived) on its normal schedule.

  ⚠️  Pushgateway warning: no TTL by default — stale metrics persist after
      job deletion. Always label with job name and delete metrics explicitly
      on job completion via the Pushgateway API.

Problem 2: AWS Lambda / Fargate / ephemeral workloads
  Lambda runs for 50ms, has no stable network address, no fixed IP.
  Prometheus cannot reach it — no inbound connectivity, no fixed endpoint.

  Solution: Push to CloudWatch (covered in AWS observability project),
  or push to a Pushgateway the Lambda knows about.
  This is exactly why CloudWatch uses push — Lambda has no inbound address.

Problem 3: Strict network isolation (private subnets, no inbound access)
  App is in a private VPC subnet. Prometheus cannot reach port 8080.

  Solution: Deploy Prometheus in the same subnet, or use Grafana Alloy
  as a push agent that remote_writes to a Prometheus remote endpoint.
```

> **The rule:** Pull works for stable, long-running services with known network
> addresses — almost every Kubernetes workload. Use push only for ephemeral
> workloads with no stable address.

---

## The TSDB — How Prometheus Stores Data on Disk

TSDB (Time Series Database) is Prometheus's embedded storage engine.
Understanding it helps you reason about disk usage, query performance,
retention policies, and what happens when Prometheus restarts.

### What a Time Series Is

Every unique combination of metric name + labels is a separate **time series**:

```
http_requests_total{job="api", instance="10.0.0.1:8080", method="GET",  status="200"}
http_requests_total{job="api", instance="10.0.0.1:8080", method="GET",  status="500"}
http_requests_total{job="api", instance="10.0.0.1:8080", method="POST", status="200"}
http_requests_total{job="api", instance="10.0.0.2:8080", method="GET",  status="200"}
         ↑               ↑                                ↑               ↑
      metric name     labels                      4 completely separate time series
```

Each time series is a sequence of `(timestamp, float64)` pairs:

```
t=1715000000, value=14823.0
t=1715000015, value=14829.0   ← +6 requests in 15 seconds
t=1715000030, value=14841.0   ← +12 requests in 15 seconds (traffic increased)
t=1715000045, value=14841.0   ← same value (no new requests in this window)
```

### TSDB On-Disk Layout

```
/prometheus/                              ← storage root (--storage.tsdb.path)
│
├── wal/                                  ← Write-Ahead Log
│   ├── 00000001                          ← WAL segment: all incoming samples
│   └── 00000002                          ← new segment created when prev fills
│                                         ← replayed on restart after crash
│
├── chunks_head/                          ← in-memory head chunk (mmap'd to disk)
│   └── 000001                            ← most recent ~2 hours of data
│
├── 01HPB5X2YJVZWCA4QXZG6T3ZSF/          ← compacted block (ULID — time-ordered)
│   ├── chunks/                           ← compressed metric samples
│   │   └── 000001                        ← raw float64, delta-encoded
│   ├── index                             ← inverted index: label → series → chunk
│   ├── meta.json                         ← min/max time, stats, compaction history
│   └── tombstones                        ← deleted series markers (soft delete)
│
└── 01HPC7MNZAKQTB2JVZW3Y8P4RX/          ← another compacted block
    └── ...
```

### The Write Path — What Happens Every 15 Seconds

```
Step 1: Scrape
  Prometheus sends HTTP GET /metrics to the target
  Target responds with OpenMetrics text format
  Prometheus parses response → raw sample list in memory

Step 2: WAL append
  Every sample written to WAL immediately (sequential write — fast)
  WAL provides crash safety: if Prometheus dies, WAL is replayed on restart
  This is the same pattern as database transaction logs

Step 3: Head block (in-memory)
  Samples stored in compressed in-memory head block
  Head block covers approximately the most recent 2 hours
  Queries against recent data read from head block (very fast — no disk I/O)

Step 4: Block creation (every 2 hours)
  Head block flushed to disk as a new immutable 2-hour block
  Block contains: chunks (compressed samples) + index + metadata

Step 5: Compaction (background process)
  Small blocks merged into larger blocks progressively:
  2h → 6h → 24h → 48h → up to maximum block duration (31d default)
  Larger blocks = fewer files = faster range queries

Step 6: Retention enforcement
  Blocks older than --storage.tsdb.retention.time (default: 15d) are deleted
  Or when --storage.tsdb.retention.size is exceeded
```

### RAM Usage — What Drives It

```
Prometheus RAM is dominated by the head block (in-memory recent data):

Approximate RAM per active series: ~2–3 KB in the head block

Example calculation for a medium cluster:
  Node Exporter:       10 nodes × 300 metrics  =  3,000 series ×  3KB =   9 MB
  kube-state-metrics:  1 cluster × 5,000 metrics = 5,000 series ×  3KB =  15 MB
  App metrics:         5 services × 2,000 metrics = 10,000 series × 3KB =  30 MB
  ──────────────────────────────────────────────────────────────────────────────
  Total:               18,000 series                                  ~  54 MB

Cardinality explosion with user_id label (100,000 active users):
  5 services × 2,000 metrics × 100,000 users = 1,000,000,000 series
  1,000,000,000 × 3KB = 3 TB RAM  ← Prometheus OOMKills
  This is a real scenario that has happened to production companies

Check current series count:
  Prometheus UI → Status → Runtime & Build Information → Head Series
  OR query: prometheus_tsdb_head_series
```

---

## The Four Metric Types — With Real /metrics Examples

Prometheus has exactly four metric types. Choosing the right one and using
the right PromQL functions with each is a core production skill.

### Counter

A counter **only ever increases**. It resets to zero when the process restarts.
`rate()` handles counter resets automatically.

**When to use:** requests, errors, bytes transferred, tasks completed, retries.
**Never use for:** values that go down (memory, queue depth, active connections).

```
# HELP http_requests_total Total number of HTTP requests processed
# TYPE http_requests_total counter
http_requests_total{method="GET",  path="/api/orders", status="200"} 482931
http_requests_total{method="GET",  path="/api/orders", status="500"} 142
http_requests_total{method="POST", path="/api/orders", status="201"} 91283
http_requests_total{method="POST", path="/api/orders", status="400"} 837
```

```
Correct PromQL for counters:

  WRONG: http_requests_total
    Returns raw cumulative total (482931) — useless for alerting
    You cannot set a meaningful threshold on a monotonically increasing number

  CORRECT: rate(http_requests_total[5m])
    Per-second request rate over the last 5 minutes
    Handles counter resets (pod restarts) automatically
    Meaningful: "14.2 requests per second"

  CORRECT: increase(http_requests_total[1h])
    Total new requests in the last 1 hour — useful for trend reporting
    "3,420 new requests in the past hour"

  Rule: never use a raw counter value in an alert or dashboard panel.
        Always wrap with rate() or increase().
```

### Gauge

A gauge **goes up and down**. It represents a snapshot of a current value.

**When to use:** memory usage, CPU temperature, queue depth, active connections,
goroutine count, pod replica count.
**Never use for:** monotonically increasing values.

```
# HELP node_memory_MemAvailable_bytes Memory available for new allocations
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 4294967296

# HELP go_goroutines Number of goroutines that currently exist
# TYPE go_goroutines gauge
go_goroutines 42

# HELP kube_deployment_status_replicas_available Deployment available replicas
# TYPE kube_deployment_status_replicas_available gauge
kube_deployment_status_replicas_available{namespace="default",deployment="api"} 3
```

```
Correct PromQL for gauges:

  CORRECT: node_memory_MemAvailable_bytes / 1024 / 1024 / 1024
    Current available memory in GB — query directly, no function needed

  CORRECT: predict_linear(node_filesystem_avail_bytes[6h], 24 * 3600)
    Project current disk trend 24 hours forward
    "At current rate, disk will be full in X hours" — proactive alerting

  CORRECT: delta(go_goroutines[10m])
    How much did goroutine count change in the last 10 minutes?
    Positive delta that keeps growing = possible goroutine leak

  WRONG: rate(node_memory_MemAvailable_bytes[5m])
    rate() assumes monotonic increase (counter semantics)
    On a gauge it produces nonsense when the value decreases
```

### Histogram

A histogram **samples observations into configurable buckets** and also tracks
`_sum` (total of all observed values) and `_count` (number of observations).

**When to use:** request duration, response size, database query time.
**Critical:** bucket boundaries must be defined at instrumentation time.

```
# HELP http_request_duration_seconds Request latency histogram
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005"} 724
http_request_duration_seconds_bucket{le="0.01"}  1205
http_request_duration_seconds_bucket{le="0.025"} 2891
http_request_duration_seconds_bucket{le="0.05"}  4201
http_request_duration_seconds_bucket{le="0.1"}   4803
http_request_duration_seconds_bucket{le="0.25"}  4961
http_request_duration_seconds_bucket{le="0.5"}   4989
http_request_duration_seconds_bucket{le="1"}     4997
http_request_duration_seconds_bucket{le="+Inf"}  5000
http_request_duration_seconds_sum   184.231
http_request_duration_seconds_count 5000
```

```
Reading this histogram:
  724 of 5000 requests completed in ≤ 5ms      (14.5% very fast)
  4803 of 5000 requests completed in ≤ 100ms   (96% under SLO if SLO = 100ms)
  5000 - 4997 = 3 requests took more than 1 second
  Average latency = 184.231 / 5000 = 36.8ms

Calculating p99 latency (the most important latency metric):
  histogram_quantile(
    0.99,
    rate(http_request_duration_seconds_bucket[5m])
  )
  → histogram_quantile interpolates between bucket boundaries
  → Design buckets to bracket your SLO (e.g. le="0.1" if SLO is 100ms)

Why three series (_bucket, _sum, _count)?
  _bucket: cumulative — "how many requests fell below this threshold?"
  _sum:    total observed duration — divide by _count for average latency
  _count:  number of observations — same semantics as a counter

Prometheus 3.x: Native Histograms
  New in Prometheus 3.0: dynamic buckets, more accurate, lower cardinality.
  Enabled in this demo via enableFeatures: [native-histograms] in values.yaml.
  Client libraries support both formats simultaneously.
  Classic format above still fully supported — nothing breaks.

Histogram vs Summary (always choose histogram unless you have a specific reason):
  Histogram: buckets at code time, quantiles at query time — aggregatable ✅
  Summary:   quantiles at scrape time, per-instance — not aggregatable ❌
  Rule: use histogram unless you specifically need single-instance quantiles
        and cannot tolerate any query-time approximation.
```

### Summary

A summary **calculates quantiles client-side** (inside the application).
It exports pre-calculated quantile values plus `_sum` and `_count`.

**When to use:** only when you need accurate single-instance quantiles.
Almost always prefer histogram.

```
# HELP go_gc_duration_seconds Pause duration of garbage collection cycles
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"}    3.9012e-05
go_gc_duration_seconds{quantile="0.25"} 5.1e-05
go_gc_duration_seconds{quantile="0.5"}  6.8e-05
go_gc_duration_seconds{quantile="0.75"} 9.3e-05
go_gc_duration_seconds{quantile="1"}    0.000293
go_gc_duration_seconds_sum   0.4829
go_gc_duration_seconds_count 4821
```

```
Summary limitations that make histogram almost always better:

  You cannot aggregate summaries across instances:
    Averaging p99 across 10 pods is mathematically incorrect
    sum(p99 per pod) / 10 is NOT the p99 across all pods

  Quantile levels are fixed at deploy time:
    If you instrument with quantile="0.99" but later need p99.9,
    you must redeploy the application and wait for new data

  When summary is correct:
    Single-instance application where exact quantiles matter
    Cannot tolerate any histogram interpolation inaccuracy
    Specific documented technical requirement for per-instance precision
```

---

## Labels and Cardinality — Power and Danger

Labels are key-value pairs attached to every metric. They make Prometheus
enormously expressive. They are also the most common source of Prometheus
OOMKills in production.

### What Labels Enable

```
Without labels:
  http_requests_total = 9283
  (one number — which service? which endpoint? which status code? unknown)

With labels:
  http_requests_total{service="orders", method="POST", status="201"} = 8291
  http_requests_total{service="orders", method="POST", status="500"} = 992
  http_requests_total{service="orders", method="GET",  status="200"} = 44821

  Now you can answer:
    What is the error rate for the orders POST endpoint?
    Which service handles the most traffic?
    Which HTTP methods are returning errors?
```

### Cardinality — The Most Important Production Concern

**Cardinality** = total number of unique time series in the TSDB head block.
Each unique combination of `{metric_name, all_label_values}` = 1 series.

```
Safe cardinality example:
  http_requests_total with bounded labels:
    service: orders, payment, catalogue    (3 values)
    method:  GET, POST, PUT, DELETE        (4 values)
    status:  200, 201, 400, 404, 500, 503  (6 values)

  Total: 3 × 4 × 6 = 72 series            ← perfectly fine ✅


Cardinality explosion (this destroys Prometheus in production):
  Add user_id label (100,000 active users)
  3 × 4 × 6 × 100,000 = 7,200,000 series

  At ~3 KB RAM per series in the head block:
  7,200,000 × 3 KB = ~21 GB RAM consumed by ONE metric
  Prometheus OOMKills → monitoring disappears → during an incident
  This exact scenario has happened at real companies.


Production cardinality targets by cluster size:
  Small  (< 5 nodes):    50,000 – 200,000 series
  Medium (5–50 nodes):   200,000 – 1,000,000 series
  Large  (50+ nodes):    1M+ series (needs tuning and Mimir — Demo 22)
```

### Label Cardinality Rules

```
✅  GOOD labels — bounded, enumerable, stable:
  service, pod, namespace, method, status_code, region, environment
  HTTP method: GET, POST, PUT, DELETE — always 4–5 values ✅
  HTTP status: 200, 404, 500 — always 10–20 common values ✅

❌  BAD labels — unbounded, growing, unique per request:
  user_id      → grows with every new user (millions)
  request_id   → unique per request (billions/day)
  session_id   → same problem as request_id
  email        → unique per user — same as user_id
  url          → with query params ?page=1&sort=price is infinite
  timestamp    → new series every millisecond

The test before adding any label:
  "Can I enumerate every possible value of this label?"
  method: yes (GET, POST, ...) — safe to use ✅
  user_id: no (grows forever)  — never use ❌
```

### Labels Added Automatically by Prometheus

```
When Prometheus scrapes a target, it adds target labels automatically.
You did not write these — the Prometheus Operator sets them from CRDs:

http_requests_total{
  method="GET",                                       ← your application label
  status="200",                                       ← your application label
  job="default/order-api/0",                          ← from ServiceMonitor
  instance="10.244.0.12:8080",                        ← pod IP:port
  namespace="default",                                ← from Kubernetes metadata
  pod="order-api-deployment-abc123",                  ← pod name
  service="order-api",                                ← service name
  container="order-api"                               ← container name
}
```

---

## The Prometheus Operator — Why It Exists

Without the Prometheus Operator, every new application scraping requires
manual edits to `prometheus.yaml`. In Kubernetes with dozens of services
deploying constantly, this becomes a bottleneck for every team.

### Without Prometheus Operator — The Problem

```
Developer deploys "inventory-service":
  → Manually edits prometheus.yaml:
      scrape_configs:
        - job_name: 'inventory-service'
          static_configs:
            - targets: ['10.244.0.25:8080']
  → Opens PR, waits for review
  → Pod restarts with new IP 10.244.0.31 → config is stale
  → Repeat for every service, every deployment

Problems:
  Manual prometheus.yaml is a bottleneck — central team controls all scraping
  Pod IP changes break static configs immediately after every deploy
  No self-service — developer cannot add their own service to Prometheus
  One team's bad scrape config can break Prometheus for everyone
```

### With Prometheus Operator — CRD-Based Self-Service

```
Developer deploys "inventory-service" and creates one ServiceMonitor CRD:

  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: inventory-service
    namespace: inventory
  spec:
    selector:
      matchLabels:
        app: inventory-service
    endpoints:
      - port: metrics
        interval: 15s

What happens automatically (no human intervention required):
  1. Prometheus Operator sees the new ServiceMonitor via Kubernetes watch
  2. Queries Kubernetes API for endpoints matching selector
  3. Generates prometheus.yaml scrape_config with real pod IPs
  4. POSTs to Prometheus /-/reload endpoint (no restart needed)
  5. Prometheus scrapes inventory-service within 30 seconds
  6. Pod restarts with new IP → Operator updates config automatically

Benefits:
  Fully self-service — development team manages their own ServiceMonitor
  RBAC on ServiceMonitor CRDs — namespaces control their own scraping
  Pod IP changes handled automatically — Kubernetes endpoints always fresh
  PrometheusRule CRD follows the same pattern for alert rules
```

### CRDs Installed by the Operator

```bash
# Verify CRDs are installed after Step 5
kubectl get crd | grep monitoring.coreos.com
```

Expected output:
```
alertmanagerconfigs.monitoring.coreos.com    ← Alertmanager routing per namespace
alertmanagers.monitoring.coreos.com          ← Deploy Alertmanager instances
podmonitors.monitoring.coreos.com            ← Scrape pods directly (no Service)
probes.monitoring.coreos.com                 ← Blackbox Exporter probes (Demo 19)
prometheuses.monitoring.coreos.com           ← Deploy Prometheus instances
prometheusrules.monitoring.coreos.com        ← Alerting and recording rules
scrapeconfigs.monitoring.coreos.com          ← Low-level scrape config (non-CRD)
servicemonitors.monitoring.coreos.com        ← Scrape a Service's endpoints
thanosrulers.monitoring.coreos.com           ← Federated alerting with Thanos
```

---

## scrape_interval vs evaluation_interval — Two Separate Clocks

These control different things, run independently, and must be understood separately.

```
scrape_interval (default: 1m, recommended: 15s)
├── Controls: how often Prometheus sends HTTP GET /metrics to targets
├── Set in: global.scrape_interval (yaml) or per-ServiceMonitor spec.endpoints[].interval
├── Shorter = more data points = better alerting precision = more disk + RAM
└── Standard: 15s production, 30s cost-sensitive, 5s high-frequency


evaluation_interval (default: 1m, recommended: match scrape_interval)
├── Controls: how often Prometheus evaluates ALL recording and alerting rules
├── Set in: global.evaluation_interval only (applies to every rule group)
├── Can be overridden per rule group via the interval: field in PrometheusRule
└── Must be: ≥ scrape_interval (evaluating rules against stale data causes problems)


The timeline with both set to 15s (recommended):
  t=0s    Scrape all targets → fresh samples written to TSDB
  t=0s    Evaluate all rules → run against fresh data ✅
  t=15s   Scrape all targets again → new samples
  t=15s   Evaluate all rules again → always fresh
  t=30s   ...

What happens when evaluation_interval < scrape_interval (wrong):
  t=0s    Scrape (scrape_interval=60s)
  t=15s   Evaluate rules (evaluation_interval=15s) → data is 15 seconds stale ⚠️
  t=30s   Evaluate rules → data is 30 seconds stale ⚠️
  t=45s   Evaluate rules → data is 45 seconds stale ⚠️
  t=60s   Scrape → fresh data
  t=60s   Evaluate rules → fresh ✅
  Rules evaluate against stale data 3 of every 4 evaluation cycles

Production recommendation: set both to 15s (kube-prometheus-stack default)
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Minikube Cluster                                │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │                       monitoring namespace                          │     │
│  │                                                                     │     │
│  │  ┌─────────────────────────────────┐  ┌─────────────────────────┐   │     │
│  │  │    Prometheus Operator          │  │    Alertmanager         │   │     │
│  │  │    (Deployment, 1 replica)      │  │    (StatefulSet)        │   │     │
│  │  │                                 │  │    Port 9093            │   │     │
│  │  │    Watches:                     │  │    Deduplicates +       │   │     │
│  │  │      ServiceMonitor CRDs        │  │    routes fired alerts  │   │     │
│  │  │      PodMonitor CRDs            │  │    to Slack / email /   │   │     │
│  │  │      PrometheusRule CRDs        │  │    PagerDuty            │   │     │
│  │  │                                 │  └─────────────────────────┘   │     │
│  │  │    Generates: prometheus.yaml   │                                │     │
│  │  │    Reloads:   /-/reload API     │  ┌─────────────────────────┐   │     │
│  │  └─────────────────────────────────┘  │    Grafana              │   │     │ 
│  │                                       │    (Deployment)         │   │     │  
│  │  ┌──────────────────────────────────────────────────────────┐   │   │     │
│  │  │             Prometheus Server                            │   │   │     │
│  │  │             (StatefulSet, 1 replica, Port 9090)          │   │   │     │
│  │  │             10Gi PVC for TSDB — 10d retention            │   │   │     │
│  │  │                                                          │   │   │     │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐  │   │   │     │
│  │  │  │  Scraper     │  │    TSDB      │  │ Rule Evaluator │  │   │   │     │
│  │  │  │ Pull /metrics│  │ WAL → Head   │  │ Every 15s      │  │   │   │     │
│  │  │  │ every 15s    │  │ → Disk Blks  │  │ Recording rules│  │   │   │     │
│  │  │  └──────┬───────┘  └──────────────┘  │ Alerting rules │  │   │   │     │
│  │  └─────────┼────────────────────────────┴────────────────┴──┘   │   │     │
│  │            │                                                        │     │
│  │   ① HTTP GET /metrics (pull model — Prometheus reaches out)         │     │ 
│  │            │                                                        │     │
│  │  ┌─────────▼──────────────────────────────────────────────────┐     │     │
│  │  │                   Scrape Targets                           │     │     │
│  │  │  ┌─────────────┐  ┌──────────────────┐  ┌─────────────┐    │     │     │
│  │  │  │Node Exporter│  │kube-state-metrics│  │  Grafana    │    │     │     │
│  │  │  │(DaemonSet)  │  │(Deployment)      │  │(self-mon)   │    │     │     │
│  │  │  │Port 9100    │  │Port 8080         │  │Port 3000    │    │     │     │
│  │  │  │Host: CPU    │  │K8s API state:    │  │             │    │     │     │
│  │  │  │mem, disk    │  │pods, deploys,    │  │             │    │     │     │
│  │  │  │network, fs  │  │PVCs, resource    │  │             │    │     │     │
│  │  │  │             │  │limits, quotas    │  │             │    │     │     │
│  │  │  └─────────────┘  └──────────────────┘  └─────────────┘    │     │     │
│  │  └────────────────────────────────────────────────────────────┘     │     │
│  └─────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │                       default namespace                             │     │
│  │  ┌──────────────────────────────────────────────────────────────┐   │     │
│  │  │  podinfo test app (Deployment, 3 replicas)                   │   │     │
│  │  │  Port 9898: HTTP API  |  Port 9797: /metrics                 │   │     │
│  │  │  ServiceMonitor CRD → Operator → scrape config auto-generated│   │     │
│  │  └──────────────────────────────────────────────────────────────┘   │     │
│  └─────────────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────────────┘

Signal flows:
  ① Prometheus ──(HTTP GET /metrics every 15s)──► each target
  ② Samples ──► WAL ──► head block ──► disk blocks (compaction)
  ③ PromQL query ──► Prometheus API ──► Grafana / UI
  ④ Alert rule fires ──► Alertmanager ──► Slack / email
  ⑤ ServiceMonitor created ──► Operator ──► prometheus.yaml regenerated ──► reload
```

---

## Versions Used in This Demo

| Component | Version | Notes |
|---|---|---|
| kube-prometheus-stack Helm chart | **84.5.0** | `prometheus-community/kube-prometheus-stack` |
| Prometheus | **3.4.1** | bundled — `prom/prometheus:v3.4.1` |
| Prometheus Operator | **0.90.1** | bundled |
| Alertmanager | **0.28.1** | bundled |
| Grafana | **12.3.0** | bundled |
| Node Exporter | **1.11.1** | bundled |
| kube-state-metrics | **2.18.0** | bundled via kube-state-metrics chart 7.3.0 |
| podinfo (test app) | **6.7.1** | `ghcr.io/stefanprodan/podinfo:6.7.1` |
| Minikube | **1.35.0+** | [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io) |
| Helm | **3.17.0+** | [helm.sh](https://helm.sh) |
| kubectl | **1.32+** | [kubernetes.io](https://kubernetes.io) |

> **Version policy for this project:** Every demo pins explicit chart and image versions.
> Using `latest` tags breaks reproducibility — a breaking change in a new release
> makes your environment stop working days after you wrote it.
> Always check [ArtifactHub](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack)
> for the current stable release when starting a new lab environment.

---

## Prerequisites

**Software required on your local machine:**

| Tool | Minimum version | Verify command |
|---|---|---|
| Minikube | **1.37.0** | `minikube version` |
| kubectl | **1.34.1** | `kubectl version --client` |
| Helm | **3.19.0** | `helm version --short` |
| curl | any | `curl --version` |

**Knowledge expected:**
- Basic Kubernetes: pods, deployments, services, namespaces, kubectl
- Basic Helm: `helm repo add`, `helm install`, values files, `helm upgrade`
- YAML syntax familiarity

**Verify all tools before starting:**

```bash
minikube version && kubectl version --client && helm version --short
```

Expected output (your versions may be newer — that is fine):
```
minikube version: v1.37.0
...
Client Version: v1.34.1
...
v3.19.0+g3d8990f
```

---

## Lab Objectives

By the end of this demo you will be able to:

1. ✅ Explain why Prometheus uses a pull model and when to use Pushgateway instead
2. ✅ Describe the TSDB write path: scrape → WAL → head block → disk → compaction
3. ✅ Identify all four metric types from a raw `/metrics` endpoint
4. ✅ Explain label cardinality and calculate its RAM cost
5. ✅ Describe what the Prometheus Operator does and how it replaces manual config
6. ✅ Explain the difference between `scrape_interval` and `evaluation_interval`
7. ✅ Deploy `kube-prometheus-stack` v84.5.0 with a custom values file
8. ✅ Navigate Targets, Graph, Service Discovery, and TSDB Status pages
9. ✅ Deploy a test application and make it auto-discoverable via ServiceMonitor
10. ✅ Write five PromQL queries covering the four golden signals
11. ✅ Validate the running configuration with `promtool`
12. ✅ Simulate CPU load and watch metrics respond in real time

---

## Directory Structure

```
01-prometheus-fundamentals/
├── README.md                               ← this file
└── src/
    ├── values.yaml                         ← kube-prometheus-stack Helm values
    └── test-app/
        ├── deployment.yaml                 ← podinfo (3 replicas)
        ├── service.yaml                    ← ClusterIP Service
        └── servicemonitor.yaml             ← ServiceMonitor CRD
```

---

## Step 1: Start Minikube

`kube-prometheus-stack` requires at least 4 CPUs and 8 GB RAM because it runs
Prometheus (TSDB in memory), Grafana, Alertmanager, Prometheus Operator,
Node Exporter, and kube-state-metrics simultaneously — before any applications.

```bash
minikube start \
  --profile observ \
  --cpus=4 \
  --memory=8192 \
  --driver=docker \
  --kubernetes-version=v1.33.0
```

**Why `--driver=docker`?**
Docker is the most portable Minikube driver — works on macOS, Linux, and Windows
without a hypervisor license. It runs Minikube inside a container, starts faster,
and uses less disk than a full VM. On Linux, `--driver=kvm2` gives slightly better
performance if you have KVM available.

**Expected output:**
```
😄  minikube v1.35.0
✨  Using the docker driver based on user choice
🔥  Creating docker container (CPUs=4, Memory=8192MB) ...
🐳  Preparing Kubernetes v1.33.0 on Docker ...
🔗  Configuring bridge CNI ...
🔎  Verifying Kubernetes components...
🏄  Done! kubectl is now configured to use "minikube" cluster
```

Verify the node is Ready before proceeding:

```bash
kubectl get nodes
```

Expected:
```
NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   60s   v1.33.0
```

---

## Step 2: Add the Helm Repository

```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts

helm repo update
```

Expected output:
```
"prometheus-community" has been added to your repositories
...Successfully got an update from the "prometheus-community" chart repository
Update Complete. ⎈Happy Helming!⎈
```

Confirm the exact chart version is available before installing:

```bash
helm search repo prometheus-community/kube-prometheus-stack \
  --version 84.5.0
```

Expected output:
```
NAME                                              CHART VERSION   APP VERSION
prometheus-community/kube-prometheus-stack        84.5.0          0.90.1
```

If this returns no results, run `helm repo update` again and retry.

---

## Step 3: Create the Monitoring Namespace

```bash
kubectl create namespace monitoring
```

**Why a dedicated namespace?**

```
Isolation benefits:
  RBAC: restrict who can read monitoring configs without affecting app namespaces
  Resource quotas: cap observability RAM/CPU independent from app budgets
  Cleanup: kubectl delete namespace monitoring removes everything in one command
  Visibility: kubectl get pods -n monitoring shows only monitoring components

Naming convention: "monitoring" is the universal standard.
  All kube-prometheus-stack documentation and examples use "monitoring".
  Avoid custom names — they break most copy-paste examples and community runbooks.
```

Verify:
```bash
kubectl get namespace monitoring
```

Expected:
```
NAME         STATUS   AGE
monitoring   Active   5s
```

---

## Step 4: Create the Helm Values File

The `values.yaml` file overrides defaults from the chart. Only specify what
you are changing — everything else inherits from the chart's default `values.yaml`.
Each setting is explained below with the reason for the choice.

Create `src/values.yaml`:

```yaml
# src/values.yaml
# kube-prometheus-stack custom values
# Chart: 84.5.0  |  Prometheus: 3.4.1  |  Grafana: 12.3.0
#
# Only settings that differ from chart defaults are shown.
# View full defaults: helm show values prometheus-community/kube-prometheus-stack --version 84.5.0

# ── Prometheus ───────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:

    # How often Prometheus scrapes each target.
    # 15s is the production standard: fine enough for alerting,
    # coarse enough to keep data volume manageable.
    scrapeInterval: "15s"

    # How often to evaluate alerting and recording rules.
    # Must equal or exceed scrapeInterval so rules run against fresh data.
    evaluationInterval: "15s"

    # How long to keep data locally.
    # 10d is appropriate for demos. Production: 15-30d local + Mimir for long-term.
    retention: 10d

    # Persist TSDB data across pod restarts.
    # Without this, ALL metrics are lost when the Prometheus pod restarts
    # (version upgrade, node eviction, OOMKill — all destroy data).
    # Minikube provisions hostPath volumes via the 'standard' StorageClass.
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi

    # Allow Prometheus to discover ServiceMonitors in ALL namespaces.
    # Default (true) restricts discovery to ServiceMonitors labelled with
    # the same Helm release name — too restrictive for cross-namespace monitoring.
    # Set false so application teams can create ServiceMonitors in their own
    # namespaces without needing to add the Helm release label.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

    # Resource limits sized for a 4-CPU / 8GB Minikube node.
    # Production sizing: use prometheus_tsdb_head_series × 3KB to estimate RAM.
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 500m
        memory: 1Gi

    # Prometheus 3.x: native histograms
    # More accurate than classic histograms, uses dynamic buckets, lower cardinality.
    # Safe to enable: classic histogram format continues to work alongside it.
    enableFeatures:
      - native-histograms

# ── Alertmanager ─────────────────────────────────────────────────────────────
alertmanager:
  alertmanagerSpec:

    # Persist silence state across restarts.
    # Without this, all configured silences are lost when the pod restarts.
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi

    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi

# ── Grafana ───────────────────────────────────────────────────────────────────
grafana:

  # Admin credentials.
  # In production: use adminCredentialsSecret to reference a Kubernetes Secret.
  # Never put credentials in values.yaml in a real environment.
  adminPassword: "observability-demo"

  # Persist Grafana database (dashboards, users, alert rules) across restarts.
  persistence:
    enabled: true
    size: 1Gi

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

  # Grafana 11.x: unified alerting is the only supported engine.
  # Legacy alerting was removed in Grafana 11. These settings make it explicit.
  grafana.ini:
    unified_alerting:
      enabled: true
    alerting:
      enabled: false

# ── Node Exporter ─────────────────────────────────────────────────────────────
nodeExporter:
  # Exposes host-level metrics: CPU, memory, disk, network, filesystem.
  # Runs as a DaemonSet (one pod per node).
  # Port 9100. Listens on /metrics.
  # The Operator auto-creates a ServiceMonitor for it on install.
  enabled: true

# ── kube-state-metrics ────────────────────────────────────────────────────────
kubeStateMetrics:
  # Talks to the Kubernetes API server and exposes object state as metrics.
  # Covers: pod count, deployment replicas, resource limits, PVC status, events.
  # Different from Node Exporter:
  #   Node Exporter = host OS metrics (from /proc, /sys)
  #   kube-state-metrics = Kubernetes API object state (from kube-apiserver)
  enabled: true

# ── Prometheus Operator ───────────────────────────────────────────────────────
prometheusOperator:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

---

## Step 5: Install kube-prometheus-stack

```bash
helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version 84.5.0 \
  --namespace monitoring \
  --values src/values.yaml \
  --wait \
  --timeout 10m
```

**Flags explained:**

| Flag | Purpose |
|---|---|
| `--version 84.5.0` | Pin exact chart version — never omit this |
| `--namespace monitoring` | Install all resources into the monitoring namespace |
| `--values src/values.yaml` | Apply our custom settings on top of chart defaults |
| `--wait` | Block the terminal until all pods reach Running/Ready state |
| `--timeout 10m` | Allow up to 10 minutes for image pulls on a slow connection |

**Expected output:**
```
NAME: kube-prometheus-stack
LAST DEPLOYED: [timestamp]
NAMESPACE: monitoring
STATUS: deployed
REVISION: 1
```

Monitor pods starting (takes 2–3 minutes on first run while images pull):

```bash
kubectl get pods -n monitoring -w
```

Press Ctrl+C when all pods show READY. Final expected state:

```bash
kubectl get pods -n monitoring
```

```
NAME                                                        READY   STATUS    RESTARTS
alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0
kube-prometheus-stack-grafana-5c9f4b67c-xkp2r               3/3     Running   0
kube-prometheus-stack-kube-state-metrics-7d9f8b8bd5-p9p4m   1/1     Running   0
kube-prometheus-stack-operator-6c8b7d9f5-jkr8n              1/1     Running   0
kube-prometheus-stack-prometheus-node-exporter-7k8qp         1/1     Running   0
prometheus-kube-prometheus-stack-prometheus-0                2/2     Running   0
```

**Why some pods have 2/2 or 3/3 containers:**

```
alertmanager-...-0  (2/2)
  Container 1: alertmanager          — the routing daemon
  Container 2: config-reloader       — watches for config changes, triggers reload
  StatefulSet because it stores silence state on a PVC

grafana-...  (3/3)
  Container 1: grafana               — the Grafana server
  Container 2: grafana-sc-datasources — sidecar: loads data sources from ConfigMaps
  Container 3: grafana-sc-dashboard   — sidecar: loads dashboards from ConfigMaps
  The sidecars enable provisioning — dashboards load automatically, no manual setup

prometheus-...-0  (2/2)
  Container 1: prometheus            — TSDB + scraper + rule evaluator
  Container 2: config-reloader       — watches generated config, triggers /-/reload
  StatefulSet because TSDB data lives on a 10Gi PVC
```

Verify PersistentVolumeClaims are bound (data survives pod restarts):

```bash
kubectl get pvc -n monitoring
```

Expected:
```
NAME                                                              STATUS   CAPACITY
alertmanager-kube-prometheus-stack-alertmanager-db-...-0          Bound    1Gi
prometheus-kube-prometheus-stack-prometheus-db-...-0              Bound    10Gi
```

If STATUS is `Pending`:
```bash
kubectl get storageclass
# 'standard (default)' must be listed
# If missing: minikube addons enable default-storageclass
```

---

## Step 6: Access the Prometheus UI and Explore

Open a port-forward to the Prometheus Service:

```bash
kubectl port-forward \
  -n monitoring \
  svc/kube-prometheus-stack-prometheus \
  9090:9090
```

Open [http://localhost:9090](http://localhost:9090) in your browser.

### Status → Targets

```
http://localhost:9090/targets
```

This page shows every target Prometheus is currently scraping.
All should show state **UP** (green):

```
Discovered and scraped by kube-prometheus-stack:
────────────────────────────────────────────────────────────────
monitoring/kube-prometheus-stack-alertmanager/0       (1/1 up)
monitoring/kube-prometheus-stack-apiserver/0          (1/1 up)
monitoring/kube-prometheus-stack-coredns/0            (1/1 up)
monitoring/kube-prometheus-stack-grafana/0            (1/1 up)
monitoring/kube-prometheus-stack-kube-state-metrics/0 (1/1 up)
monitoring/kube-prometheus-stack-kubelet/0            (1/1 up)
monitoring/kube-prometheus-stack-node-exporter/0      (1/1 up)
monitoring/kube-prometheus-stack-operator/0           (1/1 up)
monitoring/kube-prometheus-stack-prometheus/0         (1/1 up)  ← self-monitoring
```

**Why are all these targets already discovered without any config you wrote?**

The chart ships with ServiceMonitor CRDs for every component it installs.
The Prometheus Operator read those CRDs on startup and generated
`prometheus.yaml` scrape jobs automatically. This is the Operator pattern in action.

**Targets page columns explained:**

```
Endpoint    → the URL being scraped (http://10.244.0.x:9100/metrics)
State       → UP = last scrape succeeded | DOWN = failed | UNKNOWN = not yet tried
Labels      → all labels attached to this target
Last Scrape → timestamp of the most recent successful scrape
Duration    → how long that scrape took (healthy = milliseconds)
Error       → error message if DOWN (connection refused, timeout, 404, etc.)
```

Click any **Endpoint URL** to open the raw `/metrics` page in your browser
and see the OpenMetrics text format directly.

### Status → Service Discovery

```
http://localhost:9090/service-discovery
```

Shows every Kubernetes endpoint Prometheus is aware of — including endpoints
it chose not to scrape (filtered by relabeling rules). This page is essential
for debugging "why isn't my service being scraped?" — you can see whether
Prometheus found the endpoint but dropped it, versus never finding it at all.

### Status → TSDB Status

```
http://localhost:9090/tsdb-status
```

```
Important fields to check:
  Head Series:    ~15,000 – 40,000    ← total active time series (cardinality)
  Head Chunks:    [count]             ← number of in-memory chunk objects

Top 10 metric names by series count:
  Tells you which metrics contribute most to cardinality.
  In a fresh install: go_info, kube_pod_status_phase, node_cpu_seconds_total

Top 10 label names by series count:
  Usually: __name__, instance, job — all expected.
  If you see user_id or request_id here: cardinality problem has been introduced.
```

`Head Series` is your total cardinality. Monitor this value over time.
If it grows faster than your workload grows, a cardinality bomb was introduced.

---

## Step 7: Read a Raw /metrics Endpoint

Every target exposes metrics in OpenMetrics text format. Knowing how to read
this format is fundamental — every Prometheus client library in every language
produces exactly this output.

```bash
# Find the Node Exporter pod
NODE_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus-node-exporter \
  -o jsonpath='{.items[0].metadata.name}')

echo "Node Exporter pod: $NODE_POD"

# Port-forward directly to the pod
kubectl port-forward -n monitoring pod/$NODE_POD 9100:9100 &
PF_PID=$!
sleep 2

# Fetch a sample of the /metrics output
curl -s http://localhost:9100/metrics | grep -E "^(#|node_cpu|node_memory|node_filesystem)" | head -50
```

**Expected output:**

```
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"}    39284.49
node_cpu_seconds_total{cpu="0",mode="iowait"}  42.38
node_cpu_seconds_total{cpu="0",mode="irq"}     0
node_cpu_seconds_total{cpu="0",mode="nice"}    2.14
node_cpu_seconds_total{cpu="0",mode="softirq"} 83.29
node_cpu_seconds_total{cpu="0",mode="system"}  491.67
node_cpu_seconds_total{cpu="0",mode="user"}    1284.91

# HELP node_filesystem_avail_bytes Filesystem space available to non-root users.
# TYPE node_filesystem_avail_bytes gauge
node_filesystem_avail_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 1.87e+10

# HELP node_memory_MemAvailable_bytes Memory information field MemAvailable_bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 5.536e+09
```

**Reading the format — every metric has this structure:**

```
# HELP <metric_name> <human-readable description>        ← documentation line
# TYPE <metric_name> <counter|gauge|histogram|summary>   ← type declaration
<metric_name>{<label>="<value>",...} <float64>           ← data line
```

**Identifying metric type from name convention:**

```
node_cpu_seconds_total       → counter  (_total suffix = counter convention)
node_memory_MemAvailable_bytes → gauge  (snapshot value, goes up and down)
http_request_duration_seconds_bucket → histogram  (le label + _bucket suffix)
go_gc_duration_seconds{quantile=...} → summary    (quantile label present)
```

Stop the port-forward:
```bash
kill $PF_PID && wait $PF_PID 2>/dev/null
```

---

## Step 8: Your First PromQL Queries

Keep Prometheus UI open at `http://localhost:9090`. Click **Graph** tab.
Run each query and understand what it returns before moving to the next.

### Query 1 — Are all targets up?

```promql
up
```

```
Expected result:
  {job="node-exporter", instance="minikube:9100"} 1
  {job="kube-state-metrics", instance="10.244.0.5:8080"} 1
  ...

The 'up' metric is synthetic — Prometheus generates it automatically.
You wrote no code for it. Every scrape target gets one:
  1 = last scrape succeeded
  0 = last scrape failed (app crashed, port closed, OOM killed, network issue)

In production: alert on up == 0 for any critical target.
alert: rule — expr: up{job="order-api"} == 0 for: 1m
```

### Query 2 — CPU busy percentage

```promql
100 - (
  avg by (instance) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  ) * 100
)
```

```
Step-by-step breakdown:

1. node_cpu_seconds_total{mode="idle"}
   Raw counter — total CPU-seconds spent idle since boot.
   On its own: useless (just keeps increasing forever)

2. rate(...[5m])
   Per-second rate of idle time over the last 5 minutes.
   Returns a value between 0 and 1:
     0 = CPU was never idle (fully busy)
     1 = CPU was idle all the time

3. avg by (instance)(...)
   Average across all CPU cores (cpu="0", cpu="1", etc.)
   Produces one value per node, not one per CPU core

4. * 100
   Convert 0–1 fraction to percentage

5. 100 - (...)
   Invert: idle% → busy%

Expected on a lightly loaded Minikube: 5–15% busy
Expected during stress test (Step 10): 80–99% busy

Why [5m]? Range must be ≥ 4 × scrape_interval for statistical reliability.
  4 × 15s = 60s minimum. [5m] = 20 data points — standard safe default.
```

### Query 3 — Memory usage percentage (gauge query)

```promql
(
  1 - (
    node_memory_MemAvailable_bytes
    /
    node_memory_MemTotal_bytes
  )
) * 100
```

```
node_memory_MemAvailable_bytes — current available memory (gauge, goes up/down)
node_memory_MemTotal_bytes     — total physical RAM (gauge, constant)

Division gives fraction used: 0.72 = 72% used
Multiply by 100 for percentage

No rate() or increase() — gauges are queried directly.
Expected on 8GB Minikube with the full stack: 55–75%
```

### Query 4 — Pod count by namespace (Kubernetes state query)

```promql
count by (namespace) (kube_pod_info)
```

```
kube_pod_info comes from kube-state-metrics — not Node Exporter.
Each row represents one running pod — count groups and counts by namespace.

Expected result:
  {namespace="kube-system"}   7
  {namespace="monitoring"}    6
  {namespace="default"}       0   (no apps deployed yet — changes in Step 9)

This is a capacity planning query:
"How many pods does each namespace consume?"
Track over time to spot namespace growth patterns before hitting quota limits.
```

### Query 5 — HTTP error rate (Golden Signal: Errors)

Run this after generating traffic in Step 9:

```promql
sum(
  rate(http_requests_total{namespace="default", status=~"5.."}[5m])
)
/
sum(
  rate(http_requests_total{namespace="default"}[5m])
)
```

```
Numerator:   rate of HTTP 500-599 (server error) requests
Denominator: rate of all HTTP requests

Result: fraction of requests that are server errors
  0.0  = 0% errors (healthy)
  0.05 = 5% error rate (SLO breach — investigate immediately)

status=~"5.." — regex match for any 5xx status code
=~  means regex match in Prometheus label selectors

This is the Errors golden signal in PromQL.
Set an alert: expr: error_rate > 0.01 for: 2m (99% success SLO)
```

---

## Step 9: Deploy a Test Application with Auto-Discovery

Deploy a realistic test application and observe the complete self-service flow:
application deployed → ServiceMonitor created → Prometheus discovers it automatically.

**Why podinfo?**
`ghcr.io/stefanprodan/podinfo:6.7.1` is a production-quality demo application
maintained by Stefan Prodan (author of Flux, a leading GitOps tool). It ships
pre-instrumented with Prometheus metrics, structured logs, and OpenTelemetry traces.
It is used across CNCF project demos, Flux documentation, and Kubernetes tutorials.
It is not a toy — it represents what a properly instrumented production service looks like.

### Create `src/test-app/deployment.yaml`

```yaml
# src/test-app/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: default
  labels:
    app: test-app
    version: "6.7.1"
spec:
  replicas: 3 # 3 replicas so we can observe per-pod metrics
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
        version: "6.7.1"
    spec:
      containers:
        - name: test-app
          image: ghcr.io/stefanprodan/podinfo:6.7.1
          ports:
            - name: http # HTTP API port
              containerPort: 9898
            - name: http-metrics # Prometheus /metrics port
              containerPort: 9797
            - name: grpc # gRPC port
              containerPort: 9999
          env:
            - name: PODINFO_UI_MESSAGE
              value: "Hello from Observability Demo 01"
            - name: PODINFO_PORT_METRICS # ← this is the only addition
              value: "9797"
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
          # Liveness probe — pod restarts if this fails
          livenessProbe:
            httpGet:
              path: /healthz
              port: 9898
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          # Readiness probe — pod receives traffic only when this passes
          readinessProbe:
            httpGet:
              path: /readyz
              port: 9898
            initialDelaySeconds: 5
            periodSeconds: 10
            successThreshold: 1
```

### Create `src/test-app/service.yaml`

```yaml
# src/test-app/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: test-app
  namespace: default
  labels:
    app: test-app     # ServiceMonitor matches on this label
spec:
  type: ClusterIP
  selector:
    app: test-app
  ports:
    - name: http           # named port — referenced by name in ServiceMonitor
      port: 9898
      targetPort: 9898
    - name: http-metrics   # named port — this is what the ServiceMonitor scrapes
      port: 9797
      targetPort: 9797
```

### Create `src/test-app/servicemonitor.yaml`

```yaml
# src/test-app/servicemonitor.yaml
#
# ServiceMonitor is a CRD installed by the Prometheus Operator.
# When you apply this manifest, the Operator will:
#   1. Find this ServiceMonitor via its cluster-wide watch
#   2. Query the Kubernetes API for Service endpoints matching spec.selector
#   3. Generate a prometheus.yaml scrape_config with the actual pod IPs
#   4. POST to Prometheus /-/reload (no Prometheus restart required)
#   5. Prometheus starts scraping the matched endpoints within 30 seconds
#   6. When pods are replaced with new IPs, the Operator regenerates config
#
# This is the self-service model — no central team, no prometheus.yaml editing.
#
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: test-app
  namespace: default
spec:
  # Select the Service to monitor by matching its labels
  selector:
    matchLabels:
      app: test-app         # matches the Service in service.yaml

  # Where to find /metrics on the matched Service
  endpoints:
    - port: http-metrics    # named port from service.yaml (not port number)
      path: /metrics        # the path Prometheus will GET
      interval: 15s         # how often to scrape
      scrapeTimeout: 10s    # timeout per scrape — must be less than interval

  # Which namespaces to look in for matching Services
  namespaceSelector:
    matchNames:
      - default
```

Deploy:

```bash
kubectl apply -f src/test-app/deployment.yaml
kubectl apply -f src/test-app/service.yaml
kubectl apply -f src/test-app/servicemonitor.yaml

kubectl rollout status deployment/test-app
```

Expected output:
```
deployment.apps/test-app successfully rolled out
```

Verify all 3 pods are running:

```bash
kubectl get pods -l app=test-app
```

Expected:
```
NAME                        READY   STATUS    RESTARTS   AGE
test-app-6d8b4f9c4-abc12    1/1     Running   0          45s
test-app-6d8b4f9c4-def34    1/1     Running   0          45s
test-app-6d8b4f9c4-ghi56    1/1     Running   0          45s
```

**Wait 30–60 seconds**, then check the Prometheus Targets page:

```
http://localhost:9090/targets
```

You should see a new entry auto-discovered:
```
default/test-app/0 (3/3 up)   ← all 3 pod replicas discovered and scraping
```

No prometheus.yaml was edited. No Prometheus was restarted. The Operator did it.

Generate traffic so the test-app metrics have real data:

```bash
# Port-forward to the app HTTP API
kubectl port-forward svc/test-app 8080:9898 &
APP_PF=$!
sleep 2

# Send 200 requests across two endpoints
for i in $(seq 1 100); do
  curl -s http://localhost:8080/api/info > /dev/null
  curl -s http://localhost:8080/version > /dev/null
done

echo "Traffic generated"
kill $APP_PF 2>/dev/null && wait $APP_PF 2>/dev/null
```

Now run the four golden signal queries from Step 8 in Prometheus UI.
You will see real data from the test-app.

---

## Step 10: Simulate CPU Load — Watch Metrics React in Real Time

Use `stress-ng` to generate realistic CPU load and observe Prometheus metrics
responding to the workload in real time.

**About stress-ng:**
`stress-ng` is an open-source Linux stress testing tool maintained by Canonical.
It is used by SRE and DevOps teams for pre-production load testing, instance
sizing validation, and verifying that monitoring alerts fire before an incident.
It is available in all major Linux distribution repositories.
It must only be used in non-production environments — never on live systems.

```bash
# Run a stress pod in the cluster for 5 minutes
kubectl run stress-test \
  --image=ubuntu:24.04 \
  --restart=Never \
  --command -- bash -c \
    "apt-get update -qq && apt-get install -y -qq stress-ng && \
     echo 'Stressing 2 CPUs for 300 seconds...' && \
     stress-ng --cpu 2 --timeout 300s --metrics-brief"
```

Wait for the pod to reach Running state:

```bash
kubectl get pod stress-test -w
# Wait until STATUS = Running, then Ctrl+C
```

Now open the Prometheus UI Graph tab and run:

```promql
100 - (
  avg by (instance) (
    rate(node_cpu_seconds_total{mode="idle"}[1m])
  ) * 100
)
```

Set time range to **Last 15 minutes** and view as **Graph**.

**What you will see:**

```
Timeline:
  Before stress-ng:  CPU busy = 5–15% (baseline cluster overhead)
  During stress-ng:  CPU busy climbs to 60–90% (stress-ng using 2 CPUs)
  After stress-ng:   CPU busy drops back to baseline (clean recovery)

This is the SATURATION golden signal responding to a real workload change.
In a production incident, this spike shape with a sustained plateau is
exactly what CPU saturation from a traffic surge or runaway process looks like.
```

Also watch memory:

```promql
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```

Clean up the stress pod:

```bash
kubectl delete pod stress-test
```

---

## Step 11: Validate Configuration with promtool

`promtool` is the official Prometheus CLI. Use it in CI/CD pipelines to validate
configuration files and rule files before they are applied to production.

```bash
# Get the Prometheus pod name
PROM_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}')

echo "Prometheus pod: $PROM_POD"
```

**Validate the running config:**

```bash
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool check config /etc/prometheus/config_out/prometheus.env.yaml
```

Expected:
```
Checking /etc/prometheus/config_out/prometheus.env.yaml
  SUCCESS: X rule files found
```

**View the auto-generated scrape job for the test-app:**

```bash
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  cat /etc/prometheus/config_out/prometheus.env.yaml \
  | grep -A 12 "job_name: default/test-app"
```

Expected output — generated by the Operator from your ServiceMonitor CRD:
```yaml
- job_name: default/test-app/0
  honor_timestamps: true
  scrape_interval: 15s
  scrape_timeout: 10s
  metrics_path: /metrics
  scheme: http
  kubernetes_sd_configs:
  - role: endpoints
    namespaces:
      names:
      - default
```

**Count total scrape jobs currently configured:**

```bash
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  cat /etc/prometheus/config_out/prometheus.env.yaml \
  | grep "^- job_name:" | wc -l
```

Expected: approximately 12–15 jobs. Every job corresponds to one ServiceMonitor.
None of these were written manually — the Operator generated them all.

**Run TSDB analysis to check cardinality:**

```bash
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool tsdb analyze /prometheus
```

This outputs: block count, compression ratio, top metric names by series count.
Use this weekly in production to catch cardinality problems before they cause OOMKills.

---

## Step 12: The Four Golden Signals — Full PromQL Reference

```
┌───────────────┬──────────────────────────────────────────────────────────────┐
│  Golden Signal│  PromQL Query                                                │
├───────────────┼──────────────────────────────────────────────────────────────┤
│  LATENCY      │  histogram_quantile(                                         │
│  p99 latency  │    0.99,                                                     │
│               │    sum by (le) (                                             │
│               │      rate(                                                   │
│               │        http_request_duration_seconds_bucket{                 │
│               │          job="default/test-app/0"                           │
│               │        }[5m]                                                 │
│               │      )                                                       │
│               │    )                                                         │
│               │  )                                                           │
│               │  → e.g. 0.042 = 42ms p99                                   │
│               │  → Alert: > 0.5 (500ms SLO breach)                          │
├───────────────┼──────────────────────────────────────────────────────────────┤
│  TRAFFIC      │  sum(                                                        │
│  requests/sec │    rate(                                                     │
│               │      http_requests_total{                                    │
│               │        job="default/test-app/0"                             │
│               │      }[5m]                                                   │
│               │    )                                                         │
│               │  )                                                           │
│               │  → e.g. 14.2 = 14.2 requests/second across all pods        │
│               │  → Use for: capacity planning, anomaly detection            │
├───────────────┼──────────────────────────────────────────────────────────────┤
│  ERRORS       │  sum(rate(http_requests_total{                               │
│  error rate   │    job="default/test-app/0", status=~"5.."}[5m]))           │
│               │  /                                                           │
│               │  sum(rate(http_requests_total{                               │
│               │    job="default/test-app/0"}[5m]))                          │
│               │  → e.g. 0.0 = 0% errors, 0.05 = 5% error rate             │
│               │  → Alert: > 0.01 (99% success SLO)                         │
├───────────────┼──────────────────────────────────────────────────────────────┤
│  SATURATION   │  process_resident_memory_bytes{                              │
│  memory %     │    job="default/test-app/0"                                 │
│               │  }                                                           │
│               │  / (64 * 1024 * 1024)                                       │
│               │  → e.g. 0.72 = 72% of 64MB limit used                     │
│               │  → Alert: > 0.85 (OOMKill risk at 85%)                     │
└───────────────┴──────────────────────────────────────────────────────────────┘
```

Run all four in Prometheus Graph tab and switch to Graph view.
In Demo 04 (Grafana Dashboards) these become the foundation of your
first operational dashboard.

---

## Lessons Learned

### The Prometheus Operator Is the Correct Mental Model for Kubernetes

The most important mindset shift from this demo: in Kubernetes, you never edit
`prometheus.yaml` directly. The Operator reads ServiceMonitor CRDs and generates
config automatically. When a service is not being scraped, always look at the
ServiceMonitor and the Operator logs first — not at prometheus.yaml.

```bash
# First step when debugging "my service is not being scraped":

# 1. Does the ServiceMonitor exist?
kubectl get servicemonitor -A

# 2. Is the ServiceMonitor's selector matching the Service?
kubectl describe servicemonitor test-app -n default

# 3. Does the Service have healthy endpoints (pods Ready)?
kubectl get endpoints test-app -n default

# 4. Is the target visible in Prometheus with an error?
# → http://localhost:9090/targets
# Read the error message on the target row

# 5. What is the Operator saying?
kubectl logs -n monitoring \
  -l app.kubernetes.io/name=prometheus-operator \
  --tail=50
```

### rate() Requires a Sufficient Range Window

```
WRONG: rate(http_requests_total[30s])
  scrape_interval = 15s → 30s window has only 2 data points
  rate() needs at least 4 points for statistical reliability
  Result: erratic, unreliable, misleading values

CORRECT: rate(http_requests_total[5m])
  5m window = approximately 20 data points at 15s scrape interval
  Stable, reliable rate calculation

Rule: range window ≥ 4 × scrape_interval
Standard ranges for 15s scrape: [1m], [5m], [15m], [1h]
```

### promtool Must Be Part of Your CI/CD Pipeline

Every Prometheus rule file change should pass through `promtool check rules` before
deployment. This catches invalid PromQL syntax, malformed YAML, duplicate rule names,
and unit test failures. Adding it to a GitHub Actions workflow costs 30 seconds of
CI time and prevents monitoring outages caused by bad alerting rule deploys.

```yaml
# GitHub Actions step example
- name: Validate Prometheus rules
  run: |
    promtool check config prometheus.yaml
    promtool check rules rules/*.yaml
```

### PVCs Are Not Deleted by helm uninstall — Always Clean Them Manually

```bash
# WRONG cleanup (leaves PVCs consuming disk):
helm uninstall kube-prometheus-stack -n monitoring

# CORRECT cleanup:
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete pvc -n monitoring --all    # ← required manually
kubectl delete namespace monitoring
```

Helm preserves PVCs on uninstall by design — it protects your TSDB data during
upgrades. In a demo environment with limited disk, always delete PVCs explicitly.

### Statistic Choice Changes the Story Completely

```
CPUUtilization Average = 45%  →  "looks fine"
CPUUtilization Maximum = 98%  →  "threads were starved, users felt latency"

Memory Average  = 60%  →  "comfortable headroom"
Memory Maximum  = 95%  →  "we were minutes from OOMKill"

Use Average for: capacity planning, trend analysis, cost estimation
Use Maximum for: incident investigation, finding peak saturation
Use p99 for:     SLO alerting, latency SLOs, understanding tail behaviour
```

### Troubleshooting — Port-Forward Connection Refused

```
Error: "error forwarding port 9090: ... connection refused"

Cause 1: Pod is not yet Running
  kubectl get pods -n monitoring → check STATUS column
  kubectl describe pod <pod-name> -n monitoring → check Events section

Cause 2: Wrong service name
  kubectl get svc -n monitoring  → list actual service names
  Chart default: kube-prometheus-stack-prometheus (not "prometheus")

Cause 3: Port already in use locally
  lsof -i :9090  → check what is using port 9090 on your machine
  Fix: kubectl port-forward ... 19090:9090
  Then open http://localhost:19090 instead

Cause 4: Port-forward process died
  Check if the kubectl port-forward process is still running
  ps aux | grep port-forward
  Restart it if gone
```

---

## What You Built

```
monitoring namespace:
  ✅ Prometheus 3.3.1 (StatefulSet, 10Gi PVC, 10d retention, native histograms)
  ✅ Prometheus Operator v0.90.1 (watching all CRDs cluster-wide)
  ✅ Alertmanager 0.28.1 (StatefulSet, 1Gi PVC)
  ✅ Grafana 12.3.0 (Deployment, 1Gi PVC, unified alerting)
  ✅ Node Exporter 1.11.1 (DaemonSet, host metrics from /proc and /sys)
  ✅ kube-state-metrics 2.18.0 (Kubernetes API object state)

default namespace:
  ✅ podinfo 6.7.1 (Deployment, 3 replicas, Prometheus metrics on port 9797)
  ✅ ServiceMonitor CRD (auto-discovered and scraping in < 30 seconds)

Skills demonstrated:
  ✅ Pull model internals — why and when pull vs push
  ✅ TSDB write path — WAL, head block, disk blocks, compaction, retention
  ✅ Four metric types — counter, gauge, histogram, summary with real examples
  ✅ Labels and cardinality — calculation, limits, and production rules
  ✅ Prometheus Operator — CRD-based self-service, zero manual config
  ✅ scrape_interval vs evaluation_interval — two independent clocks
  ✅ ServiceMonitor CRD — auto-discovery of new applications
  ✅ Five PromQL queries — including all four golden signals
  ✅ promtool — config validation and TSDB cardinality analysis
  ✅ Stress testing — watching metrics react to real workload
```

---

## Quick Reference — Commands

| What | Command |
|---|---|
| Install stack | `helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 84.5.0 -n monitoring -f src/values.yaml --wait` |
| Upgrade values | `helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring -f src/values.yaml` |
| All monitoring pods | `kubectl get pods -n monitoring` |
| All ServiceMonitors | `kubectl get servicemonitors -A` |
| Prometheus UI | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` |
| Grafana UI | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` |
| Alertmanager UI | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093` |
| Validate config | `kubectl exec -n monitoring <prom-pod> -c prometheus -- promtool check config /etc/prometheus/config_out/prometheus.env.yaml` |
| Current series count | `prometheus_tsdb_head_series` (run in Prometheus UI) |
| TSDB analysis | `kubectl exec -n monitoring <prom-pod> -c prometheus -- promtool tsdb analyze /prometheus` |
| Operator logs | `kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator --tail=100` |
| Chart default values | `helm show values prometheus-community/kube-prometheus-stack --version 84.5.0` |

---

## Cleanup — Complete Teardown

Run all steps in order. This removes every resource from this demo.
**Run this before shutting down for the night to avoid resource waste.**

```bash
# Step 1: Remove test application and its ServiceMonitor
kubectl delete -f src/test-app/servicemonitor.yaml
kubectl delete -f src/test-app/service.yaml
kubectl delete -f src/test-app/deployment.yaml

# Step 2: Remove stress pod if still running
kubectl delete pod stress-test --ignore-not-found

# Step 3: Uninstall the Helm release
# Removes: pods, services, ServiceMonitors, PrometheusRules, CRDs, RBAC, ConfigMaps
# Does NOT remove: PersistentVolumeClaims (by design — see Lessons Learned)
helm uninstall kube-prometheus-stack -n monitoring

# Step 4: Delete PersistentVolumeClaims manually
# Critical: helm uninstall does not delete PVCs — they survive intentionally
# to protect TSDB data on accidental uninstall. Delete them manually for demos.
kubectl delete pvc -n monitoring --all

# Step 5: Delete the monitoring namespace and any remaining resources
kubectl delete namespace monitoring

# Step 6: Verify everything is removed
echo "--- Remaining pods ---"
kubectl get pods -n monitoring 2>&1

echo "--- Remaining PVCs ---"
kubectl get pvc -n monitoring 2>&1

echo "--- Remaining ServiceMonitors ---"
kubectl get servicemonitors -A 2>&1 | grep -v "No resources found" || echo "None"

# Step 7: Stop Minikube (preserves cluster state on disk — fast restart next time)
minikube stop

# Optional Step 8: Delete Minikube cluster entirely (frees all disk space)
# Do this if you are done with the project or want a completely clean start
# minikube delete
```

**Expected final output:**
```
release "kube-prometheus-stack" uninstalled
persistentvolumeclaim "prometheus-..." deleted
persistentvolumeclaim "alertmanager-..." deleted
namespace "monitoring" deleted
--- Remaining pods ---
No resources found in monitoring namespace.
--- Remaining PVCs ---
No resources found in monitoring namespace.
--- Remaining ServiceMonitors ---
None
✋  Stopping node "minikube"  ...
🛑  1 node stopped.
```

---

## What's Next

**Demo 02 — PromQL: From Selectors to Production-Grade Queries**

Prometheus is running, scraping targets, and storing real data. Demo 02 goes
deep on PromQL — the query language you will use every working day as an SRE.
Topics: instant vs range vectors in depth, rate() vs irate() vs increase() and
when each is correct, all aggregation operators with real examples, binary operations
for ratio queries, the `offset` modifier for week-over-week comparisons,
subqueries for alerting on trends, and recording rules that pre-compute expensive
queries for dashboard performance.

---

## References

| Resource | URL |
|---|---|
| Prometheus 3.x Documentation | https://prometheus.io/docs/prometheus/3.3/ |
| kube-prometheus-stack Helm Chart | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack |
| Prometheus Operator API Reference | https://prometheus-operator.dev/docs/api-reference/api/ |
| ArtifactHub — chart versions | https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack |
| Prometheus Data Model | https://prometheus.io/docs/concepts/data_model/ |
| Prometheus Metric Types | https://prometheus.io/docs/concepts/metric_types/ |
| Prometheus TSDB internals | https://ganeshvernekar.com/blog/prometheus-tsdb-the-head-block/ |
| Google SRE Book — Monitoring Distributed Systems | https://sre.google/sre-book/monitoring-distributed-systems/ |
| Google SRE Book — Being On Call | https://sre.google/sre-book/being-on-call/ |
| podinfo source code | https://github.com/stefanprodan/podinfo |
| promtool CLI reference | https://prometheus.io/docs/prometheus/latest/command-line/promtool/ |
| Node Exporter collectors list | https://github.com/prometheus/node_exporter#collectors |
| Prometheus Native Histograms | https://prometheus.io/docs/prometheus/latest/feature_flags/#native-histograms |