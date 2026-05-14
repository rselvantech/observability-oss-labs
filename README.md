# opensource-observability-labs
 LGTM+ Demos  with Prometheus at the core.

# opensource-observability-labs

Hands-on, progressive demo series for building and operating a production-grade
open-source observability platform from beginner to advanced level.

Every demo is a self-contained, fully working lab with real scenarios,
real tools at pinned stable versions, and complete teardown instructions.
No cloud spend required for the first 20 demos — everything runs on Minikube.

---

## Who This Is For

Platform engineers, DevOps engineers, and SREs who want to build real,
hands-on skills with the open-source observability stack that the industry
has standardised on. Each demo is designed to give you the depth required
for production work and technical interviews — not just enough to run a
hello-world and move on.

**Assumed knowledge:** Basic Kubernetes (pods, deployments, services, Helm),
basic Docker, and comfort with the command line. AWS knowledge is helpful for
Phase 3 demos but not required for Phases 1 and 2.

---

## The Stack — What We Use and Why

The stack in this series is the **LGTM+ stack**:
**L**oki · **G**rafana · **T**empo · **M**imir, with Prometheus and Grafana Alloy
as the collection and alerting foundation, and Pyroscope for continuous profiling.

Every component was selected against the same framework. The sections below
document the selection reasoning so you understand not just what we use,
but why — and what the alternatives looked like.

---

## How We Evaluated the Stack — The Selection Framework

Before choosing any component, we applied five questions consistently.
This is the same framework a platform team should apply before adopting
any open-source infrastructure tool in a production environment.

```
Question 1 — Maintainer health
  How many active maintainers from how many organisations?
  Single-maintainer or single-company projects carry high bus-factor risk.
  Target: 5+ active maintainers from 2+ organisations.

Question 2 — Commercial backing
  Is there a company with a direct financial interest in keeping it secure,
  performant, and up to date? Open source without commercial backing relies
  entirely on volunteer time, which can dry up.

Question 3 — Attack surface and security posture
  What does the component have access to? Does it handle external traffic?
  Does it have cluster-wide API permissions?
  Does it have a formal CVE disclosure process?

Question 4 — Formal governance and standards alignment
  Is it a CNCF project? Does it follow open standards (OTel, OpenMetrics)?
  Does it have a clear roadmap and backward-compatibility commitment?

Question 5 — Exit strategy
  If this project stalled or was abandoned tomorrow, what would you do?
  Is there a migration path, a fork, or a compatible replacement?
```

---

## The LGTM+ Stack — Component by Component

### Prometheus — Metrics Collection and Alerting

**What it does:** Pulls metrics from every component in your system every 15
seconds, stores them in a local time-series database, and evaluates alerting
and recording rules.

**Why we chose it:** Prometheus is a CNCF Graduated project — the second ever
to graduate after Kubernetes. It is the de facto standard for Kubernetes metrics.
Every cloud provider, every managed Kubernetes service, and every SRE job posting
assumes Prometheus knowledge. There is no credible alternative in the
Kubernetes-native metrics space.

**Alternatives considered:**

```
┌──────────────────┬────────────────────────────────────────────────────────┐
│  Victoria Metrics│ Drop-in Prometheus replacement, more efficient storage │
│                  │ Good for very high cardinality at reduced RAM cost      │
│                  │ Not chosen: PromQL compatibility is close but not exact │
│                  │ Prometheus is the canonical baseline to learn first     │
├──────────────────┼────────────────────────────────────────────────────────┤
│  InfluxDB        │ Metrics + logs in one system                           │
│                  │ Not chosen: different query language (Flux), not       │
│                  │ Kubernetes-native, declining adoption vs Prometheus     │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Datadog Agent   │ Excellent managed metrics — zero ops overhead          │
│                  │ Not chosen: proprietary, $3–6/host/month at scale,     │
│                  │ vendor lock-in, not open source                        │
└──────────────────┴────────────────────────────────────────────────────────┘
```

