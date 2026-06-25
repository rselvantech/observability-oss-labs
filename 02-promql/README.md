# Demo 02: PromQL — From Selectors to Production-Grade Queries

## Overview

Prometheus stores data. PromQL is how you talk to it.

Every alert that fires, every Grafana panel that renders, every SLO calculation,
every capacity planning decision — all of them are PromQL expressions under the
hood. PromQL is not optional knowledge for someone working in the Kubernetes
observability space. It is the query language you will write every working day.

This demo goes deep on PromQL — not just the syntax, but the mental model behind
it. You will learn why PromQL works the way it does, what mistakes engineers
routinely make with it, and how to write queries that work correctly at
production scale.

**Real-world scenario:**
The platform team has Prometheus running (Demo 01). The head of engineering has
asked for three things by end of week: a dashboard showing the four golden signals
for the order-processing API, an alert that fires when error rate exceeds 1% for
more than 2 minutes, and a weekly report showing request volume trends.
All three require PromQL. This demo gives you the skills to build them.

**What this demo covers:**

- Instant vectors vs range vectors — the foundational mental model of PromQL
- All label matching operators: `=`, `!=`, `=~`, `!~` with regex syntax
- `rate()` vs `irate()` vs `increase()` — when to use each, and the exact maths
- All aggregation operators: `sum`, `avg`, `min`, `max`, `count`, `topk`,
  `bottomk`, `quantile` — with `by()` and `without()`
- Binary operations — arithmetic, comparison, and logical operators
- Vector matching — `on()`, `ignoring()`, `group_left()`, `group_right()`
- The `offset` modifier — comparing current vs historical values
- The `@` modifier — pinning queries to a specific timestamp
- Subqueries — computing rates over rates, and max of a rate over time
- `predict_linear()` — proactive capacity alerting
- `histogram_quantile()` — correct p50/p90/p99 calculations
- Recording rules — pre-computing expensive queries for dashboard performance
- Recording rule naming convention — the official Prometheus standard
- PromQL query performance — what makes a query slow and how to fix it
- `promtool` — validating recording rules in CI/CD

---

## Prerequisites

> **Foundation Reading — Demo 00:**
> Before proceeding with this hands-on lab, read the
> [Kube-Prometheus-Stack-Guide (Demo 00)](../01-prometheus-fundamentals/Kube-Prometheus-Stack-Guide.md).
> It covers: the Prometheus and Grafana product families, why kube-prometheus-stack
> exists, security posture, component internals, CRDs, RBAC, HA patterns, and CLI tools.

**Demo 01 must be complete.** This demo requires:
- `kube-prometheus-stack` v84.5.0 running in the `monitoring` namespace
- `test-app` (podinfo v6.7.1) running in the `default` namespace with its ServiceMonitor
- Prometheus UI accessible at `http://localhost:9090`

If you tore down Demo 01, re-run Steps 1–9 from Demo 01 README before proceeding.

**Versions used in this demo:**

| Component | Version | Notes |
|---|---|---|
| kube-prometheus-stack | **84.5.0** | Inherited from Demo 01 installation |
| Prometheus | **3.4.1** | Bundled — `prom/prometheus:v3.4.1` |
| podinfo (test-app) | **6.7.1** | `ghcr.io/stefanprodan/podinfo:6.7.1` |

**Verify the environment:**

```bash
# All monitoring pods running
kubectl get pods -n monitoring

# test-app running (3 replicas)
kubectl get pods -l app=test-app

# Prometheus port-forward active
kubectl port-forward -n monitoring \
  svc/kube-prometheus-stack-prometheus 9090:9090 &
```

**Generate baseline traffic before starting queries:**

```bash
kubectl port-forward svc/test-app 8080:9898 &
APP_PF=$!
sleep 2

# Send varied traffic — mix of success, 4xx, and a few 5xx
for i in $(seq 1 200); do
  curl -s http://localhost:8080/api/info > /dev/null        # 200 OK
  curl -s http://localhost:8080/version > /dev/null         # 200 OK
  curl -s http://localhost:8080/api/echo > /dev/null        # 200 OK
done

# Trigger some delays and errors
curl -s "http://localhost:8080/delay/1" > /dev/null         # slow request
curl -s "http://localhost:8080/status/500" > /dev/null      # 500 error

echo "Traffic generated"
kill $APP_PF 2>/dev/null && wait $APP_PF 2>/dev/null
```

> **Wait at least 2 minutes** after generating traffic before running PromQL
> queries. rate() needs at least 4 data points (4 × 15s = 60s) in its range
> window to produce stable results.

---

## Demo Objectives

By the end of this demo you will be able to:

1. ✅ Explain the difference between instant vectors and range vectors precisely
2. ✅ Use all four label matching operators including correct RE2 regex syntax
3. ✅ Choose between `rate()`, `irate()`, and `increase()` correctly for any situation
4. ✅ Apply all aggregation operators with `by()` and `without()` clauses
5. ✅ Write binary operation queries for ratio calculations (error rate, saturation %)
6. ✅ Use `offset` to compare current metrics against historical baselines
7. ✅ Write subqueries to compute trends over time
8. ✅ Use `predict_linear()` for proactive disk and memory alerting
9. ✅ Calculate p50, p90, p99 latency correctly with `histogram_quantile()`
10. ✅ Write recording rules following the official Prometheus naming convention
11. ✅ Explain why recording rules improve dashboard performance
12. ✅ Validate recording rules with `promtool check rules`

---

## Directory Structure

```
02-promql/
├── README.md                               # this file
├── create_files.sh                         # extracts embedded Anki CSV and Quiz MD
└── src/
    ├── 02-promql-anki.csv                  # Anki flash cards (embedded in README Appendix)
    ├── 02-promql-quiz.md                   # Quiz (embedded in README Appendix)
    └── recording-rules/
        ├── test-app-rules.yaml             # PrometheusRule CRD with recording rules
        └── node-rules.yaml                 # PrometheusRule CRD for node metrics
```

---

## Recall Check — Demo 01

Answer from memory before reading further. These questions draw on
[Demo 01 — Prometheus Architecture, Data Model & First Scrape](../01-prometheus-fundamentals/README.md).

1. A developer deploys a new microservice and creates a ServiceMonitor CRD in the `payments` namespace. After 10 minutes the service does not appear in Prometheus Targets. The Operator logs show it selected and reloaded the config. Walk through every remaining diagnostic check and what each one would tell you.

2. You are writing your first alerting rule and your colleague says "use `irate()` — it's more accurate because it uses the latest data." What is wrong with this advice, and what is the correct function and range window for an alert that should fire when error rate exceeds 1% for 2 continuous minutes?

3. You run `promtool tsdb analyze /prometheus` on a production cluster and see `Total Series: 1,400,000` with the top metric being `http_requests_total` at `890,000 series`. The Prometheus pod is at 14 GB RAM and climbing. What is the root cause, how do you confirm it, and what is the immediate mitigation?

<details>
<summary>Answers</summary>

1. The Operator selected and reloaded — so the ServiceMonitor exists and was processed. Remaining checks: (1) `serviceMonitorSelectorNilUsesHelmValues` — if `true`, Prometheus only discovers ServiceMonitors labelled `release: kube-prometheus-stack`; the ServiceMonitor is silently rejected at the Prometheus selector level despite the Operator processing it. Check with `helm get values kube-prometheus-stack -n monitoring | grep serviceMonitorSelector`. (2) Prometheus Service Discovery page (`/service-discovery`) — shows endpoints found but dropped by relabeling, distinct from not being found at all. (3) The Service's Endpoints object — `kubectl get endpoints <service> -n payments` — if empty, pods are not Ready and there is nothing to scrape even if discovery works.

2. `irate()` uses only the two most recent data points. In an alerting rule with a `for: 2m` clause, a momentary spike makes `irate()` fire, then the next 15-second scrape shows normal — the alert immediately resolves. This is alert flapping. The correct function is `rate()` with a range of at least `[5m]`: `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.01` with `for: 2m`. `rate()` uses all data points in the window, smoothing brief spikes, and the `for: 2m` clause requires the condition to be sustained before firing.

3. Root cause: a label with unbounded values (user_id, request_id, session_id, or URL with query parameters) was added to `http_requests_total`. 890,000 series from one metric means one label's value set has grown to approximately 890,000 / (services × methods × status codes). Confirm: `topk(5, count by (label_name)({__name__="http_requests_total"}))` — the offending label will show a count matching the series explosion. Immediate mitigation: add a `metricRelabelings` drop action in the ServiceMonitor to drop the offending label while the application team removes it from instrumentation code. Also temporarily increase Prometheus memory limit to keep monitoring up during the fix.

</details>

---

## Concepts

### Architecture — How PromQL Queries Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         PromQL Query Execution Path                          │
│                                                                              │
│  You (browser / Grafana / alert rule)                                        │
│       │                                                                      │
│       │  HTTP GET /api/v1/query?query=rate(http_requests_total[5m])          │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    Prometheus Query Engine                          │    │
│  │                                                                     │    │
│  │  Step 1: Parse                                                      │    │
│  │    Tokenise and parse the PromQL expression into an AST             │    │
│  │    Validate syntax — return error immediately if invalid             │    │
│  │                                                                     │    │
│  │  Step 2: Select                                                     │    │
│  │    Find all time series matching the metric name + label selectors  │    │
│  │    Load the required sample data from TSDB (head block first,       │    │
│  │    then on-disk blocks for older data)                              │    │
│  │                                                                     │    │
│  │  Step 3: Evaluate                                                   │    │
│  │    Apply functions: rate(), sum(), histogram_quantile(), etc.       │    │
│  │    Apply operators: arithmetic, comparison, logical                 │    │
│  │    Apply aggregations: sum by(), avg without()                      │    │
│  │                                                                     │    │
│  │  Step 4: Return                                                     │    │
│  │    Return result as instant vector or range vector                  │    │
│  │    Grafana renders as panel / Alertmanager evaluates threshold      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │   TSDB (Time Series Database)                                       │    │
│  │   Head block (last ~2h, in memory) → fast queries                  │    │
│  │   On-disk blocks (older data)      → slower, reads from disk        │    │
│  │   Recording rules store pre-computed results here as new metrics    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘

Query evaluation for alerting rules:
  Every evaluation_interval (15s):
    Prometheus evaluates every alerting rule and recording rule
    Alerting rule: if expression returns any result → alert fires
    Recording rule: result stored as new metric in TSDB
```

### Instant Vectors vs Range Vectors — The Core Mental Model

This is the single most important concept in PromQL. Everything else builds on it.

**Instant Vector**

An instant vector is a set of time series with **one sample per series** at
a specific point in time. It is a snapshot — the current value of each series.

```
Query:  http_requests_total

Result (instant vector — all values at timestamp t=now):
  http_requests_total{method="GET", status="200", pod="test-app-abc"} = 48293
  http_requests_total{method="POST", status="201", pod="test-app-abc"} = 9102
  http_requests_total{method="GET", status="200", pod="test-app-def"} = 47891
  http_requests_total{method="POST", status="500", pod="test-app-def"} = 47

Each row = one time series. One value per series.
This is what the Prometheus UI "Table" tab shows.

When Prometheus evaluates this for an alert:
  It evaluates the expression at one point in time (now)
  Returns the single current value for each matching series
```

**Range Vector**

A range vector is a set of time series with **multiple samples per series**
over a time window. It carries history — a slice of the time series.

```
Query:  http_requests_total[5m]

Result (range vector — all samples in the last 5 minutes):
  http_requests_total{method="GET", status="200", pod="test-app-abc"}
    t=-5m: 48203
    t=-4m: 48231   ← +28 in 1 minute
    t=-3m: 48247   ← +16 in 1 minute
    t=-2m: 48261   ← +14 in 1 minute
    t=-1m: 48278   ← +17 in 1 minute
    t=now: 48293   ← +15 in 1 minute

A range vector CANNOT be displayed directly in Prometheus Graph view.
It has multiple values per series — the graph tab expects one value per point.
You MUST apply a function that reduces range vector → instant vector:
  rate(), irate(), increase(), avg_over_time(), max_over_time(), etc.

range vector → function → instant vector → displayable result
```

**Why This Distinction Matters for Every Query You Write**

```
WRONG — you cannot plot a range vector:
  http_requests_total[5m]
  Error: "matrix result not supported"

CORRECT — apply a function first:
  rate(http_requests_total[5m])

WRONG — rate() requires a range vector:
  rate(http_requests_total)
  Error: "expected type range vector in call to function 'rate'"

CORRECT:
  rate(http_requests_total[5m])

WRONG — sum() operates on instant vectors, not range vectors:
  sum(http_requests_total[5m])
  Error: "expected type instant vector in aggregation expression"

CORRECT:
  sum(rate(http_requests_total[5m]))
  (rate reduces range → instant, then sum aggregates the instant vector)
```

```
The transformation chain in most real PromQL queries:

  Raw counter (instant)    → [range window]     → Range vector
  Range vector             → rate() / irate()   → Instant vector (per-second rate)
  Instant vector           → sum by (label)     → Aggregated instant vector
  Aggregated instant vector → / another vector  → Ratio (e.g. error rate)
