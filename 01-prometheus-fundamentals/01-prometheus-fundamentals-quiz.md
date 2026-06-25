# Quiz — Demo 01: Prometheus Architecture, Data Model & First Scrape

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to Demo 02.

| Score | Action |
|---|---|
| 100% | Import Anki CSV and move to Demo 02 |
| 80–90% | Review wrong answers, then proceed |
| 60–70% | Re-read relevant sections, retry quiz |
| Below 60% | Re-read full demo before proceeding |

---

**Q1. You create a ServiceMonitor in the `payments` namespace. After 10 minutes, the service still does not appear in Prometheus Targets. A colleague suggests checking `serviceMonitorSelectorNilUsesHelmValues`. What does this setting control?**

A. Whether Prometheus scrapes pod IPs or Service ClusterIPs
B. Whether Prometheus discovers ServiceMonitors based on a required Helm release label
C. Whether the Prometheus Operator watches namespaces outside `monitoring`
D. Whether `scrape_interval` is applied per ServiceMonitor or globally

<details>
<summary>Answer</summary>

**B** — When `serviceMonitorSelectorNilUsesHelmValues: true` (the default), Prometheus only discovers ServiceMonitors that carry the label `release: kube-prometheus-stack`. Any ServiceMonitor without that label is silently ignored — no scraping, no error. Setting it to `false` makes Prometheus discover all ServiceMonitors cluster-wide regardless of labels.

Trap A: Prometheus always scrapes pod IPs directly (via the Endpoints API), not the ClusterIP — this is unrelated to this setting. Trap C: Namespace watching is controlled by `namespaceSelector` in the ServiceMonitor spec, not this setting. Trap D: `scrape_interval` is a separate setting in `prometheusSpec` or the ServiceMonitor `endpoints[].interval`.

</details>

---

**Q2. You query `http_requests_total{job="order-api"}` in Prometheus and get the value `8,291,033`. You want to alert when the error rate exceeds 1%. Which PromQL expression is correct?**

A. `http_requests_total{status=~"5.."} > 0.01`
B. `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.01`
C. `increase(http_requests_total{status=~"5.."}[5m]) > 0.01`
D. `http_requests_total{status=~"5.."} / http_requests_total > 0.01`

<details>
<summary>Answer</summary>

**B** — This calculates the per-second rate of 5xx errors divided by the per-second rate of all requests, giving the error fraction. `rate()` is required because `http_requests_total` is a counter — it only ever increases, and the raw value is a meaningless cumulative total since process start. Dividing rates gives the fraction of requests that are errors.

Trap A: Comparing a raw counter to 0.01 is meaningless — the counter is in the millions. Trap C: `increase()` gives total new errors in the window, not a fraction of requests. Trap D: Dividing raw counters gives the fraction of total historical errors to total historical requests — a meaningless ratio that converges to a constant as counters grow.

</details>

---

**Q3. An engineer proposes adding `session_id` as a label to all HTTP metrics to enable per-session debugging. Your platform has 500,000 daily active sessions. What is the primary concern?**

A. Prometheus does not support string labels longer than 64 characters
B. Session IDs are not stable across pod restarts and will confuse rate() calculations
C. Each unique session_id creates a separate time series, potentially creating millions of series and OOMKilling Prometheus
D. The ServiceMonitor spec does not allow custom label injection

<details>
<summary>Answer</summary>

**C** — Cardinality explosion. With `session_id` as a label on `http_requests_total` across 5 services, 4 methods, 6 status codes, and 500,000 sessions: 5 × 4 × 6 × 500,000 = 60,000,000 time series. At ~3 KB each, that is ~180 GB of RAM — Prometheus OOMKills immediately and monitoring disappears. High-cardinality per-event data belongs in logs (Loki) or traces (Tempo), not Prometheus.

Trap A: Prometheus does not have a documented 64-character label length limit as a practical concern. Trap B: Counter resets are handled by `rate()` gracefully — this is not the concern. Trap D: Labels can be injected via `relabelings` — this is technically possible, which makes the cardinality problem worse, not better.

</details>

---

**Q4. `scrape_interval` is set to `60s` and `evaluation_interval` is set to `10s`. You have an alerting rule: `expr: up == 0 for: 30s`. A target goes down at t=0. When does the alert fire?**

A. At t=10s — the evaluation clock runs every 10 seconds
B. At t=30s — the `for: 30s` duration is satisfied
C. At t=60s — Prometheus only knows the target is down after the first missed scrape at t=60s
D. At t=90s — the `for: 30s` window starts after the first missed scrape

<details>
<summary>Answer</summary>

**D** — Prometheus cannot know a target is down until it misses a scrape. With `scrape_interval: 60s`, the first missed scrape is detected at t=60s when `up` becomes 0. The `for: 30s` clause then requires the alert to stay in Pending state for 30 more seconds before firing. So the alert fires at approximately t=90s. The `evaluation_interval: 10s` does not help here — evaluating stale data faster does not reveal that the target is down sooner.

Trap A: Evaluation runs every 10 seconds but against data from the last scrape — which is still from before the target went down. Trap B: The `for: 30s` clock only starts after the condition is first true (after t=60s). Trap C: The alert enters Pending state at t=60s but does not fire until the for duration elapses.

