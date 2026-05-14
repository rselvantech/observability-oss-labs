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

**Demo 01 must be complete.** This demo requires:
- `kube-prometheus-stack` v84.5.0 running in the `monitoring` namespace
- `test-app` (podinfo v6.7.1) running in the `default` namespace with its ServiceMonitor
- Prometheus UI accessible at `http://localhost:9090`

If you tore down Demo 01, re-run Steps 1–9 from Demo 01 README before proceeding.

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

## Versions Used in This Demo

All versions are inherited from the Demo 01 installation.

| Component | Version |
|---|---|
| kube-prometheus-stack | **84.5.0** |
| Prometheus | **3.4.1** |
| podinfo (test-app) | **6.7.1** |

---

## Lab Objectives

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
├── README.md                            ← this file
└── src/
    └── recording-rules/
        ├── test-app-rules.yaml          ← PrometheusRule CRD with recording rules
        └── node-rules.yaml              ← PrometheusRule CRD for node metrics
```

---

## Architecture — How PromQL Queries Flow

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

---

## Part 1: Instant Vectors vs Range Vectors — The Core Mental Model

This is the single most important concept in PromQL. Everything else builds on it.

### Instant Vector

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

### Range Vector

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

### Why This Distinction Matters for Every Query You Write

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

---

## Part 2: Label Selectors and Matching Operators

Label selectors filter which time series a query operates on.
Using them precisely is the difference between a query that returns the right
data and one that silently returns too much or too little.

### The Four Matching Operators

```
Operator  Name               Behaviour
────────────────────────────────────────────────────────────────
=         Exact match        Label value equals this string exactly
!=        Not equal          Label value does NOT equal this string
=~        Regex match        Label value matches this RE2 regex
!~        Negative regex     Label value does NOT match this RE2 regex
```

### Exact Match `=`

```promql
http_requests_total{method="GET"}
```

```
Matches only time series where method label is exactly "GET"
Case sensitive — "get" would not match
Most efficient selector — Prometheus can use its inverted index directly
Use exact match whenever you know the precise value
```

### Not Equal `!=`

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

### Regex Match `=~`

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

### Combining Multiple Selectors

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

### The `__name__` Internal Label

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

---

## Part 3: rate(), irate(), increase() — The Maths, Differences, and When to Use Each

These three functions are the most frequently used and most frequently misused
functions in PromQL. Understanding the exact maths behind each one is mandatory.

### How Counters Work — What These Functions Operate On

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

### rate() — Per-Second Average Rate Over the Full Window

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

**When to use `rate()`:**

```
✅  Dashboard panels — smooth lines that show trends clearly
✅  Alerting rules — rate() never causes alert flapping from momentary spikes
    "Use rate for alerts" — official Prometheus documentation
✅  Slow-moving counters where smoothing is appropriate
✅  Aggregations: always sum(rate(...)) not rate(sum(...))
✅  Golden signal Traffic: sum(rate(http_requests_total[5m]))
✅  Golden signal Errors: rate(http_requests_total{status=~"5.."}[5m])
```

### irate() — Instantaneous Rate From Last Two Data Points Only

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

**When to use `irate()`:**

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

### rate() vs irate() — Visual Comparison

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

### increase() — Total Count of New Events Over a Window

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

**When to use `increase()`:**

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

### The Decision Table

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

---

## Part 4: Aggregation Operators — Reducing Many Series to Fewer

Aggregation operators take a set of time series (instant vector) and
collapse them into fewer series based on label grouping.

### The Two Grouping Clauses: by() and without()

```
by(label1, label2, ...)    Keep only these labels — drop all others
without(label1, label2, .) Keep all labels EXCEPT these — drop these

by() and without() are inverses of each other.
Use by() when you know exactly which labels you want to keep.
Use without() when you want to drop one or two noisy labels (like instance).
```

### sum — Add Values Together

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

### avg — Arithmetic Mean

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

### max and min — Extremes

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

### count — How Many Series Match

```promql
# How many pods are running per namespace
count by (namespace) (kube_pod_info)

# How many pods are NOT ready (0 = ready, 1 = not ready)
count(kube_pod_status_ready{condition="true"} == 0)

# Top 10 metrics by series count — cardinality audit
topk(10, count by (__name__) ({__name__=~".+"}))
```

### topk and bottomk — Ranking

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
    BEST:   Use a recording rule (see Part 7)
```

### quantile — Distribution Across Series

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