```

### Label Selectors and Matching Operators

Label selectors filter which time series a query operates on.
Using them precisely is the difference between a query that returns the right
data and one that silently returns too much or too little.

**The Four Matching Operators**

```
Operator  Name               Behaviour
────────────────────────────────────────────────────────────────
=         Exact match        Label value equals this string exactly
!=        Not equal          Label value does NOT equal this string
=~        Regex match        Label value matches this RE2 regex
!~        Negative regex     Label value does NOT match this RE2 regex
```

**Exact Match `=`**

```promql
http_requests_total{method="GET"}
```

```
Matches only time series where method label is exactly "GET"
Case sensitive — "get" would not match
Most efficient selector — Prometheus can use its inverted index directly
Use exact match whenever you know the precise value
```

**Not Equal `!=`**

```promql
http_requests_total{status!="200"}
```

```
All request metrics EXCEPT those with status="200"
Equivalent to: all status codes that are not successful
Useful for: "show me everything that went wrong"

Caution: if a series has NO status label at all, != still matches it
  (an empty label value is not equal to "200")
Use this intentionally — or filter with =~ if you need strict control
```

**Regex Match `=~`**

```promql
http_requests_total{status=~"5.."}
```

```
Matches status values that match the regex pattern "5.."
  "5.." = starts with 5, followed by any two characters
  Matches: 500, 501, 502, 503, 504, 599

IMPORTANT: Prometheus uses RE2 regex (Go's regex engine)
  RE2 is always fully anchored — the regex must match the ENTIRE label value
  NOT just find a match within it

Examples:
  status=~"5.."    → matches "500", "503"  ✅  does NOT match "1500" ✅
  status=~"5"      → does NOT match "500" — must match the full string
  status=~"5.*"    → matches "5", "500", "5abc"
  method=~"GET|POST"      → matches "GET" or "POST"
  namespace=~"prod.*"     → matches "prod", "production", "prod-api"
  namespace!~"kube-.*"    → excludes kube-system, kube-public

RE2 special characters (must be escaped with \ in label values):
  . * + ? ( ) [ ] { } | ^ $ \
```

**Combining Multiple Selectors**

```promql
http_requests_total{
  namespace="default",
  method=~"GET|POST",
  status!~"2..",
  pod=~"test-app-.*"
}
```

```
All four selectors are ANDed together — all must match
There is no OR between separate selector sets in PromQL
  (use separate queries and combine with or operator if needed)

Order of selectors affects query performance:
  Put the most selective (highest cardinality reduction) selector first
  Exact match (=) is always faster than regex (=~)
  Put exact match selectors before regex selectors
```

**The `__name__` Internal Label**

```promql
{__name__=~"http_.*", job="test-app"}
```

```
__name__ is the internal label that stores the metric name itself
Useful for: querying multiple metrics with a pattern in one expression
Rarely needed in day-to-day work — but essential for cardinality audits:

  count by (__name__) ({__name__=~".+"})
  → counts the number of series per metric name
  → shows which metrics contribute most to your cardinality

  topk(10, count by (__name__)({__name__=~".+"}))
  → top 10 metrics by series count — your first cardinality audit query
```

### rate(), irate(), increase() — The Maths, Differences, and When to Use Each

These three functions are the most frequently used and most frequently misused
functions in PromQL. Understanding the exact maths behind each one is mandatory.

**How Counters Work — What These Functions Operate On**

```
A counter's raw values over time (node_cpu_seconds_total for one CPU core):

  t=0s    value = 39,284.49
  t=15s   value = 39,286.63   ← +2.14 in 15 seconds
  t=30s   value = 39,288.91   ← +2.28 in 15 seconds
  t=45s   value = 39,291.34   ← +2.43 in 15 seconds
  t=1m    value = 39,293.62   ← +2.28 in 15 seconds
  t=1m15s value = 39,295.89   ← +2.27 in 15 seconds

At t=2m — Prometheus pod restarts — counter resets to zero:
  t=2m    value = 0.00        ← RESET (pod restarted)
  t=2m15s value = 2.14
  t=2m30s value = 4.42

All three functions — rate(), irate(), increase() — handle resets automatically.
When a reset is detected (value drops), they assume the counter was at max + new value.
```

**rate() — Per-Second Average Rate Over the Full Window**

```
Syntax:   rate(counter[range])
Returns:  per-second average rate of increase over the entire range window
Uses:     ALL data points in the range window

Calculation for rate(node_cpu_seconds_total[5m]):
  Takes the first sample in the 5m window and the last sample
  Calculates: (last_value - first_value) / time_range_in_seconds
  Applies extrapolation to the edges of the window
  Result: a single per-second rate value, smoothed over 5 minutes

With the data above over 5 minutes (300 seconds):
  first_value = 39,284.49
  last_value  = 39,295.89 (ignoring the reset)
  After reset handling: last_value = 39,295.89 + 0 = still 39,295.89
  rate = (39,295.89 - 39,284.49) / 300 = 0.038 CPU-seconds per second

Why rate() smooths:
  Uses endpoints of the window (extrapolated)
  Brief spikes are averaged out
  Line on the graph is smooth and predictable
```

When to use `rate()`:

```
✅  Dashboard panels — smooth lines that show trends clearly
✅  Alerting rules — rate() never causes alert flapping from momentary spikes
    "Use rate for alerts" — official Prometheus documentation
✅  Slow-moving counters where smoothing is appropriate
✅  Aggregations: always sum(rate(...)) not rate(sum(...))
✅  Golden signal Traffic: sum(rate(http_requests_total[5m]))
✅  Golden signal Errors: rate(http_requests_total{status=~"5.."}[5m])
```

**irate() — Instantaneous Rate From Last Two Data Points Only**

```
Syntax:   irate(counter[range])
Returns:  per-second rate based on ONLY the two most recent samples
Uses:     Only the last 2 data points in the range window
          (the range is only used to find those 2 points, not to average)

Calculation for irate(node_cpu_seconds_total[5m]):
  Finds the last two samples in the 5m window:
    t=1m:      value = 39,293.62
    t=1m15s:   value = 39,295.89
  Calculates: (39,295.89 - 39,293.62) / 15s = 0.151 CPU-seconds per second

  That is 4× higher than rate() result (0.038)
  Because these 15 seconds had higher CPU activity than the 5m average

Why irate() is reactive:
  Only looks at the last two points → reflects the most recent rate
  A spike in the last 15 seconds shows up immediately
  A spike 4 minutes ago does NOT affect the result at all
```

When to use `irate()`:

```
✅  Fast-moving, volatile counters where you need to see spikes immediately
✅  Graph panels where you want to see every fluctuation
✅  Debugging high-frequency events in real time
❌  NEVER use irate() in alerting rules
    Reason: alert for clauses require sustained conditions
    irate() is based on 2 points — a momentary spike fires the alert
    then the next scrape shows normal → alert immediately resolves → flapping
    Use rate() for alerts — official Prometheus recommendation

⚠️  When combining irate() with aggregation: always irate() first, then aggregate
    WRONG:  irate(sum(http_requests_total)[5m])     ← sum then irate
    CORRECT: sum(irate(http_requests_total[5m]))    ← irate then sum
    Reason: irate() must see individual counter resets per series
            If you sum first, resets are hidden by the aggregate
```

**rate() vs irate() — Visual Comparison**

```
True traffic pattern (requests per second):
  ^
  |    ╭──╮
  |   ╭╯  ╰╮        ╭─╮
  |  ╭╯    ╰────────╯ ╰╮
  |──╯                  ╰────────
  +───────────────────────────────→ time

rate() result (smoothed average):
  ^
  |    ╭──╮
  |   ╱    ╲       ╭──╮
  |  ╱      ╲─────╱   ╲
  |─╱              (smooth, gentle curves, no sharp edges)
  +───────────────────────────────→ time

irate() result (instantaneous — every spike visible):
  ^
  |   ╭╮╭╮
  |  ╭╯╰╯╰╮       ╭╮╭╮
  |─╭╯     ╰──────╯╰╯╰────────
  |  (jumpy, shows every 15-second fluctuation)
  +───────────────────────────────→ time
```

**increase() — Total Count of New Events Over a Window**

```
Syntax:   increase(counter[range])
Returns:  total increase in counter value over the range window
          (NOT a per-second rate — a raw count of new events)
Relationship to rate(): increase(counter[5m]) ≈ rate(counter[5m]) × 300

Calculation for increase(http_requests_total[1h]):
  Takes (last_value - first_value) over the 1-hour window
  Handles resets. Applies edge extrapolation.
  Result: total new requests in the last hour — a whole number (approximately)

  Note: increase() can return non-integer values due to extrapolation at
  window edges. This is expected behaviour, not a bug.
```

When to use `increase()`:

```
✅  Reporting total counts over a fixed period
    "How many orders were processed in the last hour?"
    increase(http_requests_total{method="POST", status="201"}[1h])

✅  Weekly/daily summaries in Grafana stat panels
    "Requests in the last 24 hours"
    increase(http_requests_total[24h])

✅  Comparing this week vs last week
    increase(http_requests_total[7d]) vs increase(http_requests_total[7d] offset 7d)

❌  Do NOT use increase() in alerting rules
    Alerting needs rates (per-second), not totals
    Use rate() for alerting

❌  Do NOT use increase() as a substitute for rate() in dashboards
    They return different units: count vs count/second
```

**The Decision Table**

```
┌───────────────────────────────┬──────────────┬──────────────┬────────────────┐
│  Use case                     │  rate()      │  irate()     │  increase()    │
├───────────────────────────────┼──────────────┼──────────────┼────────────────┤
│  Alert rules                  │  ✅ Always   │  ❌ Never    │  ❌ Never      │
│  Dashboard — trend lines      │  ✅ Best     │  ⚠️  Noisy   │  ❌ Wrong unit │
│  Dashboard — spike detection  │  ⚠️  Smooth  │  ✅ Best     │  ❌ Wrong unit │
│  Total count reporting        │  ❌ Wrong    │  ❌ Wrong    │  ✅ Best       │
│  Aggregation with sum()       │  ✅ sum(rate)│  ✅ sum(irate)│  ✅ sum(incr) │
│  SLO calculations             │  ✅ Always   │  ❌ Never    │  ❌ Never      │
│  Recording rules              │  ✅ Always   │  ❌ Avoid    │  Occasionally  │
└───────────────────────────────┴──────────────┴──────────────┴────────────────┘
```

### Aggregation Operators — Reducing Many Series to Fewer

Aggregation operators take a set of time series (instant vector) and
collapse them into fewer series based on label grouping.

**The Two Grouping Clauses: by() and without()**

```
by(label1, label2, ...)    Keep only these labels — drop all others
without(label1, label2, .) Keep all labels EXCEPT these — drop these

by() and without() are inverses of each other.
Use by() when you know exactly which labels you want to keep.
Use without() when you want to drop one or two noisy labels (like instance).
```

**sum — Add Values Together**

```promql
# Total request rate across all pods and all methods
sum(rate(http_requests_total[5m]))

# Total request rate per namespace (keep only namespace label)
sum by (namespace) (rate(http_requests_total[5m]))

# Total request rate per pod and status (keep pod and status)
sum by (pod, status) (rate(http_requests_total[5m]))

# Total request rate per status (drop instance label, keep everything else)
sum without (instance) (rate(http_requests_total[5m]))
```

```
Expected results with test-app (3 pods):
  sum(rate(http_requests_total[5m]))
  → single value: ~2.0 req/s (all pods combined)

  sum by (pod) (rate(http_requests_total[5m]))
  → three values, one per pod: each ~0.67 req/s

  sum by (status) (rate(http_requests_total[5m]))
  → one value per status code (200, 201, 500...)
```

**avg — Arithmetic Mean**

```promql
# Average request rate across pods (useful when pods should have equal load)
avg by (namespace) (rate(http_requests_total[5m]))

# Average CPU usage across all nodes
avg(rate(node_cpu_seconds_total{mode!="idle"}[5m]))
```

```
When avg is correct:
  Comparing load distribution — if avg = sum/count, load is balanced
  Normalising metrics across instances with equal expected load

When avg is wrong:
  Capacity planning (use sum — you need total, not average)
  Alerting on resource exhaustion (use max — the worst case matters)
```

**max and min — Extremes**

```promql
# Worst-case memory usage across pods (the pod closest to OOMKill)
max by (namespace) (
  process_resident_memory_bytes
)

# Best-case available disk across nodes (lowest free space node)
min(node_filesystem_avail_bytes{mountpoint="/"})
```

```
Use max for alerting on saturation:
  "Alert when ANY pod's memory exceeds 90% of limit"
  max(process_resident_memory_bytes / (64 * 1024 * 1024)) > 0.9
  (if you used avg, one pod at 98% averaged with two at 60% = no alert)

Use min for availability monitoring:
  "Is disk available on every node?"
  min(node_filesystem_avail_bytes{mountpoint="/"}) < 1e9
  (alert if the worst node has less than 1GB free)
```

**count — How Many Series Match**

```promql
# How many pods are running per namespace
count by (namespace) (kube_pod_info)

# How many pods are NOT ready (0 = ready, 1 = not ready)
count(kube_pod_status_ready{condition="true"} == 0)

# Top 10 metrics by series count — cardinality audit
topk(10, count by (__name__) ({__name__=~".+"}))
```

**topk and bottomk — Ranking**

```promql
# Top 5 pods by memory usage
topk(5, process_resident_memory_bytes{namespace="default"})

# Bottom 3 nodes by available disk
bottomk(3, node_filesystem_avail_bytes{mountpoint="/"})
```

```
⚠️  Performance warning: topk and bottomk require sorting all matching series.
    Time complexity: O(n log n) — much slower than sum/avg/count (O(n))
    On 50,000 series: topk can take 200–500ms vs <1ms for sum

    Solution for dashboards: pre-compute with a recording rule.
    Or limit the selector first to reduce the input series count.

    SLOW:   topk(10, rate(http_requests_total[5m]))
    BETTER: topk(10, rate(http_requests_total{namespace="default"}[5m]))
    BEST:   Use a recording rule (see Part D)
```

**quantile — Distribution Across Series**

```promql
# Median (p50) memory usage across all pods
quantile(0.5, process_resident_memory_bytes)

# 95th percentile CPU usage across all nodes
quantile(0.95,
  rate(node_cpu_seconds_total{mode!="idle"}[5m])
)
```

```
quantile() across series is NOT the same as histogram_quantile() for latency.
  quantile() aggregates across multiple time series (e.g. pods)
    → "what is the p95 memory usage across my pod fleet?"
  histogram_quantile() calculates quantiles within histogram buckets
    → "what is the p95 request latency for my API?"

Do not confuse them — they answer different questions.
```

### Binary Operations — Arithmetic, Comparison, and Logical

Binary operations combine two vectors with element-wise operations.
This is how you compute ratios, percentages, and conditional filtering.

**Arithmetic Binary Operations**

```promql
# Memory usage as percentage of total
(
  node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
) / node_memory_MemTotal_bytes * 100
```

```promql
# Disk usage percentage
(
  node_filesystem_size_bytes{mountpoint="/"} -
  node_filesystem_avail_bytes{mountpoint="/"}
) / node_filesystem_size_bytes{mountpoint="/"} * 100
```

```promql
# Error rate as percentage
sum(rate(http_requests_total{status=~"5.."}[5m]))
/
sum(rate(http_requests_total[5m]))
* 100
```

```
Arithmetic operators: + - * / % ^

Label matching rules for binary operations:
  Both sides must have the same label set (same labels, same values)
  Prometheus matches vectors element-by-element on ALL labels by default
  Labels present in one side but not the other = no match = dropped from result

  Example: this FAILS silently
    node_memory_MemTotal_bytes / node_memory_MemAvailable_bytes
    Both have {instance="minikube", job="node-exporter"} → they match ✅

    http_requests_total / node_memory_MemTotal_bytes
    Different label sets → no matches → empty result ❌
```

**Comparison Operators — Filtering by Value**

```promql
# Only show pods with more than 50MB memory usage
process_resident_memory_bytes > 50 * 1024 * 1024
```

```promql
# Alert expression: CPU busy > 80% for 5 minutes
(
  100 - avg by (instance) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  ) * 100
) > 80
```

```
Comparison operators: == != > < >= <=