</details>

---

**Q5. You run `helm uninstall kube-prometheus-stack -n monitoring` to do a clean reinstall. After reinstalling, Prometheus has no historical data. What went wrong?**

A. `helm uninstall` deleted the Prometheus StatefulSet and its PVC
B. `helm uninstall` does not delete PVCs by design, but the old PVC was not mounted to the new install because it had a different name
C. `helm uninstall` deleted the PVC because `--purge` was implied
D. The TSDB data was in the pod's ephemeral storage, not a PVC — retention settings were not configured in values.yaml

<details>
<summary>Answer</summary>

**D** — If `storageSpec` was not configured in `values.yaml`, the TSDB lives in the pod's ephemeral container filesystem. When the StatefulSet is deleted by `helm uninstall`, the pod and its ephemeral storage are gone. Helm does preserve PVCs on uninstall by design — but only if a PVC existed in the first place. Without the `storageSpec` block, no PVC is created, and there is no data to preserve.

Trap A: Helm does not delete PVCs on uninstall — this is a deliberate Helm design choice. Trap B: PVC names are deterministic based on chart naming conventions — a reinstall would mount the same PVC if it existed. Trap C: There is no `--purge` implied in `helm uninstall`; the flag was removed in Helm 3 (it was a Helm 2 concept).

</details>

---

**Q6. You want to calculate p99 request latency from a histogram metric. Which PromQL expression is correct?**

A. `avg(http_request_duration_seconds_sum / http_request_duration_seconds_count)`
B. `histogram_quantile(0.99, http_request_duration_seconds_bucket)`
C. `histogram_quantile(0.99, sum by (le)(rate(http_request_duration_seconds_bucket[5m])))`
D. `quantile(0.99, http_request_duration_seconds)`

<details>
<summary>Answer</summary>

**C** — This is the correct full expression. `rate()` converts the cumulative bucket counters to per-second rates over the window (required — raw histograms are counters). `sum by (le)` aggregates across all pod instances while preserving the `le` label that `histogram_quantile` requires to identify bucket boundaries. `histogram_quantile(0.99, ...)` interpolates between the bucket boundaries.

Trap A: `_sum / _count` gives the average (mean) latency — not p99. Mean latency hides tail behaviour. Trap B: This would fail or produce wrong results — `http_request_duration_seconds_bucket` is a counter and must be wrapped in `rate()` first; also missing `sum by (le)` across pods. Trap D: `quantile()` is an aggregation operator for gauge vectors, not a function for histograms.

</details>

---

**Q7. After running `kubectl apply -f 03-servicemonitor.yaml`, how long does it typically take for the new target to appear in Prometheus Targets, and what happens during that time?**

A. Immediately — the API call to Prometheus happens synchronously when you apply the manifest
B. Up to 5 minutes — Prometheus checks for new ServiceMonitors on its scrape cycle
C. Within 30 seconds — the Operator detects the new CRD, queries the Endpoints API, regenerates prometheus.yaml, and triggers a hot reload via /-/reload
D. At the next scrape_interval boundary — Prometheus and the Operator are synchronised on the same clock

<details>
<summary>Answer</summary>

**C** — The Prometheus Operator watches the Kubernetes API for changes to `servicemonitors.monitoring.coreos.com` resources. When a new ServiceMonitor is created, the Operator reconciles within seconds: it queries the Endpoints API for pods matching the selector, generates a new `prometheus.yaml` scrape config, writes it to a ConfigMap, and the config-reloader sidecar POSTs to Prometheus `/-/reload`. Prometheus reloads config without restarting. The total time is typically under 30 seconds.

Trap A: There is no synchronous API call — the Operator uses a Kubernetes watch (event-driven), not polling. Trap B: The Operator does not wait for scrape cycles — it reconciles within seconds of the CRD creation event. Trap D: The Operator and scrape_interval clocks are independent.

</details>

---

**Q8. You look at the TSDB Status page and see Total Series: 850,000 on a 3-node Minikube cluster. The top metric by series count is `http_requests_total` with 620,000 series. What is the most likely cause?**

A. The scrape_interval is too short — more frequent scrapes create more series
B. A label with unbounded values (such as user_id, request_id, or URL with query parameters) was added to http_requests_total
C. There are too many ServiceMonitors — each one creates additional time series
D. The retention period is too long — older series accumulate and inflate the count

<details>
<summary>Answer</summary>

**B** — A single metric with 620,000 series is a textbook cardinality explosion caused by an unbounded label. Typical bounded labels produce tens to hundreds of series per metric. 620,000 series from one metric means a label value is growing with each new user, request, session, or URL. Check `topk(10, count by (label_name)({__name__="http_requests_total"}))` to find which label has the most unique values.

Trap A: `scrape_interval` affects how many data points are stored per series, not how many series exist. A shorter interval adds more samples to existing series, not new series. Trap C: ServiceMonitors add scrape targets (instances), which adds a bounded number of series proportional to the number of pods — not 620,000 from one metric. Trap D: Retention controls how long old data is kept, not how many active series exist.

</details>

