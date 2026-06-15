# Quiz — Demo 00: Kube-Prometheus-Stack Reference Guide

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to Demo 01 hands-on lab.

| Score | Action |
|---|---|
| 100% | Import Anki CSV and move to Demo 01 |
| 80–90% | Review wrong answers, then proceed |
| 60–70% | Re-read relevant sections, retry quiz |
| Below 60% | Re-read full demo before proceeding |

---

**Q1. After running `helm install kube-prometheus-stack`, you open Prometheus Targets and immediately see targets for Grafana, Alertmanager, Node Exporter, and kube-state-metrics — all UP — without writing any scrape config. What is responsible for this?**

A. kube-prometheus-stack uses static_configs in a bundled prometheus.yaml written directly into the chart
B. The chart ships with ServiceMonitor CRDs for every component it installs; the Prometheus Operator reads these CRDs and generates scrape configs automatically on startup
C. Prometheus on Kubernetes auto-discovers all pods with a `/metrics` endpoint by default using the Kubernetes SD role
D. Grafana provisions the Prometheus data source and pushes target configs back to Prometheus via the API

<details>
<summary>Answer</summary>

**B** — The chart bundles ServiceMonitor CRDs for every installed component. The Prometheus Operator detects these CRDs via its Kubernetes watch, queries the Endpoints API for each, generates prometheus.yaml scrape jobs, and triggers a hot reload. No manual scrape config required.

Trap A: Static configs exist in the chart defaults but the Operator replaces them with dynamically generated CRD-based config. Trap C: Prometheus does not auto-discover all pods with /metrics — it only scrapes targets explicitly configured via ServiceMonitor, PodMonitor, or scrape_configs. Trap D: Grafana is a dashboard tool, not a Prometheus config manager.

</details>

---

**Q2. A developer creates a ServiceMonitor in the `payments` namespace. After 15 minutes, the service does not appear in Prometheus Targets. `serviceMonitorSelectorNilUsesHelmValues` is set to `true`. What is wrong?**

A. ServiceMonitors must be created in the `monitoring` namespace to be discovered
B. The Prometheus Operator only watches the namespace where it is deployed
C. The ServiceMonitor is missing the `release: kube-prometheus-stack` label required by the selector
D. The developer must restart the Prometheus pod to pick up new ServiceMonitors

<details>
<summary>Answer</summary>

**C** — When `serviceMonitorSelectorNilUsesHelmValues: true`, Prometheus only discovers ServiceMonitors with the label `release: kube-prometheus-stack` (the Helm release name). A ServiceMonitor without that label is silently ignored — no error, no warning, nothing in the Targets page. The fix is either: add the label to the ServiceMonitor, or set `serviceMonitorSelectorNilUsesHelmValues: false` to discover all ServiceMonitors cluster-wide.

Trap A: ServiceMonitors can be in any namespace — namespaceSelector in the spec controls which Service namespaces are searched. Trap B: The Prometheus Operator watches all namespaces cluster-wide by default. Trap D: Prometheus hot-reloads via /-/reload — no pod restart is needed or correct.

</details>

---

**Q3. What is the functional difference between Node Exporter and kube-state-metrics? Which one would you query to find out if a Deployment has fewer available replicas than desired?**

A. They expose the same metrics from different sources; use either. Query either for replica information.
B. Node Exporter covers host OS metrics from /proc and /sys; kube-state-metrics covers Kubernetes API object state. Use kube-state-metrics: `kube_deployment_status_replicas_available`
C. Node Exporter covers Kubernetes object state; kube-state-metrics covers container metrics. Use Node Exporter for replica counts.
D. Both are required together for every query — neither works independently

<details>
<summary>Answer</summary>

**B** — Node Exporter reads host OS metrics (CPU, memory, disk, network) from `/proc` and `/sys` on each node. It has no knowledge of Kubernetes objects. kube-state-metrics talks to the Kubernetes API server and exposes object state: deployment replicas, pod phase, resource limits, PVC status. For "are available replicas less than desired?": `kube_deployment_status_replicas_available < kube_deployment_spec_replicas` — pure kube-state-metrics query.

</details>

---

**Q4. You run `helm upgrade` to update the chart version. After the upgrade completes, all previously-configured Alertmanager silences are gone. What was missing from the original installation?**

A. The `--wait` flag was not used during the original helm install
B. Alertmanager storage was not configured in values.yaml — silences were stored in the pod's ephemeral memory and lost when the pod restarted during upgrade
C. The Prometheus Operator version changed and reset the Alertmanager config
D. Silences must be re-applied after every chart upgrade — this is expected behaviour

<details>
<summary>Answer</summary>

**B** — Silences live in Alertmanager's memory by default. A pod restart — including the restart triggered by a `helm upgrade` that updates the StatefulSet spec — erases all in-memory state. The fix is `alertmanager.alertmanagerSpec.storage` in values.yaml, which provisions a PVC. With a PVC, silence state is written to disk and survives any number of pod restarts.

Trap A: `--wait` controls whether the CLI blocks until pods are ready — it has no effect on data persistence. Trap C: The Operator manages Prometheus and Alertmanager config generation — it does not reset silence state. Trap D: Silences surviving upgrades is explicitly the expected behaviour when storage is configured correctly.

</details>

---

**Q5. The Prometheus pod has 2/2 containers and the Alertmanager pod has 2/2 containers. What are the two containers in each?**

A. Both pods: `main` container + `backup` container for HA
B. Prometheus: `prometheus` + `config-reloader`. Alertmanager: `alertmanager` + `config-reloader`
C. Prometheus: `prometheus` + `grafana-datasource`. Alertmanager: `alertmanager` + `grafana-datasource`
D. Both pods: `main` container + `rbac-proxy` sidecar for authentication

<details>
<summary>Answer</summary>

**B** — Both StatefulSets include a `config-reloader` sidecar alongside the main container. config-reloader watches the generated ConfigMap for changes (triggered by the Prometheus Operator after CRD reconciliation) and POSTs to `/-/reload` on the main container, enabling hot config reload without a process restart. Grafana has three containers (grafana + two provisioning sidecars) — the question is about Prometheus and Alertmanager specifically.

</details>