When used in filters (no bool keyword):
  Returns only the series where the condition is true
  Series where condition is false → dropped from the result
  This is how alert expressions work — if result is empty, no alert

When used with bool keyword:
  Returns 1 where condition is true, 0 where false — no dropping
  Useful for: tracking whether a condition is met as a metric over time

  Example:
    (up == 0)          → returns only series where target is down
    (up == bool 0)     → returns 1 for down targets, 0 for up targets
    (useful in recording rules for availability calculations)
```

**Logical Operators — and, or, unless**

```promql
# All series that appear in BOTH vectors (intersection)
# Alert: high CPU AND high memory simultaneously
(
  rate(node_cpu_seconds_total{mode!="idle"}[5m]) > 0.8
)
and
(
  node_memory_MemAvailable_bytes < 1e9
)
```

```promql
# Series from left side that do NOT appear in right side
# Pods with high CPU UNLESS they are in the excluded namespace
rate(container_cpu_usage_seconds_total[5m]) > 0.5
unless
on(namespace) (kube_namespace_labels{label_exclude="true"})
```

```
and:    keep left-side series that have a matching right-side series
or:     union — all series from left, plus right-side series not in left
unless: keep left-side series that have NO matching right-side series
```

**Vector Matching — on() and ignoring()**

```promql
# Correct: match only on namespace label (ignore pod, instance differences)
sum by (namespace) (rate(http_requests_total[5m]))
/
sum by (namespace) (rate(http_requests_total{status=~"5.."}[5m]))
```

```
When labels differ between two vectors:

ignoring(label1, label2):
  Ignore these labels when matching — match on everything else
  Use when two vectors have one label that differs but others match

on(label1, label2):
  Match ONLY on these labels — ignore everything else
  Use when you want explicit control over the matching key

group_left() and group_right():
  Used for many-to-one matching (one side has more series than the other)
  group_left: left side can have multiple matches per right-side series
  group_right: right side can have multiple matches per left-side series

  Example: join kube_pod_info (one row per pod) with container metrics
  (one pod may have many containers)

  container_cpu_usage_seconds_total
  * on(pod) group_left(label_app)
  kube_pod_labels
```

### The offset Modifier — Comparing Past and Present

`offset` shifts the time range of a query backwards in time. This enables
week-over-week comparisons, trend analysis, and baseline alerting.

**Basic offset Usage**

```promql
# Request rate right now
rate(http_requests_total[5m])

# Request rate from 1 hour ago
rate(http_requests_total[5m] offset 1h)

# Request rate from exactly 1 week ago
rate(http_requests_total[5m] offset 1w)
```

**Week-over-Week Traffic Comparison**

```promql
# How much has traffic grown vs same time last week?
# Positive = more traffic, negative = less
sum(rate(http_requests_total[5m]))
-
sum(rate(http_requests_total[5m] offset 1w))
```

```promql
# Traffic growth as a percentage vs last week
(
  sum(rate(http_requests_total[5m]))
  -
  sum(rate(http_requests_total[5m] offset 1w))
)
/
sum(rate(http_requests_total[5m] offset 1w))
* 100
```

```
Expected result:
  Positive value: traffic has grown since last week
  Negative value: traffic has decreased
  0: exactly the same

  In a growing business: expect 5–20% week-over-week growth
  Sudden 50%+ growth: investigate — might be good (viral feature)
                       or bad (scraper bot, DDoS, runaway client)
```

**Baseline Alerting with offset**

```promql
# Alert if current error rate is 10x higher than the same time yesterday
# (catches errors that look small in absolute terms but are unusual for this hour)
rate(http_requests_total{status=~"5.."}[5m])
>
10 * rate(http_requests_total{status=~"5.."}[5m] offset 1d)
```

```
This is a dynamic threshold — much smarter than a fixed threshold:
  3am on a Sunday might have 0.001 errors/sec normally
  If it spikes to 0.01 errors/sec → 10× increase → alert fires
  A fixed threshold of 0.1 errors/sec would never fire at 3am
  The offset-based alert catches anomalies at any traffic level
```

**The @ Modifier — Pin to a Specific Timestamp**

```promql
# What was the request rate at exactly midnight UTC today?
rate(http_requests_total[5m] @ 1735689600)
```

```
@ takes a Unix timestamp (seconds since epoch)
Useful for: post-incident analysis, reproducible queries, SLO reports
Less common than offset but important for forensic investigations
```

### Subqueries — Computing Rates Over Rates

Subqueries let you apply a range function (like `max_over_time`) to the
result of another expression that itself produces a range of values.
This is how you answer questions like "what was the maximum 5-minute
rate over the last hour?"

**Subquery Syntax**

```
<expr>[<range>:<resolution>]
  expr:        any PromQL instant vector expression
  range:       how far back to evaluate the expression
  resolution:  how frequently to evaluate (optional — defaults to evaluation_interval)
```

**Example 1 — Maximum Rate in the Last Hour**

```promql
# What was the peak 5-minute request rate over the last hour?
max_over_time(
  rate(http_requests_total[5m])[1h:5m]
)
```

```
What this does:
  Inner expression: rate(http_requests_total[5m])
    → calculates the 5-minute request rate at each step
  Subquery wrapper: [1h:5m]
    → evaluates the inner expression at 5-minute intervals going back 1 hour
    → produces 12 data points (60min / 5min = 12 evaluations)
  max_over_time(): finds the maximum across those 12 data points

Result: the peak request rate in the last hour
  Useful for: capacity planning, SLO burn rate analysis
  "What was our busiest 5 minutes in the last hour?"
```

**Example 2 — Detecting Sustained High Error Rate**

```promql
# Was the error rate above 1% at any point in the last 30 minutes?
max_over_time(
  (
    sum(rate(http_requests_total{status=~"5.."}[5m]))
    /
    sum(rate(http_requests_total[5m]))
  )[30m:1m]
) > 0.01
```

```
The subquery [30m:1m] evaluates the error rate expression every 1 minute
going back 30 minutes. max_over_time finds the worst case.
If it ever exceeded 1% in that window, the query returns a result.

This is how you build "did we breach our SLO in the last N minutes?" queries.
```

**Example 3 — Smoothed Spike Detection**

```promql
# Detect if irate() (spiky) exceeded rate() (smooth) by more than 3x
# Indicates a very sharp sudden spike
irate(http_requests_total[5m])
>
3 * rate(http_requests_total[5m])
```

```
When current instantaneous rate is 3× the 5-minute average:
  Traffic is spiking sharply — not just gradually increasing
  Alert on this to catch burst patterns that rate() would smooth over
```

### predict_linear() — Proactive Capacity Alerting

`predict_linear()` extrapolates the current trend of a gauge metric forward
in time using linear regression. This is how you build "disk full in X hours"
alerts before the disk actually fills.

**Syntax**

```
predict_linear(gauge_metric[range], seconds_ahead)
  range:         how much historical data to use for the regression (gauge metric)
  seconds_ahead: how many seconds into the future to predict
```

**Disk Space Exhaustion Alert**

```promql
# Predict available disk space 24 hours from now
# Based on the trend of the last 6 hours
predict_linear(
  node_filesystem_avail_bytes{mountpoint="/"}[6h],
  24 * 3600
)
```

```
Result: predicted bytes available in 24 hours
  Positive value: disk is growing (shrinking usage) — OK
  Negative value: disk will be full before 24 hours — alert!

Alert expression:
  predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4 * 3600) < 0
  "Disk will be full in less than 4 hours at the current trend"

This fires BEFORE the disk fills — giving you time to act.
The range [6h] uses the last 6 hours of trend data for the regression.
Use enough history to capture real trends but not too much to include old patterns:
  [1h] → too reactive, a brief spike skews the prediction
  [6h] → good default for daily patterns
  [24h] → smooths out daily cycles, better for weekly trends
```

**Memory Pressure Prediction**

```promql
# Will we OOMKill within 2 hours if memory keeps growing at current rate?
predict_linear(
  container_memory_working_set_bytes{namespace="default"}[30m],
  2 * 3600
)
>
container_spec_memory_limit_bytes{namespace="default"}
```

```
If the predicted memory in 2 hours exceeds the container limit:
  The pod will be OOMKilled before then
  Alert fires now → you have 2 hours to investigate

This is proactive alerting — you catch the problem before users feel it.
The opposite of the traditional "alert when it breaks" approach.
```

### histogram_quantile() — Correct Latency Percentiles

`histogram_quantile()` calculates approximate quantiles (p50, p90, p99, etc.)
from histogram bucket data. This is how you measure SLO compliance.

**Syntax**

```
histogram_quantile(φ, buckets)
  φ:       the quantile to calculate (0 to 1, e.g. 0.99 for p99)
  buckets: a range vector expression that produces histogram _bucket series
```

**p99 Latency — The Most Important Latency Query**

```promql
# p99 request latency for the test-app across all pods
histogram_quantile(
  0.99,
  sum by (le) (
    rate(http_request_duration_seconds_bucket{
      job="default/test-app/0"
    }[5m])
  )
)
```

```
Breaking this down:

1. http_request_duration_seconds_bucket{job="default/test-app/0"}
   Selects all _bucket series for this job (the histogram data)
   Each bucket is labelled with le="<threshold>" (less than or equal to)

2. rate(...[5m])
   Converts cumulative bucket counts to per-second rates
   Required: histogram_quantile needs rates, not raw cumulative counts
   Why? Because we want p99 of the current request latency, not since startup

3. sum by (le) (...)
   Aggregates across all pods — sums the bucket counts per le threshold
   Keeps the le label (required by histogram_quantile to find bucket boundaries)
   Drops all other labels (pod, instance) — giving us p99 across all pods