**Framework evaluation:**
- Maintainer health ✅ — 1,000+ contributors, Google, Red Hat, Spotify, Apple
- Commercial backing ✅ — CNCF Graduated, Grafana Labs, Red Hat actively contribute
- Security posture ✅ — CNCF security audit, formal CVE process (security@prometheus.io)
- Governance ✅ — CNCF Graduated (August 2018), Apache 2.0
- Exit strategy ✅ — largest metrics ecosystem in the world, no credible need for exit

**Detailed coverage:** Demo 01 and Demo 02

---

### Grafana — Visualisation, Dashboards, and Alerting UI

**What it does:** Connects to Prometheus, Loki, Tempo, and other data sources,
renders dashboards with time-series panels, stat panels, tables, and heatmaps,
and provides a unified alerting UI across all signals.

**Why we chose it:** Grafana is the universal visualisation layer for observability.
It supports 100+ data source plugins, has the largest dashboard community
(grafana.com/dashboards hosts thousands of community dashboards), and is
the front-end for the entire LGTM stack. Grafana Labs has raised over $500 million in venture capital funding, reaching a $6 billion valuation in 2024, which demonstrates the commercial sustainability behind continued OSS investment.

**Alternatives considered:**

```
┌──────────────────┬────────────────────────────────────────────────────────┐
│  Kibana          │ The original full-stack visualisation for ELK          │
│                  │ Not chosen: tightly coupled to Elasticsearch,          │
│                  │ limited Prometheus/Loki/Tempo native support           │
│                  │ SSPL licence restricts some production use cases       │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Datadog UI      │ Polished, fast, excellent UX                           │
│                  │ Not chosen: proprietary SaaS only, not self-hostable,  │
│                  │ expensive at scale                                     │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Perses          │ CNCF Incubating — the emerging open standard dashboard │
│                  │ Not chosen yet: too early for production adoption,     │
│                  │ watch for Demo series update when it matures           │
└──────────────────┴────────────────────────────────────────────────────────┘
```

**Framework evaluation:**
- Maintainer health ✅ — Grafana Labs (800+ engineers), massive OSS community
- Commercial backing ✅ — $791M raised, 5,000+ enterprise customers, sustainable model
- Security posture ⚠️ — AGPLv3 (changed from Apache 2.0 in 2021), periodic CVEs in web UI
  — mitigate: pin versions, enable auth, monitor security advisories
- Governance ✅ — Grafana Labs owned, AGPLv3, clear enterprise/OSS split
- Exit strategy ✅ — 20M users, plugin ecosystem, community dashboards — no realistic exit needed

**Detailed coverage:** Demo 04

---

### Grafana Loki — Log Aggregation

**What it does:** Stores and queries application and infrastructure logs.
Uses a label-based index (like Prometheus) rather than full-text indexing,
making it far cheaper to operate at scale than Elasticsearch.

**Why we chose it:** Loki is purpose-built to work alongside Prometheus.
It shares Grafana as its query UI, its label model maps directly to Prometheus
labels (enabling seamless log-to-metric correlation), and it requires only
cheap object storage (S3/MinIO) — no Elasticsearch cluster to operate.

**Alternatives considered:**

```
┌──────────────────┬────────────────────────────────────────────────────────┐
│  Elasticsearch / │ Industry standard full-text search                    │
│  OpenSearch      │ Not chosen: expensive to operate (memory-heavy),      │
│                  │ complex cluster management, no native Prometheus       │
│                  │ integration, query language (KQL/ES-SQL) is separate   │
│                  │ from PromQL — more to learn for the same signal        │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Splunk          │ Enterprise log analytics — very powerful               │
│                  │ Not chosen: proprietary, expensive per-GB pricing,     │
│                  │ SPL query language not transferable to other tools     │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Fluentd / Fluent│ Collection agent — not a storage backend               │
│  Bit             │ Used alongside Loki for collection, not as replacement │
└──────────────────┴────────────────────────────────────────────────────────┘
```