---

## Part 5: Binary Operations — Arithmetic, Comparison, and Logical

Binary operations combine two vectors with element-wise operations.
This is how you compute ratios, percentages, and conditional filtering.

### Arithmetic Binary Operations

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

### Comparison Operators — Filtering by Value

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

### Logical Operators — and, or, unless

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

### Vector Matching — on() and ignoring()

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

---

## Part 6: The offset Modifier — Comparing Past and Present

`offset` shifts the time range of a query backwards in time. This enables
week-over-week comparisons, trend analysis, and baseline alerting.

### Basic offset Usage

```promql
# Request rate right now
rate(http_requests_total[5m])

# Request rate from 1 hour ago
rate(http_requests_total[5m] offset 1h)

# Request rate from exactly 1 week ago
rate(http_requests_total[5m] offset 1w)
```

### Week-over-Week Traffic Comparison

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

### Baseline Alerting with offset

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

### The @ Modifier — Pin to a Specific Timestamp

```promql
# What was the request rate at exactly midnight UTC today?
rate(http_requests_total[5m] @ 1735689600)
```

```
@ takes a Unix timestamp (seconds since epoch)
Useful for: post-incident analysis, reproducible queries, SLO reports
Less common than offset but important for forensic investigations
```

---

## Part 7: Subqueries — Computing Rates Over Rates

Subqueries let you apply a range function (like `max_over_time`) to the
result of another expression that itself produces a range of values.
This is how you answer questions like "what was the maximum 5-minute
rate over the last hour?"

### Subquery Syntax

```
<expr>[<range>:<resolution>]
  expr:        any PromQL instant vector expression
  range:       how far back to evaluate the expression
  resolution:  how frequently to evaluate (optional — defaults to evaluation_interval)
```

### Example 1 — Maximum Rate in the Last Hour

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

### Example 2 — Detecting Sustained High Error Rate

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

### Example 3 — Smoothed Spike Detection

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

---

## Part 8: predict_linear() — Proactive Capacity Alerting

`predict_linear()` extrapolates the current trend of a gauge metric forward
in time using linear regression. This is how you build "disk full in X hours"
alerts before the disk actually fills.

### Syntax

```
predict_linear(gauge_metric[range], seconds_ahead)
  range:         how much historical data to use for the regression (gauge metric)
  seconds_ahead: how many seconds into the future to predict
```

### Disk Space Exhaustion Alert

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

### Memory Pressure Prediction

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

---

## Part 9: histogram_quantile() — Correct Latency Percentiles

`histogram_quantile()` calculates approximate quantiles (p50, p90, p99, etc.)
from histogram bucket data. This is how you measure SLO compliance.

### Syntax

```
histogram_quantile(φ, buckets)
  φ:       the quantile to calculate (0 to 1, e.g. 0.99 for p99)
  buckets: a range vector expression that produces histogram _bucket series
```

### p99 Latency — The Most Important Latency Query

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

### Multiple Percentiles in One Query

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

### Common Mistakes with histogram_quantile()

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

---

## Part 10: Recording Rules — Pre-Computing Expensive Queries

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