4. histogram_quantile(0.99, ...)
   Interpolates between bucket boundaries to estimate the 99th percentile
   Result: the latency that 99% of requests complete within

Expected result: approximately 0.1–0.5 seconds for podinfo under light load
```

**Multiple Percentiles in One Query**

```promql
# p50, p90, p99 in a single expression using histogram_quantiles() (Prometheus 3.x)
histogram_quantiles(
  "percentile",
  sum by (le) (
    rate(http_request_duration_seconds_bucket{job="default/test-app/0"}[5m])
  ),
  0.50, 0.90, 0.99
)
```

```
histogram_quantiles() is new in Prometheus 3.x (note the plural).
Returns multiple quantiles in one query with a "percentile" label distinguishing them.
More efficient than three separate histogram_quantile() calls.

Result:
  {percentile="0.5"}  0.032  → p50 = 32ms  (half of requests under 32ms)
  {percentile="0.9"}  0.089  → p90 = 89ms  (90% of requests under 89ms)
  {percentile="0.99"} 0.241  → p99 = 241ms (99% of requests under 241ms)
```

**Common Mistakes with histogram_quantile()**

```
Mistake 1: Missing rate() — using raw cumulative buckets
  WRONG:  histogram_quantile(0.99, http_request_duration_seconds_bucket)
  RESULT: p99 since Prometheus started — not the current p99

  CORRECT: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
  RESULT:  p99 of requests in the last 5 minutes ✅

Mistake 2: Missing sum by (le) — not aggregating across pods
  Without sum by (le), each pod's histogram is calculated separately
  You get one p99 per pod instead of the aggregate p99

  CORRECT: always sum by (le) before histogram_quantile when you have
           multiple pods/instances contributing to the same histogram

Mistake 3: Using the wrong bucket boundaries
  histogram_quantile interpolates between le bucket boundaries
  If your SLO is 200ms but you have no bucket at le="0.2",
  the p99 estimate will be imprecise around 200ms
  Always define histogram buckets that bracket your SLO values

Mistake 4: Confusing histogram_quantile (latency) with quantile (across series)
  histogram_quantile(0.99, buckets) → p99 latency within histogram data
  quantile(0.99, memory_bytes)      → p99 across different pod memory values
  These are completely different operations answering different questions
```

### PromQL Performance — What Makes Queries Slow

**Query Performance Hierarchy (fastest to slowest)**

```
1. Recording rule lookups                     < 10ms
   Reading pre-computed series — no calculation

2. Exact metric name + exact label match      10–50ms
   http_requests_total{job="test-app", status="200"}
   Uses inverted index directly

3. Aggregations with by/without clauses       50–200ms
   sum by (namespace)(rate(http_requests_total[5m]))
   Linear time: O(n) in number of matching series

4. Regex label selectors                      100–500ms
   http_requests_total{job=~"test-.*"}
   Cannot use index directly — scans all series for regex match

5. topk / bottomk / quantile                  200ms–2s
   Requires sorting all matching series: O(n log n)

6. Cross-metric binary operations             300ms–5s
   Two large vectors joined element-wise
   Expensive if label sets don't match cleanly

7. Full cardinality scans                     seconds
   {__name__=~".+"}  or  count({__name__=~".+"})
   Touches every series in TSDB — run only for audits, never in dashboards
```

**Optimisation Rules**

```
Rule 1: Reduce before you compute
  SLOW:  rate(sum(http_requests_total)[5m])   # WRONG and slow
         Sums all counters together, then rates the sum
         Counter resets from different pods are hidden in the sum
         This gives incorrect results AND is slower

  CORRECT: sum(rate(http_requests_total[5m]))  # rate per pod, then sum

Rule 2: Filter with exact match before regex
  SLOW:  http_requests_total{job=~"default/.*"}   # regex scan all series
  FAST:  http_requests_total{namespace="default"} # exact match uses index

Rule 3: Use recording rules for any query in a dashboard
  If a query takes > 100ms: make it a recording rule
  Dashboards should query pre-computed metrics, not raw counters

Rule 4: Avoid topk/bottomk in frequently-refreshed panels
  Use recording rules to pre-compute rankings
  Or limit with exact selectors to reduce input series

Rule 5: Do not use subqueries in high-frequency evaluations
  Subqueries re-evaluate their inner expression N times
  A [1h:1m] subquery = 60 inner evaluations per outer evaluation
  Expensive if the inner expression is already slow
  Pre-compute the inner expression as a recording rule instead

Rule 6: Use irate() only for ad-hoc debugging, not in production dashboards
  irate() is always noisier — engineers interpret it incorrectly
  For dashboards: rate() with a sensible range window
```

## Recording Rules — Pre-Computing Expensive Queries

Recording rules evaluate a PromQL expression on every `evaluation_interval`
and store the result as a new time series in the TSDB. Dashboard panels
query the recording rule's output instead of recomputing the expensive
expression on every panel load.

### Why Recording Rules Matter

```
Without recording rules — dashboard load scenario:

  User opens Grafana dashboard with 8 panels
  Each panel runs its own PromQL query
  Each query scans raw TSDB data for the selected time range

  Panel 1: sum(rate(http_requests_total[5m]))
    → scans all http_requests_total series for 24 hours
    → CPU spike on Prometheus, 500ms–2s query time

  8 panels × 500ms average = 4 seconds to load the dashboard
  10 engineers open the dashboard simultaneously:
    8 panels × 10 users × 500ms = 40 concurrent expensive queries
    Prometheus CPU saturates, queries slow to 5–10 seconds
    Engineers stop trusting the dashboard (it's always slow)


With recording rules — same dashboard:

  Every 15 seconds, Prometheus pre-computes:
    job:http_requests:rate5m = sum(rate(http_requests_total[5m]))
  Result stored as a new time series in TSDB

  Dashboard queries: job:http_requests:rate5m
    → reads one pre-computed series — instant, no computation needed
    → query time: <10ms regardless of number of concurrent users

  Dashboard loads in < 100ms for any number of engineers
```

### The Official Prometheus Naming Convention

Prometheus has a documented naming convention for recording rules.
Following it makes rules readable, consistent, and debuggable across teams.

```
Format:  level:metric:operations

level       → the label set of the output (what labels remain after aggregation)
              Examples: job, instance, namespace, pod, instance_path
              If aggregating by job: level is "job"
              If keeping instance and path: level is "instance_path"

metric      → the metric being computed
              Use the metric name without _total suffix (strip _total for counters)
              Examples: http_requests, node_cpu_seconds, http_request_duration

operations  → functions applied, newest first
              Examples: rate5m, rate1m, sum, p99, mean5m
              List newest operation first (the outermost function)

Examples:
  job:http_requests:rate5m
    → aggregated by job, metric is http_requests, operation is rate over 5m

  namespace_pod:http_requests:rate5m
    → aggregated by namespace and pod, rate over 5m

  job:http_request_duration_seconds:p99rate5m
    → p99 quantile of the rate over 5m, aggregated by job

  job:node_cpu_seconds:rate5m
    → node CPU rate aggregated by job (usually "node-exporter")
```

---

## Part A — Core PromQL Concepts

**What you accomplish in Part A:** Run instant and range vector queries against the live test-app metrics, apply all four label matching operators, and verify the correct behaviour of `rate()`, `irate()`, and `increase()` against real counter data.

### Step 1: Verify Instant vs Range Vectors in the Prometheus UI

This step proves the instant vs range vector distinction with real queries against your running test-app.

```bash
# Keep port-forward active for all steps in this demo
kubectl port-forward -n monitoring \
  svc/kube-prometheus-stack-prometheus 9090:9090 &
```

Open the Prometheus UI at `http://localhost:9090` and run the following queries in the **Graph** tab.

**Query 1 — Instant vector (Table view):**

```promql
http_requests_total{job="test-app"}
```

```
# Expected: Table tab shows one row per unique label combination
# Each row has a single current value (cumulative counter since pod start)
# Switch to Graph tab → error: "matrix result not supported" — this is an instant vector

# Observation: raw counter values are in the tens of thousands — not useful for alerting
```

**Query 2 — Range vector reduced to instant via rate():**

```promql
rate(http_requests_total{job="test-app"}[5m])
```

```
# Expected: Graph tab renders successfully — per-second rate per series
# Each of the 3 pods shows ~0.3–0.7 req/s depending on traffic generated
# This is the correct form for dashboards and alerting
```

**Query 3 — Sum across all pods:**

```promql
sum(rate(http_requests_total{job="test-app"}[5m]))
```

```
# Expected: single value — total request rate across all 3 pods
# Approximately 1.0–2.0 req/s after the baseline traffic generated in Prerequisites
```

Via CLI:

```bash
# Verify all three queries return data
curl -s 'localhost:9090/api/v1/query?query=sum(rate(http_requests_total{job%3D~"serviceMonitor%2Fdefault%2Ftest-app%2F.*"}[5m]))' \
  | jq '.data.result[0].value[1]'
# Expected: a string like "1.234" (requests per second)
```

### Step 2: Label Selectors — Filtering and Regex in Practice

This step applies all four label matching operators against real test-app metrics.

```promql
# Exact match — only GET requests
http_requests_total{
  job="test-app",
  method="GET"
}
```

```promql
# Not equal — all requests except 200 OK
http_requests_total{
  job="test-app",
  status!="200"
}
```

```promql
# Regex match — all 2xx success codes
http_requests_total{
  job="test-app",
  status=~"2.."
}
```

```promql
# Negative regex — everything except 2xx
http_requests_total{
  job="test-app",
  status!~"2.."
}
```

```bash
# CLI: count how many series each selector returns
curl -s 'localhost:9090/api/v1/query?query=count(http_requests_total{job%3D~"serviceMonitor%2Fdefault%2Ftest-app%2F.*"})' \
  | jq '.data.result[0].value[1]'
# Expected: a number — total series count for test-app metrics
```

### Step 3: rate(), irate(), increase() — Side-by-Side Comparison

This step runs all three functions against the same counter so you can see the difference directly.

```promql
# rate() — smooth, uses full window
rate(http_requests_total{job="test-app"}[5m])
```

```promql
# irate() — reactive, uses only last 2 points
irate(http_requests_total{job="test-app"}[5m])
```

```promql
# increase() — total count in window, not per-second
increase(http_requests_total{job="test-app"}[5m])
```

```
# Expected observations (switch to Graph tab, set range to Last 15 minutes):
#
# rate():     smooth curve — brief spikes are dampened
# irate():    jagged line — every 15-second fluctuation is visible
# increase(): larger numbers (count not rate) — roughly rate() × 300 for [5m]
#
# Observation: rate() and irate() produce per-second values (~0.3–0.7)
#              increase() produces total count (~90–210 for 5m window)
#              Units are different — never compare them on the same panel axis
```

---

## Part B — Advanced Query Patterns

**What you accomplish in Part B:** Build aggregation queries across the 3-pod test-app fleet, write binary operations for error rate and saturation ratios, and use offset for week-over-week comparison.

### Step 4: Aggregation Operators — sum, avg, max, topk

```promql
# Traffic: total RPS across all pods, broken down by HTTP method
sum by (method) (
  rate(http_requests_total{job="test-app"}[5m])
)
```

```promql
# Load balance check: per-pod request rate — should be roughly equal
sum by (pod) (
  rate(http_requests_total{job="test-app"}[5m])
)
```

```promql
# Saturation: worst-case memory across pods (the pod closest to OOMKill)
max(process_resident_memory_bytes{job="test-app"})
```

```promql
# Cardinality audit: top 10 metrics by series count
topk(10, count by (__name__) ({__name__=~".+"}))
```

```bash
# CLI: verify per-pod rates are balanced
curl -s 'localhost:9090/api/v1/query?query=sum+by+(pod)(rate(http_requests_total{job%3D~"serviceMonitor%2Fdefault%2Ftest-app%2F.*"}[5m]))' \
  | jq '[.data.result[] | {pod: .metric.pod, rate: .value[1]}]'
# Expected: three entries with similar rate values — confirms even load distribution
```

### Step 5: Binary Operations — Error Rate and Saturation Ratios

```promql
# Golden Signal: Errors — error rate as a fraction (0 to 1)
sum(rate(http_requests_total{job="test-app", status=~"5.."}[5m]))
/
sum(rate(http_requests_total{job="test-app"}[5m]))
```

```
# Expected: a small decimal (e.g. 0.005 = 0.5% error rate) after generating
# the status/500 request in Prerequisites. Empty result means no errors recorded yet.
# Observation: PromQL returns no data for absent counters (zero errors = no time series)
# This is correct behaviour — not a bug.
```

```promql
# Golden Signal: Saturation — memory as fraction of 64Mi limit
process_resident_memory_bytes{job="test-app"}
/ (64 * 1024 * 1024)
```

```promql
# Alert expression: fire if any pod exceeds 85% memory limit
max(
  process_resident_memory_bytes{job="test-app"}
  / (64 * 1024 * 1024)
) > 0.85
```

```
# Expected: empty result — pods are well under 85% under light load
# Observation: empty result from an alert expression = alert is NOT firing (correct)
# If the expression returns a value, the alert would fire
```

### Step 6: offset — Week-over-Week Comparison

```promql
# Current request rate
sum(rate(http_requests_total{job="test-app"}[5m]))
```

```promql
# Request rate from 1 hour ago (offset substitute for demo — no 1-week data yet)
sum(rate(http_requests_total{job="test-app"}[5m] offset 1h))
```

```promql
# Growth vs 1 hour ago as a percentage
(
  sum(rate(http_requests_total{job="test-app"}[5m]))
  -
  sum(rate(http_requests_total{job="test-app"}[5m] offset 1h))
)
/
sum(rate(http_requests_total{job="test-app"}[5m] offset 1h))
* 100
```

```
# Note: in a real environment, use offset 1w for true week-over-week comparison.
# Demo 01 was installed within the last hour, so [5m] offset 1h may return no data.
# Observation: empty result from offset query = no historical data yet — expected.
# In production after 7+ days of data: replace offset 1h with offset 1w.
```

### Step 7: Subqueries — Peak Rate Over Time

```promql
# Peak 5-minute request rate over the last hour
max_over_time(
  sum(rate(http_requests_total{job="test-app"}[5m]))[1h:5m]
)
```

```
# Expected: a single value — the highest request rate seen in any 5-minute window
# in the last hour. Equal to or higher than the current rate query.
# Observation: if this is much higher than the current rate, a traffic spike
# occurred earlier in the hour — worth investigating in a production context.
```

```promql
# Was the error rate above 1% at any point in the last 30 minutes?
max_over_time(
  (
    sum(rate(http_requests_total{job="test-app", status=~"5.."}[5m]))
    /
    sum(rate(http_requests_total{job="test-app"}[5m]))
  )[30m:1m]
) > 0.01
```

```
# Expected: empty result if error rate never exceeded 1% in the last 30 minutes.
# Non-empty result means an SLO breach occurred — investigate the time it happened.
```

---

## Part C — Production Techniques

**What you accomplish in Part C:** Use predict_linear() to build proactive disk and memory alerts, calculate p99 latency with histogram_quantile(), and identify and fix slow PromQL queries.

### Step 8: predict_linear() — Proactive Disk and Memory Alerts

```promql
# How much disk will be available in 24 hours at the current trend?
predict_linear(
  node_filesystem_avail_bytes{mountpoint="/"}[6h],
  24 * 3600
)
```

```bash
# CLI: check current prediction and whether it is positive or negative
curl -s 'localhost:9090/api/v1/query?query=predict_linear(node_filesystem_avail_bytes{mountpoint%3D"/"}[6h],86400)' \
  | jq '.data.result[0].value[1]'
# Expected: a large positive number (bytes available — disk not filling on Minikube)
# Negative would mean: disk will be exhausted within 24 hours at current rate
```

```promql
# Alert expression: disk will fill within 4 hours
predict_linear(
  node_filesystem_avail_bytes{mountpoint="/"}[6h],
  4 * 3600
) < 0
```

```
# Expected: empty result — disk is not filling. Correct behaviour for a healthy system.
# In production: add this as a PrometheusRule alerting rule (Demo 07).
```

```promql
# Memory growth prediction — will any test-app pod OOMKill within 2 hours?
predict_linear(
  process_resident_memory_bytes{job="test-app"}[30m],
  2 * 3600
) > (64 * 1024 * 1024)
```

```
# Expected: empty result — pods are stable, not growing toward OOMKill.
# Observation: predict_linear() on a stable gauge returns a value close to
# the current value (slope ≈ 0, prediction ≈ current).
```

### Step 9: histogram_quantile() — p99 Latency Calculation

```promql
# p99 request latency for test-app — the SLO metric
histogram_quantile(
  0.99,
  sum by (le) (
    rate(
      http_request_duration_seconds_bucket{
        job="test-app"
      }[5m]
    )
  )
)
```

```bash
# CLI: check current p99 latency value
curl -s 'localhost:9090/api/v1/query?query=histogram_quantile(0.99,sum+by+(le)(rate(http_request_duration_seconds_bucket{job%3D~"serviceMonitor%2Fdefault%2Ftest-app%2F.*"}[5m])))' \
  | jq '.data.result[0].value[1]'
# Expected: a decimal value in seconds (e.g. "0.1234" = 123ms p99 latency)
# Empty result: no histogram data yet — re-run traffic generation from Prerequisites
```

```promql
# All three percentiles using histogram_quantiles() — Prometheus 3.x
histogram_quantiles(
  "percentile",
  sum by (le) (
    rate(
      http_request_duration_seconds_bucket{
        job="test-app"
      }[5m]
    )
  ),
  0.50, 0.90, 0.99
)
```

```
# Expected: three result rows labelled percentile="0.5", "0.9", "0.99"
# p50 will be significantly lower than p99 — normal for web services
# Observation: a large gap between p90 and p99 means tail latency is high
# even if median (p50) looks fine — a common SLO trap
```

### Step 10: PromQL Performance — Measure and Optimise

This step demonstrates query performance differences and when to use recording rules.

```bash
# Check query execution time using the Prometheus API stats endpoint
# Slow query: full regex scan + topk sort
curl -s 'localhost:9090/api/v1/query?query=topk(10,count+by+(__name__)({__name__%3D~".%2B"}))&stats=true' \
  | jq '.data.stats.timings'
```

```
# Expected output (example):
# {
#   "evalTotalTime": 0.234,    ← total query evaluation time in seconds
#   "resultSortTime": 0.012,
#   "queryPreparationTime": 0.003,
#   "innerEvalTime": 0.219,    ← time spent evaluating the expression
#   "execQueueTime": 0.0001,
#   "execTotalTime": 0.235
# }
# Observation: innerEvalTime > 0.1s means this query is a candidate for a recording rule
```

```bash
# Fast query: exact match, pre-aggregated
curl -s 'localhost:9090/api/v1/query?query=sum(rate(http_requests_total{job%3D~"serviceMonitor%2Fdefault%2Ftest-app%2F.*"}[5m]))&stats=true' \
  | jq '.data.stats.timings.evalTotalTime'
# Expected: < 0.01 seconds — much faster than the topk scan above
```

```promql
# The TSDB Status page shows top metrics by series count
# Navigate to: http://localhost:9090/tsdb-status
# Look for: "Top 10 metric names by number of series"
# Any metric > 5,000 series in this single-node demo is worth investigating
```

---

## Part D — Recording Rules

**What you accomplish in Part D:** Create PrometheusRule CRDs for test-app and node metrics, apply them to the cluster, verify they are loaded and evaluating correctly, and validate the rule syntax with promtool.

### Step 11: Create and Apply Recording Rules

Create the PrometheusRule CRD for test-app metrics:

**`src/recording-rules/test-app-rules.yaml`:**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-app-recording-rules
  namespace: default
  labels:
    # PrometheusRule CRD must be discoverable by Prometheus Operator.
    # Since we set ruleSelectorNilUsesHelmValues: false in values.yaml,
    # Prometheus discovers ALL PrometheusRules cluster-wide — no label required.
    # Add for documentation clarity:
    app: test-app
    role: recording-rules
spec:
  groups:
    # ── Group 1: Request Rate Rules ───────────────────────────────────────────
    # Rule groups execute sequentially within the group.
    # Different groups execute in parallel.
    # Group interval overrides global evaluation_interval if set.
    - name: test_app_request_rates
      interval: 15s   # evaluate every 15s (matches scrape_interval)
      rules:

        # Raw 5-minute request rate per pod and status
        # Level: pod and status labels are preserved
        # Used by: per-pod breakdown panels in Grafana
        - record: pod_status:http_requests:rate5m
          expr: |
            rate(http_requests_total{job="test-app"}[5m])

        # Total request rate aggregated across all pods, per namespace
        # Level: namespace label only
        # Used by: traffic golden signal panel
        - record: namespace:http_requests:rate5m
          expr: |
            sum by (namespace) (
              rate(http_requests_total{job="test-app"}[5m])
            )

        # Total request rate — single number across everything
        # Level: no labels (fully aggregated)
        # Used by: top-level traffic stat panel
        - record: job:http_requests:rate5m
          expr: |
            sum(rate(http_requests_total{job="test-app"}[5m]))

    # ── Group 2: Error Rate Rules ─────────────────────────────────────────────
    - name: test_app_error_rates
      interval: 15s
      rules:

        # 5xx error rate as a fraction (0 to 1) aggregated by namespace
        # 0.0 = no errors, 0.05 = 5% error rate
        # Used by: error rate panel and SLO calculation
        - record: namespace:http_errors:rate5m
          expr: |
            sum by (namespace) (
              rate(http_requests_total{
                job="test-app",
                status=~"5.."
              }[5m])
            )
            /
            sum by (namespace) (
              rate(http_requests_total{job="test-app"}[5m])
            )

        # Error count rate (not ratio) — used in burn-rate calculations (Demo 18)
        - record: namespace:http_errors_total:rate5m
          expr: |
            sum by (namespace) (
              rate(http_requests_total{
                job="test-app",
                status=~"5.."
              }[5m])
            )

    # ── Group 3: Latency Rules ────────────────────────────────────────────────
    - name: test_app_latency
      interval: 15s
      rules:

        # Pre-aggregated histogram buckets — the foundation for quantile rules
        # Always aggregate buckets before calculating quantiles
        # sum by (le) is required — le label must be preserved for histogram_quantile
        - record: namespace_le:http_request_duration_seconds:rate5m
          expr: |
            sum by (namespace, le) (
              rate(http_request_duration_seconds_bucket{
                job="test-app"
              }[5m])
            )

        # p50 (median) latency
        # Query the pre-aggregated buckets rule above (chained recording rules)
        - record: namespace:http_request_duration_seconds:p50rate5m
          expr: |
            histogram_quantile(
              0.50,
              namespace_le:http_request_duration_seconds:rate5m
            )

        # p90 latency
        - record: namespace:http_request_duration_seconds:p90rate5m
          expr: |
            histogram_quantile(
              0.90,
              namespace_le:http_request_duration_seconds:rate5m
            )

        # p99 latency — the most important SLO metric
        - record: namespace:http_request_duration_seconds:p99rate5m
          expr: |
            histogram_quantile(
              0.99,
              namespace_le:http_request_duration_seconds:rate5m
            )

    # ── Group 4: Saturation Rules ─────────────────────────────────────────────
    - name: test_app_saturation
      interval: 15s
      rules:

        # Memory usage as fraction of limit per pod
        # 1.0 = at memory limit, > 1.0 = over limit (OOMKill imminent)
        - record: pod:memory_saturation:ratio
          expr: |
            process_resident_memory_bytes{job="test-app"}
            /
            (64 * 1024 * 1024)

        # CPU usage fraction per pod (0 to 1, where 1 = fully using CPU limit)
        - record: pod:cpu_saturation:rate5m
          expr: |
            rate(process_cpu_seconds_total{job="test-app"}[5m])
            /
            0.1
```

**`src/recording-rules/node-rules.yaml`:**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: node-recording-rules
  namespace: monitoring
  labels:
    role: recording-rules
spec:
  groups:
    # ── Node CPU Rules ────────────────────────────────────────────────────────
    - name: node_cpu
      interval: 15s
      rules:

        # CPU busy percentage per instance
        # Pre-computed so dashboards don't recalculate this on every load
        - record: instance:node_cpu_utilisation:rate5m
          expr: |
            100 - (
              avg by (instance) (
                rate(node_cpu_seconds_total{mode="idle"}[5m])
              ) * 100
            )

        # Per-mode CPU breakdown per instance — feeds stacked CPU chart
        - record: instance_mode:node_cpu_seconds:rate5m
          expr: |
            sum by (instance, mode) (
              rate(node_cpu_seconds_total[5m])
            )

    # ── Node Memory Rules ─────────────────────────────────────────────────────
    - name: node_memory
      interval: 15s
      rules:

        # Memory utilisation as fraction (0 to 1)
        - record: instance:node_memory_utilisation:ratio
          expr: |
            1 - (
              node_memory_MemAvailable_bytes
              /
              node_memory_MemTotal_bytes
            )

    # ── Node Filesystem Rules ─────────────────────────────────────────────────
    - name: node_filesystem
      interval: 15s
      rules:

        # Disk utilisation as fraction (0 to 1)
        - record: instance_device:node_filesystem_utilisation:ratio
          expr: |
            1 - (
              node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}
              /
              node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}
            )

        # Predicted disk exhaustion time in seconds (from now)
        # When this is < 86400 (24h), disk will fill within 24h
        - record: instance_device:node_filesystem_avail:predict24h
          expr: |
            predict_linear(
              node_filesystem_avail_bytes{
                mountpoint="/",
                fstype!~"tmpfs|overlay"
              }[6h],
              24 * 3600
            )
```

Apply the recording rules:

```bash
kubectl apply -f src/recording-rules/test-app-rules.yaml
kubectl apply -f src/recording-rules/node-rules.yaml
```

Verify the PrometheusRules were created:

```bash
kubectl get prometheusrules -A
```

Expected output:
```
NAMESPACE    NAME                              AGE
default      test-app-recording-rules          30s
monitoring   node-recording-rules              30s
```

Wait 30–60 seconds for the Operator to pick up the new rules and for Prometheus
to evaluate them once. Then verify the rules are loaded in Prometheus UI:

```
http://localhost:9090/rules
```

You should see rule groups listed under "Recording Rules":
```
test_app_request_rates    (4 rules, all OK)
test_app_error_rates      (2 rules, all OK)
test_app_latency          (4 rules, all OK)
test_app_saturation       (2 rules, all OK)
node_cpu                  (2 rules, all OK)
node_memory               (1 rule,  all OK)
node_filesystem           (2 rules, all OK)
```

Now query the pre-computed recording rule metrics directly:

```promql
# These now query pre-computed series — instant results regardless of load
job:http_requests:rate5m
namespace:http_errors:rate5m
namespace:http_request_duration_seconds:p99rate5m
instance:node_cpu_utilisation:rate5m
```

```bash
# CLI: verify recording rule metrics exist in Prometheus
curl -s 'localhost:9090/api/v1/query?query=job:http_requests:rate5m' \
  | jq '.data.result[0].value[1]'
# Expected: same value as sum(rate(http_requests_total[5m])) — confirms rule is working
```

### Step 12: Validate Recording Rules with promtool

**Always validate recording rule files before applying them to production.**
`promtool` catches: invalid PromQL syntax, invalid YAML, duplicate rule names,
and unit test failures — before they reach Prometheus.

```bash
# Get the Prometheus pod name
PROM_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}')

echo "Prometheus pod: $PROM_POD"

# Verify all rules currently loaded in Prometheus are valid
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool check config /etc/prometheus/config_out/prometheus.env.yaml
```

Expected:
```
Checking /etc/prometheus/config_out/prometheus.env.yaml
  SUCCESS: X rule files found
```

**Checking a specific rules file locally (for CI/CD):**

```bash
# Extract promtool binary from the Prometheus pod
kubectl cp \
  monitoring/$PROM_POD:/bin/promtool \
  /tmp/promtool

chmod +x /tmp/promtool

# Validate the test-app recording rules
# Note: PrometheusRule CRD wraps the groups under spec.groups
# For local validation, extract just the rules portion
cat src/recording-rules/test-app-rules.yaml | \
  python3 -c "
import sys, yaml, json
doc = yaml.safe_load(sys.stdin)
groups = doc['spec']['groups']
print(yaml.dump({'groups': groups}))
" > /tmp/test-app-rules-plain.yaml

/tmp/promtool check rules /tmp/test-app-rules-plain.yaml
```

Expected:
```
Checking /tmp/test-app-rules-plain.yaml
  SUCCESS: 15 rules found
```

**What promtool catches before deployment:**

```
PromQL syntax error:
  - record: job:http_requests:rate5m
    expr: rate(http_requests_total)    # ← missing [range]
  Error: "expected type range vector in call to function 'rate'"

Invalid metric name in record:
  - record: "job http requests rate"   # ← spaces not allowed
  Error: "invalid metric name"

Duplicate rule names in same group:
  Two rules named "job:http_requests:rate5m" in the same group
  Error: "duplicate rule name"

Empty expression:
  - record: job:http_requests:rate5m
    expr: ""
  Error: "empty expression"
```

---

## Cleanup — Complete Teardown

```bash
# Step 1: Remove recording rule CRDs
kubectl delete -f src/recording-rules/test-app-rules.yaml
kubectl delete -f src/recording-rules/node-rules.yaml

# Step 2: Verify rules are removed
kubectl get prometheusrules -A

# Step 3: (Optional) Remove test-app if proceeding to Demo 03
# Keep it running if you plan to start Demo 03 immediately
kubectl delete -f ../01-prometheus-fundamentals/src/test-app/servicemonitor.yaml
kubectl delete -f ../01-prometheus-fundamentals/src/test-app/service.yaml
kubectl delete -f ../01-prometheus-fundamentals/src/test-app/deployment.yaml

# Step 4: (Optional) Tear down the full stack
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete pvc -n monitoring --all
kubectl delete namespace monitoring

# Step 5: Stop Minikube
minikube stop
```

---

## What You Learned

By completing this demo you have achieved the following objectives:

1. ✅ Explained the difference between instant vectors and range vectors precisely — and verified with real queries that a range vector cannot be displayed without applying a function
2. ✅ Used all four label matching operators (`=`, `!=`, `=~`, `!~`) including correct RE2 fully-anchored regex syntax against live test-app metrics
3. ✅ Chose between `rate()`, `irate()`, and `increase()` correctly — confirmed the difference visually in the Prometheus Graph tab and verified why `irate()` must never be used in alerting rules
4. ✅ Applied all aggregation operators with `by()` and `without()` clauses — summed across pods, found the worst-case memory pod, and audited cardinality with `topk`
5. ✅ Wrote binary operation queries for ratio calculations — error rate as a fraction, memory saturation as a percentage of limit
6. ✅ Used `offset` to compare current metrics against a historical baseline and built a dynamic threshold alert expression
7. ✅ Wrote subqueries to compute the peak 5-minute rate over a 1-hour window and detect sustained SLO breaches
8. ✅ Used `predict_linear()` for proactive disk and memory alerting — confirmed healthy system returns empty result (correct alert behaviour)
9. ✅ Calculated p50, p90, p99 latency correctly with `histogram_quantile()` and verified the multi-percentile `histogram_quantiles()` function (Prometheus 3.x)
10. ✅ Wrote recording rules following the official `level:metric:operations` Prometheus naming convention and applied them as PrometheusRule CRDs
11. ✅ Explained why recording rules improve dashboard performance — pre-computed series eliminate per-user query execution at dashboard load time
12. ✅ Validated recording rules with `promtool check rules` and understood what errors it catches before production deployment

---

## Interview Prep

**Q1. An engineer asks: "Why do we use `sum(rate(...))` instead of `rate(sum(...))`? Doesn't summing first and then rating give the same result?" How do you explain the difference?**

They are not the same — `rate(sum(...))` is wrong and will produce incorrect results when any pod restarts. `rate()` handles counter resets by detecting when a value drops and treating it as a reset. When you `sum()` first, you aggregate all pod counters into a single series. If pod A restarts and its counter resets from 50,000 to 0, the aggregate sum drops by 50,000. `rate()` sees this drop and treats it as a reset of the combined counter — but it is not a real reset of the combined counter. The other pods never reset. The result is that `rate()` overcorrects, producing an inflated or incorrect rate for the window containing the restart. `sum(rate(...))` does it correctly: `rate()` runs independently on each pod's counter, handles each pod's resets individually and accurately, and then `sum()` adds the already-correct per-second rates together. The sum of correct rates is always correct. The rate of a sum is not.

**Q2. You are reviewing an alert rule written by a junior engineer: `alert: HighErrorRate, expr: irate(http_requests_total{status=~"5.."}[5m]) > 0.1, for: 2m`. What is wrong with it and how do you fix it?**

Two problems. First, `irate()` must never be used in alerting rules. `irate()` is based on the two most recent data points — it reflects only the last 15-second interval. A momentary spike makes the expression true, the `for: 2m` clause starts counting, but the very next 15-second scrape might show normal traffic — the expression becomes false and the alert resets before the `for` duration completes. The alert flaps without ever firing. Second, the expression returns an absolute error rate (errors per second) rather than a ratio — a threshold of 0.1 errors/second means nothing without knowing total traffic. Fix: `expr: sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.01` with `for: 2m`. This uses `rate()` for stability, expresses errors as a fraction of total traffic (1% threshold), and the `for: 2m` clause now correctly fires only after 2 continuous minutes above 1% error rate.

**Q3. A Grafana dashboard with 10 panels loads in 8 seconds. Engineers have stopped trusting it because it is always slow. How do you fix this systematically?**

Start by identifying which panels are slow using the Prometheus query stats endpoint — add `?stats=true` to the query URL and look at `innerEvalTime`. Any panel query taking over 100ms is a recording rule candidate. Then create a PrometheusRule CRD with recording rules pre-computing those expressions every 15 seconds. Replace each slow panel's PromQL with the recording rule metric name — the panel now reads a single pre-computed time series instead of scanning raw TSDB data. Recording rule lookups take under 10ms regardless of how many engineers are viewing the dashboard simultaneously. For the topk queries (the slowest), either pre-compute the ranking with a recording rule or add tight label selectors to reduce the input series count before sorting. After deploying recording rules, dashboard load time should drop from 8 seconds to under 500ms for 10 panels. The key insight: dashboards should display data, not compute it.

**Q4. What is the correct `histogram_quantile()` query for p99 latency across all pods, and what are the three most common mistakes engineers make with it?**

Correct query: `histogram_quantile(0.99, sum by (le)(rate(http_request_duration_seconds_bucket{job="test-app"}[5m])))`. The three most common mistakes: (1) Missing `rate()` — using raw cumulative bucket counts gives the p99 since Prometheus started, not current p99. Always wrap in `rate()` with an appropriate window. (2) Missing `sum by (le)` — without aggregating across pods with `sum by (le)`, you get one p99 per pod instead of the aggregate p99 across all pods. The `le` label must be preserved because `histogram_quantile()` reads it to find bucket boundaries. (3) Poorly designed bucket boundaries — if your SLO is 200ms but you have no bucket near that threshold, `histogram_quantile()` interpolates across a wide range and the result is inaccurate. Always define buckets that bracket your SLO values.

**Q5. You need to build an alert that catches "unusual error rate at any time of day" — not just absolute rate above a fixed threshold. A fixed threshold of 0.1 errors/sec would miss anomalies at low-traffic 3am, and would fire constantly at high-traffic noon. What PromQL pattern solves this?**

Use the `offset` modifier to build a dynamic threshold based on historical baseline. Compare the current error rate against the same time yesterday: `rate(http_requests_total{status=~"5.."}[5m]) > 10 * rate(http_requests_total{status=~"5.."}[5m] offset 1d)`. This fires when the current error rate is 10× higher than the same time yesterday — automatically scaling with traffic. At 3am with normally 0.001 errors/sec, a spike to 0.01 fires the alert (10× increase). At noon with normally 0.05 errors/sec, the alert requires 0.5 errors/sec before firing (a genuinely significant anomaly, not normal noon traffic). The multiplier (10×) is tunable — lower values are more sensitive, higher values reduce false positives. This pattern is called a dynamic threshold or anomaly-relative alert and is significantly more production-appropriate than fixed thresholds for traffic-correlated error rates.

---

## Break-Fix Scenario

> **Rules:** No hints are given. Diagnose using only the error output shown.
> Attempt a diagnosis before opening the answer.

---

### Scenario: Recording rules applied — metrics not appearing in Prometheus after 10 minutes

You apply both PrometheusRule CRDs from Step 11. After waiting 10 minutes, you query the recording rule metrics in Prometheus UI and get no results. You run the following diagnostics:

```bash
kubectl get prometheusrules -A
```
```
NAMESPACE    NAME                       AGE
default      test-app-recording-rules   9m43s
monitoring   node-recording-rules       9m43s
```

```bash
kubectl logs -n monitoring \
  -l app.kubernetes.io/name=prometheus-operator \
  --tail=20
```
```
level=info msg="PrometheusRule selected" prometheusrule=default/test-app-recording-rules
level=info msg="PrometheusRule selected" prometheusrule=monitoring/node-recording-rules
level=info msg="Updating Prometheus configuration"
level=info msg="Reloading Prometheus" url=http://prometheus-operated:9090/-/reload
level=info msg="Prometheus reloaded"
```

```bash
# Check rules loaded in Prometheus
curl -s localhost:9090/api/v1/rules | jq '.data.groups[].name' | grep -E "test_app|node_"
```
```
(no output)
```

```bash
helm get values kube-prometheus-stack -n monitoring | grep -A2 ruleSelector
```
```
ruleSelectorNilUsesHelmValues: true
```

```bash
kubectl get prometheusrule test-app-recording-rules -n default -o jsonpath='{.metadata.labels}'
```
```
{"app":"test-app","role":"recording-rules"}
```

**What is wrong and what is the fix?**

<details>
<summary>Answer</summary>

**Root cause:** `ruleSelectorNilUsesHelmValues: true` is set in the Helm values. This means Prometheus only loads PrometheusRules that carry the label `release: kube-prometheus-stack`. Both PrometheusRule CRDs are missing this label — so the Operator selects them (it processes all CRDs cluster-wide) and reloads Prometheus, but Prometheus then filters them out at rule loading time using its own selector. The rules are never actually loaded.

**Evidence trail:**
- PrometheusRules exist in both namespaces ✅
- Operator selected both and reloaded Prometheus ✅
- Operator logs show no errors ✅
- `curl /api/v1/rules` shows no matching rule groups ← rules were rejected by selector
- `ruleSelectorNilUsesHelmValues: true` ← the cause
- Missing label `release: kube-prometheus-stack` on both CRDs ← confirms it

**Fix option 1 — Change the Helm value (recommended):**

Update `src/values.yaml`:
```yaml
prometheus:
  prometheusSpec:
    ruleSelectorNilUsesHelmValues: false  # was true — discover all PrometheusRules
```

```bash
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version 84.5.0 \
  -n monitoring \
  -f src/values.yaml
```

**Fix option 2 — Add the required label to the CRDs:**

```bash
kubectl label prometheusrule test-app-recording-rules -n default \
  release=kube-prometheus-stack

kubectl label prometheusrule node-recording-rules -n monitoring \
  release=kube-prometheus-stack
```

**Verify after fix:**

```bash
# Wait 30 seconds then check
curl -s localhost:9090/api/v1/rules \
  | jq '.data.groups[].name' | grep -E "test_app|node_"
```

Expected:
```
"test_app_request_rates"
"test_app_error_rates"
"test_app_latency"
"test_app_saturation"
"node_cpu"
"node_memory"
"node_filesystem"
```

```bash
# Confirm recording rule metric is now queryable
curl -s 'localhost:9090/api/v1/query?query=job:http_requests:rate5m' \
  | jq '.data.result[0].value[1]'
# Expected: a numeric string — recording rule is evaluating successfully
```

</details>

---

## Key Takeaways

1. **PromQL has exactly two data types: instant vectors and range vectors — and every query error comes from confusing them.** An instant vector is one value per series right now; a range vector is multiple values per series over a time window. Range vectors cannot be displayed or aggregated directly — they must be passed to a function (`rate()`, `max_over_time()`, etc.) that reduces them back to an instant vector first.

2. **`rate()` for alerts, `irate()` for spike debugging, `increase()` for count reporting — never swap them.** `irate()` in an alert rule causes flapping because it reflects only the last two data points. A momentary spike fires the alert and the next scrape resolves it before the `for` clause completes. `rate()` smooths over the full window, making alerts stable and non-flapping.

3. **Always `sum(rate(...))` — never `rate(sum(...))`.** Summing counters before applying `rate()` hides individual pod counter resets inside the aggregate. When a pod restarts, the aggregated counter drops and `rate()` misinterprets the reset, producing an incorrect inflated rate. `rate()` must always be the innermost function applied to individual counter series.

4. **`histogram_quantile()` requires `rate()` + `sum by (le)` — both are mandatory.** Without `rate()`, you get the p99 since Prometheus started (useless for current SLO tracking). Without `sum by (le)`, you get per-pod p99 instead of the aggregate across all pods. The `le` label must survive the aggregation because `histogram_quantile()` reads it to identify bucket boundaries.

5. **Recording rules are not optional for production dashboards — they are the only way to keep dashboards fast under load.** A `sum(rate(...))` query that takes 200ms per user × 10 engineers = 2 seconds of Prometheus CPU per dashboard refresh. The same query as a recording rule: computed once every 15 seconds, read in under 10ms by any number of concurrent users.

6. **The official recording rule naming convention `level:metric:operations` is not style — it is documentation.** `namespace:http_request_duration_seconds:p99rate5m` tells every engineer reading it exactly what label set it uses, what underlying metric it derives from, and what operations were applied. Unambiguous names prevent duplicate rules and incorrect dashboard queries.

7. **`ruleSelectorNilUsesHelmValues: true` silently rejects PrometheusRules without the Helm release label — the Operator logs success while Prometheus never loads the rules.** This is the most common recording rule and alerting rule "disappearance" bug in production. The Operator and Prometheus have independent selectors; the Operator processes all CRDs but Prometheus applies its own label filter. Always set `ruleSelectorNilUsesHelmValues: false` in multi-team environments and control access via RBAC on the `prometheusrules` resource.

8. **`predict_linear()` fires before the problem occurs — a negative predicted value means exhaustion is imminent, an empty result means the system is healthy.** Understanding that an alert expression returning no data means the condition is false (not broken) is fundamental to reading Prometheus alert rules correctly.

9. **RE2 regex in Prometheus is always fully anchored — the pattern must match the entire label value, not just a substring.** `status=~"5"` does not match `"500"`. `status=~"5.."` matches exactly three-character strings starting with 5. This surprises engineers coming from other regex flavours where partial matching is the default.

---

## Quick Commands Reference

| What | Command |
|---|---|
| Port-forward Prometheus UI | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` |
| Apply recording rules | `kubectl apply -f src/recording-rules/test-app-rules.yaml` |
| List all PrometheusRules | `kubectl get prometheusrules -A` |
| View rules in Prometheus | `http://localhost:9090/rules` |
| Validate rules with promtool | `kubectl exec -n monitoring <pod> -c prometheus -- promtool check rules <file>` |
| Check rule selector setting | `helm get values kube-prometheus-stack -n monitoring \| grep ruleSelectorNilUsesHelmValues` |
| Query with timing stats | `curl 'localhost:9090/api/v1/query?query=<expr>&stats=true' \| jq '.data.stats.timings'` |
| Check active targets | `curl -s localhost:9090/api/v1/targets \| jq '.data.activeTargets[] \| {job: .labels.job, health: .health}'` |
| TSDB cardinality check | `curl -s 'localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' \| jq '.data.result[0].value[1]'` |

**Quick Reference — PromQL Cheat Sheet**

```
SELECTORS
  metric{label="value"}             exact match
  metric{label!="value"}            exclude
  metric{label=~"regex"}            regex match (RE2, fully anchored)
  metric{label!~"regex"}            negative regex
  metric[5m]                        range vector (5 minute window)
  metric offset 1h                  shift 1 hour back in time
  metric @ 1735689600               value at specific Unix timestamp

FUNCTIONS — counters
  rate(counter[5m])                 per-second avg rate, handles resets, smoothed
  irate(counter[5m])                per-second rate from last 2 points, reactive
  increase(counter[1h])             total increase over window (not per-second)

FUNCTIONS — gauges
  delta(gauge[5m])                  change in value over window
  deriv(gauge[5m])                  per-second derivative (slope)
  avg_over_time(gauge[5m])          average value over window
  max_over_time(gauge[5m])          maximum value over window
  min_over_time(gauge[5m])          minimum value over window
  predict_linear(gauge[6h], 86400)  predict value N seconds in the future

FUNCTIONS — histograms
  histogram_quantile(0.99, rate(bucket[5m]))        p99 latency
  histogram_quantiles("p", buckets, 0.5, 0.9, 0.99) multiple quantiles (Prom 3.x)

AGGREGATIONS
  sum by (label)(expr)              sum, keep listed labels
  sum without (label)(expr)         sum, drop listed labels
  avg by (label)(expr)              arithmetic mean
  max by (label)(expr)              maximum value
  min by (label)(expr)              minimum value
  count by (label)(expr)            count matching series
  topk(5, expr)                     top 5 series by value
  bottomk(5, expr)                  bottom 5 series by value
  quantile(0.95, expr)              p95 across series (not within histogram)

SUBQUERIES
  max_over_time(rate(counter[5m])[1h:5m])    max of 5m rate over 1h window

BINARY OPERATORS
  + - * / %                         arithmetic
  == != > < >= <=                   comparison (filter or bool)
  and or unless                     logical
  on(labels)                        match only on these labels
  ignoring(labels)                  match on everything except these labels
  group_left(labels)                many-to-one matching (left has more)
  group_right(labels)               many-to-one matching (right has more)

RECORDING RULE NAMING
  level:metric:operations
  job:http_requests:rate5m
  namespace_pod:http_request_duration_seconds:p99rate5m
```

---

## Next Demo

**Demo 03 — Loki Architecture & Grafana Alloy Log Collection**

With metrics fully mastered, Demo 03 introduces the second observability pillar:
logs. You will deploy Grafana Loki and Grafana Alloy, configure Alloy as a
DaemonSet to collect all pod logs from the Kubernetes node's container runtime,
and learn how Loki's label-based index model differs fundamentally from
full-text search systems like Elasticsearch.

---

## References

| Resource | URL |
|---|---|
| PromQL Basics — Official Docs | https://prometheus.io/docs/prometheus/latest/querying/basics/ |
| PromQL Operators — Official Docs | https://prometheus.io/docs/prometheus/latest/querying/operators/ |
| PromQL Functions — Official Docs | https://prometheus.io/docs/prometheus/latest/querying/functions/ |
| Recording Rules — Official Docs | https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/ |
| Recording Rule Naming Convention | https://prometheus.io/docs/practices/rules/ |
| Histogram and Summary Best Practices | https://prometheus.io/docs/practices/histograms/ |
| irate() vs rate() — Official Guidance | https://prometheus.io/docs/prometheus/latest/querying/functions/#irate |
| Google SRE Book — Alerting on SLOs | https://sre.google/workbook/alerting-on-slos/ |
| Prometheus 3.x histogram_quantiles() | https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantiles |

---

## Appendix — Anki Cards

**02-promql-anki.csv:**

```
#deck:Opensource Observability Labs::Phase 1 - Foundations::02-promql
#separator:Comma
#columns:Front,Back,Tags
"What is the difference between an instant vector and a range vector in PromQL? Give an example of each.","Instant vector: one value per time series at a single point in time. Example: `http_requests_total` — returns the current counter value per series. Range vector: multiple values per time series over a time window. Example: `http_requests_total[5m]` — returns all samples for each series in the last 5 minutes. Range vectors cannot be displayed or aggregated directly — they must be passed to a function (rate(), max_over_time(), etc.) that reduces them to an instant vector.","demo02,vectors,fundamentals"
"You write `sum(http_requests_total[5m])` and get an error. What is wrong and what is the fix?","Error: 'expected type instant vector in aggregation expression'. `sum()` is an aggregation operator that works on instant vectors. `http_requests_total[5m]` is a range vector — it has multiple values per series. Fix: apply a function first to reduce the range vector to an instant vector: `sum(rate(http_requests_total[5m]))`. The correct order is always: range vector → function → instant vector → aggregation.","demo02,vectors,aggregation,errors"
"Why must you never use `irate()` in alerting rules? What should you use instead?","irate() uses only the two most recent data points. A momentary spike makes the expression true, starting the `for:` clause. The next 15-second scrape may show normal traffic — the expression becomes false and the alert resets before the `for` duration completes. The alert flaps endlessly without ever firing. Use rate() instead: it uses all data points in the range window, smooths brief spikes, and produces stable values that allow the `for:` clause to complete. Official Prometheus documentation states: use rate() for alerting.","demo02,irate,rate,alerting"
"What is wrong with `rate(sum(http_requests_total)[5m])`? What is the correct form?","When a pod restarts and its counter resets to zero, the summed aggregate counter also drops. rate() detects this drop and treats it as a counter reset of the combined counter — but it is not. The other pods never reset. rate() overcorrects, producing an inflated or incorrect rate. Correct form: `sum(rate(http_requests_total[5m]))`. rate() runs independently on each pod's counter, handles each pod's resets individually and accurately, then sum() adds the correct per-pod rates. Rule: rate() must always be the innermost function applied to individual counter series.","demo02,rate,sum,counter-resets"
"Write the correct PromQL query for p99 request latency across all pods. What are the two mandatory components?","Correct query: `histogram_quantile(0.99, sum by (le)(rate(http_request_duration_seconds_bucket{job=~'serviceMonitor/default/test-app/.*'}[5m])))`. Two mandatory components: (1) rate() — converts cumulative bucket counts to per-second rates; without it you get p99 since Prometheus started, not current p99. (2) sum by (le) — aggregates across all pods while preserving the le label; without it you get per-pod p99 instead of aggregate p99. histogram_quantile() reads the le label to identify bucket boundaries — it must survive the aggregation.","demo02,histogram_quantile,p99,latency"
"What does `ruleSelectorNilUsesHelmValues: true` do and why does it cause recording rules to silently disappear?","When true, Prometheus only loads PrometheusRules that carry the label `release: kube-prometheus-stack` (the Helm release name). PrometheusRules without this label are silently rejected at Prometheus rule loading time. The Prometheus Operator processes all PrometheusRules cluster-wide and logs success — but Prometheus itself applies a separate label filter and never loads the rules. No error is shown. Fix: set `ruleSelectorNilUsesHelmValues: false` to discover all PrometheusRules cluster-wide, and control access via RBAC on the prometheusrules resource.","demo02,recording-rules,selector,troubleshooting"
"What is the official Prometheus recording rule naming convention? Give an example for p99 latency aggregated by namespace.","Format: `level:metric:operations` where level = label set of the output (what labels remain after aggregation), metric = underlying metric name (drop _total suffix for counters), operations = functions applied newest first. Example for p99 latency aggregated by namespace: `namespace:http_request_duration_seconds:p99rate5m`. Breakdown: namespace = only namespace label is kept in the output, http_request_duration_seconds = the metric, p99rate5m = p99 quantile of the rate over 5 minutes (outermost operation listed first).","demo02,recording-rules,naming-convention"
"What is the `offset` modifier and how do you use it for dynamic threshold alerting?","offset shifts a query's time range backwards. `rate(http_requests_total[5m] offset 1d)` returns the request rate from 24 hours ago. For dynamic threshold alerting: `rate(http_requests_total{status=~'5..'}[5m]) > 10 * rate(http_requests_total{status=~'5..'}[5m] offset 1d)` fires when the current error rate is 10× higher than the same time yesterday. This automatically scales with traffic — at 3am it catches small anomalies that a fixed threshold would miss; at peak noon it requires a truly significant spike before firing.","demo02,offset,dynamic-threshold,alerting"
"What is a subquery in PromQL? Write a query that finds the peak 5-minute request rate over the last hour.","A subquery evaluates an instant vector expression at multiple points in the past, producing a range of values for a range function to operate on. Syntax: `<expr>[<range>:<resolution>]`. Peak 5-minute request rate over the last hour: `max_over_time(sum(rate(http_requests_total[5m]))[1h:5m])`. This evaluates `sum(rate(...[5m]))` at 5-minute intervals going back 1 hour (12 evaluations), then max_over_time() finds the highest value across those 12 points. Use cases: capacity planning, SLO burn rate analysis, detecting whether a threshold was breached at any point in a window.","demo02,subqueries,max_over_time"
"What does `predict_linear(node_filesystem_avail_bytes{mountpoint='/'}[6h], 4*3600) < 0` mean in an alert?","This fires when the predicted available disk space 4 hours from now (based on the last 6 hours of trend) is negative — meaning the disk will be completely full before 4 hours have passed at the current rate of consumption. `predict_linear()` uses linear regression on the gauge metric values over the range window [6h] to extrapolate forward `seconds_ahead` (4×3600 = 14,400 seconds). A negative predicted value means the trend line crosses zero before that time. The alert fires proactively — before the disk fills — giving time to act. Empty result from this alert expression means the disk is not filling at a rate that would exhaust it within 4 hours.","demo02,predict_linear,proactive-alerting,disk"
"Prometheus uses RE2 regex for label matching. How does this differ from standard regex and what are two common mistakes?","RE2 is always fully anchored — the regex must match the entire label value, not just find a match within it. Standard regex flavours default to partial matching. Common mistakes: (1) `status=~'5'` — does NOT match '500'; the pattern '5' must equal the entire label value. Correct: `status=~'5..'` to match three-character strings starting with 5. (2) `namespace=~'prod'` — does NOT match 'production'; use `namespace=~'prod.*'` to match production and any value starting with prod. RE2 special characters that must be escaped: . * + ? ( ) [ ] { } | ^ $ \\","demo02,regex,re2,label-selectors"
"What is the query performance hierarchy in Prometheus from fastest to slowest? Where do recording rules fit?","From fastest to slowest: (1) Recording rule lookups < 10ms — reads pre-computed series. (2) Exact metric + exact label match 10–50ms — uses inverted index. (3) Aggregations with by/without 50–200ms — O(n) linear scan. (4) Regex label selectors 100–500ms — cannot use index, scans all series. (5) topk/bottomk/quantile 200ms–2s — O(n log n) sort required. (6) Cross-metric binary operations 300ms–5s. (7) Full cardinality scans ({__name__=~'.+'}) — seconds, touches all series. Recording rules pre-compute at category 1 speed — a dashboard query that takes 500ms raw becomes < 10ms via a recording rule.","demo02,performance,recording-rules,query-optimization"
```

---

## Appendix — Quiz

**02-promql-quiz.md:**

````markdown
# Quiz — Demo 02: PromQL — From Selectors to Production-Grade Queries

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to Demo 03.

| Score | Action |
|---|---|
| 100% | Import Anki CSV and move to Demo 03 |
| 80–90% | Review wrong answers, then proceed |
| 60–70% | Re-read relevant sections, retry quiz |
| Below 60% | Re-read full demo before proceeding |

---

**Q1. You run `sum(http_requests_total[5m])` in Prometheus and get an error. What is the error and what is the correct fix?**

A. Error: "range too long" — reduce the window to `[1m]`
B. Error: "expected type instant vector" — fix: `sum(rate(http_requests_total[5m]))`
C. Error: "metric not found" — verify the metric name with a selector-only query first
D. Error: "label selector required" — add a job label to the selector

<details>
<summary>Answer</summary>

**B** — `sum()` is an aggregation operator that works on instant vectors. `http_requests_total[5m]` is a range vector — it returns multiple samples per series over a time window. To aggregate it, first apply `rate()` to convert the range vector to an instant vector (per-second rates), then `sum()` across the instant vector: `sum(rate(http_requests_total[5m]))`.

Trap A: There is no "range too long" error for this situation. Trap C: The metric exists — the error is about the wrong data type. Trap D: Label selectors are optional — the error is about vector type mismatch.

</details>

---

**Q2. A junior engineer writes this alert rule: `expr: irate(http_requests_total{status=~"5.."}[5m]) > 0.1`. What is wrong?**

A. `irate()` should be `rate()` — irate is not valid in PrometheusRule CRDs
B. The range `[5m]` is too short for irate — it requires at least `[15m]`
C. `irate()` in alerting rules causes flapping because it uses only the last 2 data points — a momentary spike fires then resolves before the `for:` clause completes
D. The threshold `0.1` is wrong — irate() returns values between 0 and 1

<details>
<summary>Answer</summary>

**C** — `irate()` uses only the two most recent data points (the last 15-second interval). A momentary spike makes the expression exceed 0.1, starting the `for:` clause. The next scrape at 15 seconds might show normal traffic — the condition becomes false and the alert resets before completing the `for:` duration. The alert fires and resolves endlessly without ever triggering a notification. Use `rate()` which uses all data points in the window and smooths brief spikes.

Trap A: `irate()` is syntactically valid in PrometheusRule CRDs — it is a semantic/behavioural problem, not a validity problem. Trap B: The range in `irate()` only determines how far back to look for the two most recent points — its length does not fix the flapping problem. Trap D: `irate()` returns a per-second rate — there is no 0–1 constraint.

</details>

---

**Q3. Which of these expressions correctly calculates the total request rate across 3 pods, handling counter resets from pod restarts correctly?**

A. `rate(sum(http_requests_total{job="test-app"})[5m])`
B. `sum(http_requests_total{job="test-app"}[5m])`
C. `sum(rate(http_requests_total{job="test-app"}[5m]))`
D. `rate(http_requests_total{job="test-app"}[5m]) * 3`

<details>
<summary>Answer</summary>

**C** — `sum(rate(...))` is the correct order. `rate()` runs independently on each pod's counter series, handles each pod's counter reset individually and accurately, then `sum()` adds the correct per-pod per-second rates together.

Trap A: `rate(sum(...))` sums all counters into one aggregate first. When any pod restarts and its counter resets, the aggregate drops and `rate()` misinterprets the entire aggregate as having reset — producing an incorrect inflated rate. Trap B: `sum()` cannot operate on a range vector directly — error. Trap D: Multiplying by 3 assumes exactly equal load across pods, which is never guaranteed, and does not handle counter resets correctly.

</details>

---

**Q4. You query `http_requests_total{status=~"5"}` expecting to see 500 errors. The result is empty despite 500 errors existing in Prometheus. What is wrong?**

A. The `=~` operator requires at least 3 characters in the pattern
B. Prometheus RE2 regex is fully anchored — `"5"` must match the entire label value, so it matches only the exact string `"5"`, not `"500"`
C. Status codes are stored as integers in Prometheus, not strings — use `status=500` instead
D. The `=~` operator requires the `g` flag for global matching — use `status=~"5/g"`

<details>
<summary>Answer</summary>

**B** — Prometheus uses RE2 regex which is always fully anchored. The pattern `"5"` must equal the entire label value — it matches only a status label containing exactly the single character `"5"`. To match 500, 501, 502, etc., use `status=~"5.."` (starts with 5, followed by any two characters) or `status=~"5[0-9]{2}"` for precision.

Trap A: There is no minimum character requirement in Prometheus regex. Trap C: All Prometheus label values are strings — status codes are stored and matched as strings. Trap D: RE2 has no flags syntax in PromQL label selectors.

</details>

---

**Q5. After applying PrometheusRule CRDs for recording rules, the Prometheus Operator logs show "PrometheusRule selected" and "Prometheus reloaded" — but `http://localhost:9090/rules` shows no new rule groups. What is the most likely cause?**

A. The PrometheusRule namespace does not match the monitoring namespace
B. `ruleSelectorNilUsesHelmValues: true` — Prometheus filters out rules without the `release: kube-prometheus-stack` label
C. The PrometheusRule CRD version is incompatible with the current Operator version
D. Recording rules require a Prometheus restart, not just a reload

<details>
<summary>Answer</summary>

**B** — The Operator and Prometheus have independent selectors. The Operator processes all PrometheusRules cluster-wide (which is why it logs "selected" and "reloaded"). But when `ruleSelectorNilUsesHelmValues: true`, Prometheus itself applies a label filter — only loading PrometheusRules that carry `release: kube-prometheus-stack`. Rules without that label are rejected at Prometheus rule loading time. No error is logged. Fix: set `ruleSelectorNilUsesHelmValues: false` in values.yaml and upgrade.

Trap A: PrometheusRules can be in any namespace — the Operator discovers them cluster-wide. Trap C: CRD version compatibility would surface as a different error during `kubectl apply`. Trap D: Prometheus supports hot config reload via `/-/reload` — no restart needed or correct.

</details>

---

**Q6. What does `predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4 * 3600) < 0` mean when it returns an empty result?**

A. The metric is missing — Node Exporter is not scraping the root filesystem
B. The disk has already filled — the alert should have fired earlier
C. The condition is false — the disk is not predicted to fill within 4 hours at the current trend (correct, healthy behaviour)
D. predict_linear() returned a NaN — the trend data is insufficient

<details>
<summary>Answer</summary>

**C** — In Prometheus, a comparison operator filters the result. `< 0` keeps only series where the predicted value is negative (disk will be exhausted). When the predicted available bytes in 4 hours is positive (disk has space remaining), the condition is false — the series is dropped from the result. Empty result = alert not firing = system is healthy. This is the correct and expected behaviour for a well-functioning system.

Trap A: If the metric were missing, the query would return no data regardless of the comparison — but you would verify with `node_filesystem_avail_bytes` directly. Trap B: An already-full disk would show current available bytes near 0, and predict_linear() would return a small negative value, making the alert fire — not disappear. Trap D: NaN results from predict_linear() produce no output, but the question states the system is healthy — insufficient data would be a different diagnostic scenario.

</details>

---

**Q7. You want p99 latency across all pods. Which expression is correct?**

A. `histogram_quantile(0.99, http_request_duration_seconds_bucket[5m])`
B. `quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))`
C. `histogram_quantile(0.99, sum by (le)(rate(http_request_duration_seconds_bucket[5m])))`
D. `histogram_quantile(0.99, rate(sum(http_request_duration_seconds_bucket)[5m]))`

<details>
<summary>Answer</summary>

**C** — This is the correct full expression. `rate()` converts cumulative bucket counts to per-second rates (required — without it you get p99 since startup). `sum by (le)` aggregates across all pods while preserving the `le` label (required — `histogram_quantile()` reads `le` to find bucket boundaries). `histogram_quantile(0.99, ...)` then interpolates to estimate the 99th percentile.

Trap A: Missing `rate()` — uses raw cumulative counts, giving p99 since Prometheus started. Trap B: `quantile()` is an aggregation operator for computing quantiles across multiple time series (e.g. p99 across pod memory values) — it does not calculate latency percentiles from histogram buckets. Trap D: `rate(sum(...))` sums all bucket values first then rates — same counter reset problem as with regular counters, plus sum destroys the per-le bucket structure needed by `histogram_quantile()`.

</details>

---

**Q8. A Grafana dashboard with 8 panels loads in 6 seconds for each engineer. There are 15 engineers on the team. What is the correct systematic fix?**

A. Increase Prometheus memory to reduce query time
B. Reduce the dashboard time range from 24h to 1h to scan less data
C. Create recording rules that pre-compute each panel's expression and update the panels to query the recording rule metrics
D. Shard Prometheus into multiple instances — one per engineer team

<details>
<summary>Answer</summary>

**C** — Recording rules pre-compute each panel's PromQL expression every 15 seconds and store the result as a new time series. Dashboard panels query the pre-computed series instead of re-computing against raw TSDB data on every load. Recording rule lookups take under 10ms regardless of number of concurrent users — 15 engineers loading simultaneously no longer means 15 × 8 × 500ms = 60 seconds of concurrent Prometheus CPU. Dashboard load time drops from 6 seconds to under 500ms.

Trap A: More memory does not reduce query computation time — it reduces OOM risk. Query speed is CPU-bound and data-scan-bound. Trap B: Reducing the time range helps slightly but does not solve the root problem of concurrent expensive computation — it also makes the dashboard less useful. Trap D: Sharding adds operational complexity and is the wrong tool for dashboard latency — recording rules solve this problem at the query layer.

</details>

````