**Framework evaluation:**
- Maintainer health ✅ — Grafana Labs primary maintainer, active OSS community
- Commercial backing ✅ — core part of Grafana Cloud product, direct revenue link
- Security posture ✅ — AGPLv3, multi-tenant isolation tested at Grafana Cloud scale
- Governance ✅ — Grafana Labs owned, clear roadmap
- Exit strategy ✅ — OpenTelemetry log format compatibility, Alloy can route to other backends

**Detailed coverage:** Demo 05, Demo 06, Demo 15, Demo 21

---

### Grafana Alloy — Telemetry Collection Agent

**What it does:** Collects metrics, logs, traces, and profiles from
Kubernetes pods, the host OS, and applications. Replaces Promtail (EOL
March 2026) and Grafana Agent (deprecated November 2025). Acts as an
OpenTelemetry Collector distribution with Grafana-native pipelines.

**Why we chose it:** Alloy is the current and future standard for telemetry
collection in the Grafana ecosystem. Starting with Alloy means learning
the tool that will be relevant in 3–5 years, not one being phased out.
Its OTel compatibility means data is not locked into Grafana — you can
route to any OTel-compatible backend.

**Alternatives considered:**

```
┌──────────────────┬────────────────────────────────────────────────────────┐
│  Promtail        │ Predecessor to Alloy — Loki-only log collector         │
│                  │ Not chosen: EOL March 2026, replaced by Alloy          │
│                  │ Learning it now means relearning Alloy in months       │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Grafana Agent   │ Predecessor to Alloy — deprecated November 2025        │
│                  │ Not chosen: same reason as Promtail                    │
├──────────────────┼────────────────────────────────────────────────────────┤
│  OTel Collector  │ The CNCF reference implementation                      │
│  (upstream)      │ Alloy IS an OTel Collector distribution — it wraps the │
│                  │ upstream collector and adds Grafana-native components   │
│                  │ Learning Alloy = learning OTel Collector principles    │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Fluentd /       │ Mature, widely deployed log collectors                 │
│  Fluent Bit      │ Good collectors but single-signal (logs only)          │
│                  │ Alloy handles all four signals in one agent            │
└──────────────────┴────────────────────────────────────────────────────────┘
```

**Framework evaluation:**
- Maintainer health ✅ — Grafana Labs primary maintainer
- Commercial backing ✅ — core part of Grafana Cloud product
- Security posture ✅ — AGPLv3, vendor-neutral OTel compatibility reduces lock-in
- Governance ✅ — Grafana Labs owned, clear migration path from Promtail
- Exit strategy ✅ — OTel compatible, config can be adapted to upstream OTel Collector

**Detailed coverage:** Demo 05, Demo 09, Demo 16

---

### Grafana Tempo — Distributed Tracing

**What it does:** Stores distributed traces and provides TraceQL for querying
them. Requires only object storage (S3/MinIO) — no Cassandra or Elasticsearch.
Automatically generates service graphs and RED metrics from trace data.

**Why we chose it over Jaeger:**

```
┌──────────────────┬──────────────┬──────────────────────────────────────────┐
│  Criterion       │  Jaeger       │  Grafana Tempo                           │
├──────────────────┼──────────────┼──────────────────────────────────────────┤
│  Status (2025)   │ v1 deprecated │ Actively developed                       │
│                  │ v2 rebuilding │                                           │
├──────────────────┼──────────────┼──────────────────────────────────────────┤
│  Storage backend │ Elasticsearch │ Object storage only (S3/MinIO)           │
│                  │ Cassandra     │ No index — very cheap at scale            │
├──────────────────┼──────────────┼──────────────────────────────────────────┤
│  Grafana native  │ Plugin only   │ First-class, native integration           │
├──────────────────┼──────────────┼──────────────────────────────────────────┤
│  RED metrics     │ No            │ Yes — auto-generated from traces          │
├──────────────────┼──────────────┼──────────────────────────────────────────┤
│  Service graph   │ Yes           │ Yes — auto-generated                      │
├──────────────────┼──────────────┼──────────────────────────────────────────┤
│  Query language  │ No — UI only  │ TraceQL — purpose-built for traces        │
├──────────────────┼──────────────┼──────────────────────────────────────────┤
│  Instrumentation │ Own SDKs      │ OTel only — standard, vendor-neutral      │
└──────────────────┴──────────────┴──────────────────────────────────────────┘
```