### Building Recording Rules — Step by Step

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
            rate(http_requests_total{job="default/test-app/0"}[5m])

        # Total request rate aggregated across all pods, per namespace
        # Level: namespace label only
        # Used by: traffic golden signal panel
        - record: namespace:http_requests:rate5m
          expr: |
            sum by (namespace) (
              rate(http_requests_total{job="default/test-app/0"}[5m])
            )

        # Total request rate — single number across everything
        # Level: no labels (fully aggregated)
        # Used by: top-level traffic stat panel
        - record: job:http_requests:rate5m
          expr: |
            sum(rate(http_requests_total{job="default/test-app/0"}[5m]))

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
                job="default/test-app/0",
                status=~"5.."
              }[5m])
            )
            /
            sum by (namespace) (
              rate(http_requests_total{job="default/test-app/0"}[5m])
            )

        # Error count rate (not ratio) — used in burn-rate calculations (Demo 18)
        - record: namespace:http_errors_total:rate5m
          expr: |
            sum by (namespace) (
              rate(http_requests_total{
                job="default/test-app/0",
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
                job="default/test-app/0"
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
            process_resident_memory_bytes{job="default/test-app/0"}
            /
            (64 * 1024 * 1024)

        # CPU usage fraction per pod (0 to 1, where 1 = fully using CPU limit)
        - record: pod:cpu_saturation:rate5m
          expr: |
            rate(process_cpu_seconds_total{job="default/test-app/0"}[5m])
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

---

## Part 11: Validate Recording Rules with promtool

**Always validate recording rule files before applying them to production.**
`promtool` catches: invalid PromQL syntax, invalid YAML, duplicate rule names,
and unit test failures — before they reach Prometheus.

```bash
# Get the Prometheus pod name
PROM_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}')

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

## Part 12: PromQL Performance — What Makes Queries Slow

### Query Performance Hierarchy (fastest to slowest)

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

### Optimisation Rules

```
Rule 1: Reduce before you compute
  SLOW:  sum(rate(http_requests_total[5m]))   # rate on all series, then sum
         Actually fine — rate then sum is correct

  SLOW:  rate(sum(http_requests_total)[5m])   # WRONG and slow
         Sums all counters together, then rates the sum
         Counter resets from different pods are hidden in the sum
         This gives incorrect results AND is slower

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

---

## Lessons Learned

### Always aggregate inside rate(), never outside

```
WRONG (most common mistake in production):
  rate(sum(http_requests_total)[5m])

  This sums the counter values first across all pods into one series,
  then calculates the rate of that aggregated counter.
  When any individual pod restarts and its counter resets to zero,
  the aggregate counter also drops suddenly.
  rate() handles the reset, but the calculation is now inaccurate —
  the reset from one pod appears as if ALL pods reset.

CORRECT:
  sum(rate(http_requests_total[5m]))

  This calculates the rate per pod first (handling each pod's resets
  individually and correctly), then sums the per-pod rates together.
  Each pod's counter resets are handled independently.
  The sum is always accurate.

Rule: rate() and irate() must always be the innermost function.
      Never apply them to an already-aggregated counter.
```

### Recording Rule Dependencies — Order Matters Within a Group

```
Within one rule group, rules execute sequentially.
A rule can reference the output of a previous rule in the same group.

Example — chained rules (CORRECT, second rule uses first rule's output):
  - record: namespace_le:http_request_duration_seconds:rate5m
    expr: sum by (namespace, le)(rate(http_request_duration_seconds_bucket[5m]))

  - record: namespace:http_request_duration_seconds:p99rate5m
    expr: histogram_quantile(0.99, namespace_le:http_request_duration_seconds:rate5m)

The p99 rule queries the pre-aggregated bucket rule — efficient and correct.

WRONG — cross-group dependencies:
  Rules in different groups execute in parallel.
  If group B depends on group A's output, the dependency may not be ready yet.
  Keep dependent rules in the same group to guarantee execution order.
```

### The [range] Window Selection Rule

```
Common interview question: "Why do you use [5m] in rate()?"
Correct answer: it must be at least 4× the scrape interval.

With scrape_interval=15s:
  Minimum valid range: 4 × 15s = 60s = [1m]
  Standard range:      5m = 20 data points    ← use for most dashboards
  Stable range:       15m = 60 data points    ← use for alerting
  Long-term:           1h = 240 data points   ← use for trend analysis

Using too short a window:
  [30s] with 15s scrape = only 2 data points
  rate() extrapolation becomes unreliable
  Graph shows erratic, jumpy values

Using too long a window:
  [1h] for a 5-minute dashboard panel
  The rate() smooths over too much history
  A spike 55 minutes ago still affects the current "rate"
  Dashboard no longer reflects current state

For alerting: use [15m] or longer to avoid false positives from brief spikes
For dashboards: use [5m] for responsiveness with reasonable smoothing
```

### histogram_quantile() Accuracy Depends on Bucket Design

```
If your SLO is 200ms latency and you have these buckets:
  le="0.1"  (100ms)
  le="0.5"  (500ms)

Then histogram_quantile(0.99, ...) must interpolate between 100ms and 500ms.
It assumes a uniform distribution within the bucket — inaccurate.
Your p99 could be reported as 320ms when it is actually 195ms.

The fix: add a bucket at le="0.2" (200ms):
  le="0.1"  (100ms)
  le="0.2"  (200ms)  ← added
  le="0.5"  (500ms)

Now interpolation happens within a narrower range and is more accurate.

Rule: always define histogram buckets that bracket your SLO target values.
If your SLO is 200ms: ensure you have buckets at le="0.15" and le="0.25".
```

---

## Quick Reference — PromQL Cheat Sheet

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

## What's Next

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