**Framework evaluation:**
- Maintainer health ✅ — Grafana Labs primary maintainer, active OSS community
- Commercial backing ✅ — core Grafana Cloud product
- Security posture ✅ — AGPLv3, object storage backend reduces attack surface
- Governance ✅ — Grafana Labs owned, clear roadmap
- Exit strategy ✅ — OTel OTLP input — trace data is not locked in Tempo format

**Detailed coverage:** Demo 09, Demo 10

---

### Grafana Mimir — Long-Term Metrics Storage

**What it does:** Horizontally scalable, multi-tenant Prometheus-compatible
metrics backend. Prometheus remote_writes to Mimir. Stores metric blocks on
S3. Scales to billions of active series. Replaces local Prometheus TSDB for
long-term retention.

**Origin:** Mimir combines the best of what was built in Cortex with features developed to run Grafana Enterprise Metrics and Grafana Cloud at massive scale, all under the AGPLv3 license. Cortex was the predecessor CNCF project; Mimir is the production-grade fork maintained by Grafana Labs.

**Why we use it for Phase 3:** Local Prometheus TSDB is limited to one node
and 15–30 days of retention. Mimir provides unlimited retention with S3 costs,
HA via replication, and multi-tenancy for multiple teams on one platform.

**Alternatives considered:**

```
┌──────────────────┬────────────────────────────────────────────────────────┐
│  Cortex          │ CNCF Incubating — Mimir's predecessor                  │
│                  │ Not chosen: Grafana Labs commits are now on Mimir,     │
│                  │ Mimir is the actively developed fork                   │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Thanos          │ CNCF Incubating — sidecar model for HA Prometheus      │
│                  │ Valid alternative — different architecture (sidecar    │
│                  │ vs remote_write), more complex to operate              │
│                  │ Mimir's simpler remote_write model is preferred here   │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Victoria Metrics│ Single-binary alternative, very efficient              │
│  Cluster         │ Not chosen: different ecosystem, less native Grafana   │
│                  │ integration than Mimir                                 │
└──────────────────┴────────────────────────────────────────────────────────┘
```

**Framework evaluation:**
- Maintainer health ✅ — Grafana Labs primary maintainer
- Commercial backing ✅ — underpins Grafana Cloud metrics product
- Security posture ✅ — AGPLv3, multi-tenant isolation at production scale
- Governance ✅ — Grafana Labs owned, clear Cortex → Mimir migration path
- Exit strategy ✅ — standard Prometheus remote_write protocol, S3-standard storage

**Detailed coverage:** Demo 22

---

### Grafana Pyroscope — Continuous Profiling

**What it does:** Collects CPU and memory profiles from running applications
continuously in production. Stores profiles on object storage. Enables
flame graph visualisation and correlation with metrics, logs, and traces
in Grafana. The fourth observability signal — alongside metrics, logs, traces.

**Origin:** Pyroscope was an independent open-source project (co-founded by
Ryan Perry) before Grafana Labs acquired Pyroscope in 2023. It was merged with
Grafana Phlare (Grafana Labs' own profiling project) into one codebase.

**Why continuous profiling matters:** Metrics tell you a service is slow.
Traces tell you which request path is slow. Profiles tell you which function
in which line of code is consuming CPU or allocating memory. It is the
final drill-down from symptom to code-level root cause.

**Alternatives considered:**

```
┌──────────────────┬────────────────────────────────────────────────────────┐
│  pprof (Go)      │ Built-in Go profiler — pull mode                      │
│                  │ Pyroscope can collect pprof endpoints — complementary  │
│                  │ not competing                                           │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Elastic APM     │ Includes profiling as part of full APM suite           │
│                  │ Not chosen: Elasticsearch dependency, not LGTM-native  │
├──────────────────┼────────────────────────────────────────────────────────┤
│  Datadog Profiler│ Excellent managed continuous profiling                 │
│                  │ Not chosen: proprietary, part of Datadog platform      │
└──────────────────┴────────────────────────────────────────────────────────┘
```

**Framework evaluation:**
- Maintainer health ✅ — Grafana Labs primary maintainer post-acquisition
- Commercial backing ✅ — part of Grafana Cloud product suite
- Security posture ✅ — AGPLv3, eBPF profiling is read-only observation
- Governance ✅ — Grafana Labs owned
- Exit strategy ✅ — pprof and eBPF are open standards, data portable via OTel

**Detailed coverage:** Demo 23

---

## Why Not a Managed SaaS Platform?

The most common alternative to building this stack is using a managed
commercial observability platform — Datadog, Dynatrace, or New Relic.
Here is an honest comparison of the trade-offs:

```
┌────────────────────────┬───────────────────────────┬────────────────────────┐
│  Criterion             │  LGTM+ Stack (this series) │  Managed SaaS          │
│                        │  Grafana / Prometheus       │  Datadog / Dynatrace   │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Time to first value   │  Hours to days             │  Minutes to hours      │
│                        │  (setup + config required) │  (agent install → done) │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Cost at small scale   │  Free (infra only)         │  $15–35/host/month     │
│  (< 20 hosts)          │                            │                        │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Cost at large scale   │  Controlled by you         │  $100k–$500k+/year     │
│  (500+ hosts)          │  S3 + compute only         │  for large deployments │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Data sovereignty      │  Full — data stays on your │  Data sent to vendor   │
│                        │  infrastructure            │  cloud (GDPR concern)  │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Vendor lock-in        │  None — OTel standard      │  High — proprietary    │
│                        │  data stays portable       │  agents and formats    │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Operational overhead  │  High — you manage the     │  Low — vendor manages  │
│                        │  stack, upgrades, scaling  │  infrastructure        │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Customisation         │  Complete                  │  Limited to vendor UI  │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Skills transferability│  High — PromQL, LogQL,     │  Low — proprietary     │
│                        │  OTel are open standards   │  query languages       │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Regulated industries  │  Best — data never leaves │  Risk — data residency │
│  (finance, healthcare) │  your environment          │  requirements may fail │
├────────────────────────┼───────────────────────────┼────────────────────────┤
│  Job market value      │  Very high — open source   │  Vendor-specific,      │
│                        │  skills transfer across    │  less transferable     │
│                        │  every organisation        │                        │
└────────────────────────┴───────────────────────────┴────────────────────────┘

When managed SaaS is the right choice:
  Small team, no dedicated platform engineers, speed matters more than cost
  Organisation is not in a regulated industry with data residency requirements
  Budget is available and operational simplicity is the priority

When the LGTM+ stack is the right choice (this series):
  Team has DevOps/SRE capacity to manage the platform
  Data sovereignty is required (regulated industry, air-gapped environment)
  Cost control at scale is important
  Organisation values open standards and portability
  Engineers want transferable skills across the industry
```

---

## The 25-Demo Roadmap

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Phase 1 — Beginner (Demos 01–10) · All Minikube                            │
├────┬──────────────────────────────────────────────────────────────────────── ┤
│ 01 │ Prometheus — architecture, data model, first scrape                     │
│ 02 │ PromQL — from selectors to production-grade queries                     │
│ 03 │ Exporters — Node Exporter, kube-state-metrics, Pushgateway              │
│ 04 │ Grafana — dashboards, panels, variables, provisioning                   │
│ 05 │ Loki + Alloy — architecture and log collection                          │
│ 06 │ LogQL — filtering, parsing, and metric queries from logs                │
│ 07 │ Alerting — Prometheus rules and Alertmanager routing                    │
│ 08 │ Alertmanager — inhibition, silences, deduplication, amtool              │
│ 09 │ Distributed tracing — OTel SDK instrumentation and OTLP pipeline        │
│ 10 │ Grafana Tempo — TraceQL, service graph, RED metrics                     │
├────┼───────────────────────────────────────────────────────────────────────  ┤
│  Phase 2 — Intermediate (Demos 11–20) · All Minikube                        │
├────┼───────────────────────────────────────────────────────────────────────  ┤
│ 11 │ Prometheus Operator — ServiceMonitor, PodMonitor, PrometheusRule CRDs   │
│ 12 │ Custom app instrumentation — Prometheus client libraries                │
│ 13 │ Grafana Alerting — unified alerting, contact points, policies           │
│ 14 │ Grafana Explore — multi-signal correlation across metrics, logs, traces │
│ 15 │ Loki advanced — label strategy, structured metadata, Alloy pipelines    │
│ 16 │ OTel Collector pipelines — receivers, processors, exporters, sampling   │
│ 17 │ Kubernetes workload monitoring — HPA, resource quotas, capacity         │
│ 18 │ SLOs and error budgets — Google SRE burn-rate alerting method           │
│ 19 │ Synthetic monitoring — Blackbox Exporter and endpoint probing           │
│ 20 │ Grafana OnCall — schedules, escalations, incident workflow              │
├────┼───────────────────────────────────────────────────────────────────────  ┤
│  Phase 3 — Advanced (Demos 21–25) · Minikube + MinIO, EKS for Demos 24–25  │
├────┼───────────────────────────────────────────────────────────────────────  ┤
│ 21 │ Loki at scale — Simple Scalable mode, S3/MinIO, compactor               │
│ 22 │ Grafana Mimir — long-term metrics, remote_write, multi-tenancy          │
│ 23 │ Pyroscope — continuous profiling and flame graphs                       │
│ 24 │ Full LGTM+ platform — HA, multi-tenant, GitOps-managed                  │
│ 25 │ Real incident simulation — detect, correlate, RCA, post-mortem          │
└────┴───────────────────────────────────────────────────────────────────────  ┘
```

---

## Demo Index

| Demo | Title | Phase | Platform | Key Tools |
|---|---|---|---|---|
| [01](./01-prometheus-fundamentals/) | Prometheus architecture & first scrape | Beginner | Minikube | kube-prometheus-stack |
| [02](./02-promql/) | PromQL — selectors to production queries | Beginner | Minikube | Prometheus, promtool |
| 03 | Exporters | Beginner | Minikube | Node Exporter, kube-state-metrics |
| 04 | Grafana dashboards | Beginner | Minikube | Grafana 11 |
| 05 | Loki + Alloy log collection | Beginner | Minikube | Loki, Alloy |
| 06 | LogQL | Beginner | Minikube | Loki |
| 07 | Alerting rules + Alertmanager routing | Beginner | Minikube | Alertmanager |
| 08 | Alertmanager advanced | Beginner | Minikube | Alertmanager, amtool |
| 09 | OTel instrumentation + OTLP | Beginner | Minikube | OTel SDK, Alloy |
| 10 | Tempo + TraceQL | Beginner | Minikube | Tempo, TraceQL |
| 11 | Prometheus Operator CRDs | Intermediate | Minikube | Prometheus Operator |
| 12 | Custom instrumentation | Intermediate | Minikube | Python/Go client libs |
| 13 | Grafana unified alerting | Intermediate | Minikube | Grafana 11 |
| 14 | Multi-signal correlation | Intermediate | Minikube | Grafana Explore |
| 15 | Loki label strategy + Alloy pipelines | Intermediate | Minikube | Loki 3.x, Alloy |
| 16 | OTel Collector pipelines | Intermediate | Minikube | OTel Collector, Alloy |
| 17 | Kubernetes workload monitoring | Intermediate | Minikube | kube-state-metrics |
| 18 | SLOs and error budgets | Intermediate | Minikube | Pyrra/Sloth |
| 19 | Synthetic monitoring | Intermediate | Minikube | Blackbox Exporter |
| 20 | Grafana OnCall | Intermediate | Minikube | OnCall |
| 21 | Loki at scale | Advanced | Minikube + MinIO | Loki Simple Scalable |
| 22 | Grafana Mimir | Advanced | Minikube + MinIO | Mimir |
| 23 | Pyroscope profiling | Advanced | Minikube | Pyroscope |
| 24 | Full LGTM+ platform | Advanced | EKS + S3 | Full stack |
| 25 | Incident simulation | Advanced | EKS | Full stack |

---

## Repository Structure

```
opensource-observability-labs/
├── README.md                                    ← this file
├── 01-prometheus-fundamentals/
│   ├── README.md                                ← Demo 01: hands-on lab
│   ├── STACK-GUIDE.md                           ← kube-prometheus-stack deep reference
│   └── src/
│       ├── values.yaml
│       └── test-app/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── servicemonitor.yaml
├── 02-promql/
│   ├── README.md
│   └── src/
│       └── recording-rules/
│           ├── test-app-rules.yaml
│           └── node-rules.yaml
└── ... (03 through 25 added as demos are built)
```

---

## How to Use This Series

**Starting from scratch:**
Follow the demos in order, Demo 01 through 25. Each demo builds on the
previous one — the test application and monitoring stack from Demo 01
is used throughout Phases 1 and 2.

**Starting from a specific component:**
Each demo is self-contained with a prerequisites section. Jump to any demo
and follow the prerequisite steps to get to a valid starting state.

**GitHub repo setup:**
```bash
git clone https://github.com/<your-username>/opensource-observability-labs.git
cd opensource-observability-labs
```

**Tools required (all demos):**
```bash
# Verify all tools are installed
minikube version    # v1.35.0+
kubectl version --client --short
helm version --short
```

---

## Related Projects

| Repository | Content |
|---|---|
| [kubernetes](https://github.com/rselvantech/kubernetes) | Kubernetes fundamentals — demos from beginner to advanced |
| [gitops-labs](https://github.com/rselvantech/gitops-labs) | GitOps with ArgoCD and Flux |
| [aws-monitoring-observability](https://github.com/rselvantech/aws-monitoring-observability) | AWS-native observability — CloudWatch, ADOT, Container Insights |

The AWS observability project picks up where Demo 20 of this series ends —
it assumes familiarity with the LGTM+ stack and layers AWS-managed services
(CloudWatch, X-Ray, Container Insights) on top of the open-source foundation.

---

## References

| Resource | URL |
|---|---|
| Prometheus documentation | https://prometheus.io/docs/prometheus/3.3/ |
| Grafana documentation | https://grafana.com/docs/grafana/latest/ |
| Grafana Loki documentation | https://grafana.com/docs/loki/latest/ |
| Grafana Alloy documentation | https://grafana.com/docs/alloy/latest/ |
| Grafana Tempo documentation | https://grafana.com/docs/tempo/latest/ |
| Grafana Mimir documentation | https://grafana.com/docs/mimir/latest/ |
| Grafana Pyroscope documentation | https://grafana.com/docs/pyroscope/latest/ |
| OpenTelemetry specification | https://opentelemetry.io/docs/ |
| Google SRE Book | https://sre.google/sre-book/table-of-contents/ |
| Google SRE Workbook | https://sre.google/workbook/table-of-contents/ |
| CNCF landscape | https://landscape.cncf.io/ |
| kube-prometheus-stack ArtifactHub | https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack |