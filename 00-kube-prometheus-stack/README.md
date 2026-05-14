# Demo 00: Kube-Prometheus-Stack — Complete Reference Guide

This document is the companion reference to [Demo 01](./README.md).
While the demo README focuses on hands-on steps, this guide covers everything
you need to understand, operate, secure, and scale kube-prometheus-stack in
depth — from the identity and governance of every component, through its
internals, configuration, CRDs, RBAC, HA patterns, and production practices.

**Read this document when:**
- You want to understand who built each component, how it is governed, and whether it is safe to depend on in a professional environment
- You want to understand what the Helm chart actually installs and why
- You need to debug a component or verify its configuration
- You are designing a production deployment and need to understand HA, multi-tenancy, or storage options
- You want to understand how all components interwork at the message level
- You need to understand RBAC and what permissions each component holds

**Related documents:**
- [Demo 01 README](./README.md) — hands-on lab steps
- [Project root README](../README.md) — full 25-demo roadmap and stack rationale

---

## Contents
0. [Overview — kube-prometheus-stack](#0-overview--kube-prometheus-stack)
1. [Understanding the Prometheus Product Family](#1-understanding-the-prometheus-product-family)
2. [Understanding the Grafana Product Family](#2-understanding-the-grafana-product-family)
3. [Why kube-prometheus-stack — and Production Adoption](#3-why-kube-prometheus-stack--and-production-adoption)
4. [Security Posture — Full Stack Assessment](#4-security-posture--full-stack-assessment)
5. [What the Helm Chart Installs](#5-what-the-helm-chart-installs)
6. [Component Deep Dive](#6-component-deep-dive)
7. [CRDs — Every Custom Resource Explained](#7-crds--every-custom-resource-explained)
8. [Configuration Files and How They Are Generated](#8-configuration-files-and-how-they-are-generated)
9. [RBAC — Who Has Access to What](#9-rbac--who-has-access-to-what)
10. [Message Flow and Component Interworking](#10-message-flow-and-component-interworking)
11. [UI, CLI, and API Endpoints](#11-ui-cli-and-api-endpoints)
12. [Verifying Stack Health](#12-verifying-stack-health)
13. [High Availability — Patterns and Solutions](#13-high-availability--patterns-and-solutions)
14. [Multi-Tenancy and Multi-Cluster](#14-multi-tenancy-and-multi-cluster)
15. [Storage Solutions](#15-storage-solutions)
16. [Release Alignment — Chart vs Component Versions](#16-release-alignment--chart-vs-component-versions)
17. [Official Resources](#17-official-resources)

---

## 0. Overview — kube-prometheus-stack

### What It Is

kube-prometheus-stack is the industry-standard, one-command deployment of a
complete Kubernetes monitoring platform. A single Helm install brings up
Prometheus, Alertmanager, Grafana, Node Exporter, kube-state-metrics, and
the Prometheus Operator — all pre-wired, pre-configured, and ready to scrape
your cluster within minutes.

It collects Kubernetes manifests, Grafana dashboards, and Prometheus rules combined with documentation and scripts to provide easy-to-operate, end-to-end Kubernetes cluster monitoring with Prometheus using the Prometheus Operator.

It is not a new product — it is a carefully assembled and maintained packaging
of six independent open-source tools, each from a different organisation, that
would otherwise require significant manual effort to wire together correctly.

### History — How It Came to Be

```
2012  Prometheus created at SoundCloud by Matt Proud and Julius Volz.
      Designed to monitor microservices — pull model, labels, PromQL.

2016  CoreOS engineers build the Prometheus Operator.
      CoreOS invented the Kubernetes Operator pattern itself.
      Goal: manage Prometheus on Kubernetes as a native CRD resource,
      eliminating manual prometheus.yaml management entirely.

2016  CoreOS also publishes kube-prometheus — a Jsonnet library that
      bundles Prometheus Operator + Alertmanager + Grafana + Node Exporter
      + kube-state-metrics into a deployable monitoring stack.
      Deployed by generating Kubernetes YAML from Jsonnet templates.

2018  Red Hat acquires CoreOS.
      Prometheus Operator and kube-prometheus donated to the community
      under the independent prometheus-operator GitHub organisation.
      CRD API group remains monitoring.coreos.com as a historical artefact.
      Red Hat ships the Prometheus Operator as the monitoring foundation
      of every OpenShift cluster worldwide.

2018  Prometheus graduates from CNCF — the second project ever after Kubernetes.

2020  prometheus-community Helm chart organisation created.
      The chart was formerly named prometheus-operator — renamed to
      kube-prometheus-stack to reflect that the Prometheus Operator is
      only one component of the full stack it deploys.

2020–  kube-prometheus-stack Helm chart becomes the de facto standard
2026   for Kubernetes monitoring. Multiple releases per month tracking
       every upstream component release.
       Chart version 84.5.0 (May 2026) — Prometheus Operator v0.90.1.
```

### Two Related but Distinct Projects

A source of confusion in the community is that two projects share very similar
names. Understanding the distinction prevents documentation confusion:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  kube-prometheus  (the upstream Jsonnet project)                            │
│  GitHub: github.com/prometheus-operator/kube-prometheus                    │
│                                                                             │
│  The original CoreOS project. Maintained by the prometheus-operator org.   │
│  Deployed by generating YAML from Jsonnet templates using jsonnet-bundler.  │
│  Gives maximum flexibility — every component is customisable via Jsonnet.   │
│  Used by platform teams who need deep customisation beyond what Helm allows.│
│  Contains the canonical alert rules and dashboards used by the Helm chart.  │
│  NOT what most teams use for day-to-day deployments.                        │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  kube-prometheus-stack  (the Helm chart)                                    │
│  GitHub: github.com/prometheus-community/helm-charts                       │
│                                                                             │
│  The Helm-packaged version of kube-prometheus.                              │
│  Maintained by the prometheus-community volunteer organisation.             │
│  Deployed with a single helm install command.                               │
│  Configured via values.yaml — no Jsonnet knowledge required.                │
│  Imports dashboards and alert rules directly from kube-prometheus upstream. │
│  What this guide covers. What 95%+ of teams use in practice.               │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Who Develops and Maintains It

kube-prometheus-stack is a community effort with no single company owning it.
The work is distributed across three organisations:

```
prometheus-community (the Helm chart):
  A volunteer-run GitHub organisation with no formal corporate backing.
  Seven named maintainers from across the community (as of 2026):
    andrewgkew, gianrubio, gkarthiks, GMartinez-Sisti,
    jkroepke, Xtigyro, QuentinBisson
  Regular contributors from Grafana Labs, Red Hat, and AWS.
  No SLA. No paid security team. No formal CVE response process.
  Releases multiple times per month tracking upstream component updates.
  Chart licence: Apache 2.0

prometheus-operator (the Operator and CRDs):
  Independent community organisation — not CNCF, not a single company.
  Red Hat (IBM) is the dominant commercial contributor.
  Red Hat ships it in every OpenShift cluster globally — direct commercial
  interest in its quality and security.
  Grafana Labs contributes regularly.
  Licence: Apache 2.0

prometheus-operator/kube-prometheus (upstream Jsonnet):
  Same prometheus-operator organisation.
  Source of truth for alert rules and dashboard definitions.
  Changes here flow downstream into the Helm chart on each release.
```

### What the Stack Contains

kube-prometheus-stack installs and pre-wires six components. Each is an
independent open-source project from a different organisation:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Component             │  Owner                  │  Role in the stack        │
├──────────────────────────────────────────────────────────────────────────────┤
│  Prometheus Operator   │  prometheus-operator org │  Manages all components  │
│                        │  (Red Hat primary)        │  via CRDs, generates     │
│                        │                           │  configs automatically   │
├──────────────────────────────────────────────────────────────────────────────┤
│  Prometheus            │  CNCF Graduated           │  Metrics TSDB, scraper,  │
│                        │  (SoundCloud origin)      │  PromQL engine, alerting │
├──────────────────────────────────────────────────────────────────────────────┤
│  Alertmanager          │  CNCF Graduated           │  Alert deduplication,    │
│                        │  (Prometheus project)     │  grouping, routing       │
├──────────────────────────────────────────────────────────────────────────────┤
│  Grafana               │  Grafana Labs             │  Dashboards, panels,     │
│                        │  (AGPLv3)                 │  unified alerting UI     │
├──────────────────────────────────────────────────────────────────────────────┤
│  Node Exporter         │  CNCF Graduated           │  Host OS metrics from    │
│                        │  (Prometheus project)     │  /proc and /sys          │
├──────────────────────────────────────────────────────────────────────────────┤
│  kube-state-metrics    │  Kubernetes SIG-          │  Kubernetes API object   │
│                        │  instrumentation          │  state as metrics        │
└──────────────────────────────────────────────────────────────────────────────┘

Versions in chart 84.5.0 (May 2026):
  Prometheus Operator  v0.90.1   │  Prometheus     3.4.1
  Alertmanager         0.28.1    │  Grafana        12.3.0
  Node Exporter        1.11.1    │  kube-state-metrics  2.18.0
```

### What This Guide Covers

This guide is the companion reference to [Demo 01](./README.md).
The sections that follow go deep on every aspect of the stack —
use the table of contents to navigate to the topic you need:

```
Section 1–2  →  Product family background: Prometheus and Grafana ecosystems
Section 3    →  Why this stack exists — the problem it solves
Section 4    →  Security posture — honest assessment of every component
Section 5    →  What is installed — complete inventory with actual outputs
Section 6    →  Component internals — how each component works under the hood
Section 7    →  CRDs — every Custom Resource and what it does
Section 8    →  Configuration — how configs are generated and where they live
Section 9    →  RBAC — exact permissions per component
Section 10   →  Message flows — end-to-end from scrape to alert to dashboard
Section 11   →  UI, CLI, API — accessing every component
Section 12   →  Health verification — checking the full stack is working
Section 13   →  High Availability — how to make the stack resilient
Section 14   →  Multi-tenancy and multi-cluster patterns
Section 15   →  Storage — local TSDB, MinIO, AWS S3
Section 16   →  Release alignment — chart versions vs component versions
Section 17   →  Official resources and references
```

---

## 1. Understanding the Prometheus Product Family

Before running a single command it is worth understanding what you are actually
deploying — who built it, who maintains it, how it is governed, and whether it
is safe to depend on in a professional environment. These are the questions every
responsible engineer asks before adopting infrastructure tooling.

### Are Node Exporter and kube-state-metrics Part of the Prometheus Project?

This is a frequently asked question. The short answer: **Node Exporter yes,
kube-state-metrics no** — but both are tightly integrated into the Prometheus ecosystem.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Node Exporter                                                               │
│                                                                              │
│  Maintained by: the Prometheus project itself                                │
│  GitHub:        github.com/prometheus/node_exporter                         │
│  CNCF status:   Part of the CNCF Graduated Prometheus project               │
│  License:       Apache 2.0                                                   │
│                                                                              │
│  Node Exporter lives under the prometheus GitHub organisation — the same     │
│  organisation that owns Prometheus, Alertmanager, and Pushgateway.          │
│  It is an official first-party Prometheus sub-project.                      │
│  The Prometheus maintainers review and merge its releases.                  │
│                                                                              │
│  Relationship: it is the "official Linux OS metrics exporter" for Prometheus │
│  in the same way Alertmanager is the "official alert router" for Prometheus. │
└──────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────┐
│  kube-state-metrics                                                          │
│                                                                              │
│  Maintained by: Kubernetes SIG-instrumentation                               │
│  GitHub:        github.com/kubernetes/kube-state-metrics                    │
│  CNCF status:   Part of the Kubernetes project (CNCF Graduated)             │
│  License:       Apache 2.0                                                   │
│                                                                              │
│  kube-state-metrics lives under the kubernetes GitHub organisation —         │
│  not under prometheus. It is a Kubernetes SIG project, not a Prometheus     │
│  project. SIG-instrumentation owns it and drives its development.           │
│                                                                              │
│  Relationship: it is a Kubernetes-native exporter that produces metrics     │
│  in Prometheus format. It depends on Prometheus for consumption but is      │
│  not owned or governed by the Prometheus project.                           │
└──────────────────────────────────────────────────────────────────────────────┘
```

Both are bundled by kube-prometheus-stack because together they cover the
two fundamental signal layers every Kubernetes cluster needs: host OS metrics
(Node Exporter) and Kubernetes API object state (kube-state-metrics).
Neither signal can substitute for the other — you need both.

---

### Three Distinct Projects — Commonly Confused

There are three separate things that share the "Prometheus" name and are routinely
conflated by engineers new to the ecosystem. They have different origins, different
governance, and different levels of formal backing.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. Prometheus  (the software binary)                                       │
│                                                                             │
│  What it is:   The time-series database, PromQL engine, scraper, and rule   │
│                evaluator. A single Go binary you can run anywhere.          │
│                                                                             │
│  Origin:       Built at SoundCloud in 2012 by Matt Proud and Julius Volz    │
│                to solve the problem of monitoring microservices at scale.    │
│                Donated to CNCF in May 2016.                                 │
│                                                                             │
│  CNCF status:  GRADUATED — August 9, 2018.                                 │
│                Second ever CNCF project to graduate, after Kubernetes.      │
│                Graduation requires: security audit, structured governance,  │
│                thriving adoption, and a code of conduct. All met.           │
│                                                                             │
│  Governance:   Self-selected team of active contributors. No single company │
│                controls it. Contributors include engineers from Google,      │
│                Red Hat, AWS, Grafana Labs, Spotify, Apple, and IBM.         │
│                                                                             │
│  License:      Apache 2.0                                                   │
│  GitHub:       github.com/prometheus/prometheus                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  2. Prometheus Operator                                                     │
│                                                                             │
│  What it is:   A Kubernetes controller that manages Prometheus instances    │
│                via CRDs (ServiceMonitor, PrometheusRule, etc.).             │
│                Eliminates manual prometheus.yaml management entirely.       │
│                                                                             │
│  Origin:       Built at CoreOS in 2016 alongside the Operator pattern       │
│                itself — CoreOS invented the Kubernetes Operator concept.    │
│                Red Hat acquired CoreOS in 2018 and donated the project to   │
│                the independent prometheus-operator GitHub organisation.     │
│                                                                             │
│  CNCF status:  NOT a CNCF project — community maintained.                  │
│                Lives under the prometheus-operator GitHub org, independent  │
│                of both CNCF and any single company.                         │
│                                                                             │
│  Backing:      Red Hat (IBM) and Grafana Labs are the largest active        │
│                contributors. Red Hat ships it as the monitoring foundation  │
│                of every OpenShift cluster worldwide — they have a direct    │
│                commercial interest in its quality and security.             │
│                                                                             │
│  Note on API:  CRD group is monitoring.coreos.com — the coreos.com name    │
│                remains as a historical artefact. Renaming a CRD API group  │
│                is a breaking change that would require every existing       │
│                ServiceMonitor and PrometheusRule in every cluster worldwide │
│                to be updated. The community kept the name intentionally.    │
│                                                                             │
│  License:      Apache 2.0                                                   │
│  GitHub:       github.com/prometheus-operator/prometheus-operator           │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  3. kube-prometheus-stack  (the Helm chart)                                 │
│                                                                             │
│  What it is:   A Helm chart that packages Prometheus Operator + Prometheus  │
│                + Alertmanager + Grafana + Node Exporter + kube-state-metrics│
│                into a single installable unit with all wiring pre-done.     │
│                                                                             │
│  Origin:       Evolved from the older stable/prometheus-operator chart and  │
│                the kube-prometheus jsonnet project. Moved to the            │
│                prometheus-community GitHub organisation.                    │
│                                                                             │
│  CNCF status:  NOT a CNCF project.                                         │
│                Maintained by the prometheus-community volunteer org.        │
│                This is a community Helm chart — not a CNCF artifact.        │
│                                                                             │
│  Backing:      Community maintained — no single company owns it.            │
│                Contributors from Grafana Labs, Red Hat, and AWS regularly   │
│                submit PRs. Grafana Labs and Red Hat both ship their own     │
│                distributions that use the same underlying components,       │
│                providing a fallback if the community chart ever stalled.    │
│                                                                             │
│  License:      Apache 2.0                                                   │
│  GitHub:       github.com/prometheus-community/helm-charts                  │
│  ArtifactHub:  artifacthub.io/packages/helm/prometheus-community/           │
│                kube-prometheus-stack                                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Understanding the Grafana Product Family

Grafana is the visualisation and unified frontend for the entire LGTM+ stack.
Before using it, understanding what it is, who built it, how it is licensed,
and how its products relate to each other prevents confusion later — especially
around the OSS vs Enterprise distinction and the AGPLv3 licence change.

### Origin and Company Background

Grafana was created by Torkel Ödegaard in January 2014 as a side project while
working at Orbitz, originally built on top of Kibana v3's UI to improve
Graphite dashboards. It was released as open source from day one.

Ödegaard met Raj Dutt and Anthony Woods in New York in 2015. Together they
founded a company making commercially licensed software built around Grafana OSS,
initially called Raintank, later rebranded as Grafana Labs in 2017.

Grafana Labs has raised a total of $791M over 7 rounds from 17 institutional
investors including Lightspeed Venture Partners, Sequoia Capital, and Coatue,
reaching a valuation of $6 billion.

Grafana Labs generates revenue primarily through enterprise subscriptions and
managed cloud services, with over 5,000 paying customers including major
enterprises like Salesforce, Bloomberg, and J.P. Morgan Chase.

The financial backing is directly relevant to open-source sustainability:
Grafana Labs employs the engineers who build and maintain Grafana, Loki, Tempo,
Mimir, Alloy, and Pyroscope. Revenue from enterprise products and Grafana Cloud
funds continued investment in the OSS projects — this is the commercial
open-source flywheel model.

### The Grafana Product Family — Three Distinct Things

Engineers new to the ecosystem routinely conflate three separate concepts
that share the Grafana name:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. Grafana OSS  (the dashboard and visualisation software)                 │
│                                                                             │
│  What it is:   A web application that connects to data sources and renders  │
│                dashboards. Does NOT store any metric, log, or trace data    │
│                itself. It is purely a query and visualisation layer.        │
│                                                                             │
│  Origin:       Created by Torkel Ödegaard in 2014. Always open source.     │
│                                                                             │
│  Licence:      AGPLv3 since 2021 (previously Apache 2.0)                   │
│                AGPLv3 means: if you modify Grafana and run it as a service  │
│                for others, you must publish your modifications.             │
│                Running Grafana internally (not as a SaaS) is unrestricted. │
│                                                                             │
│  Architecture: Single Go binary + React/TypeScript frontend                 │
│                Plugin system: data source plugins, panel plugins, app plugins│
│                100+ data source plugins: Prometheus, Loki, Tempo, Mimir,    │
│                CloudWatch, PostgreSQL, MySQL, Elasticsearch, and more.      │
│                Grafana does not store data — it queries backends at render  │
│                time and combines results from multiple sources in one panel. │
│                                                                             │
│  Version used in this demo series: Grafana 11.6.0                          │
│  GitHub: github.com/grafana/grafana                                         │
│  Licence: AGPLv3                                                            │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  2. Grafana Enterprise  (commercial edition of Grafana OSS)                 │
│                                                                             │
│  What it adds: Features gated behind a commercial licence on top of OSS:   │
│    - SAML and LDAP team synchronisation                                     │
│    - Data source permissions (restrict which team sees which data source)   │
│    - Audit logging (who queried what, when)                                 │
│    - Reporting (scheduled PDF dashboard exports)                            │
│    - Enhanced RBAC with fine-grained dashboard and folder permissions       │
│    - Premium data source plugins: Datadog, Splunk, New Relic, Dynatrace    │
│    - Enterprise support with SLAs                                           │
│                                                                             │
│  Same binary as OSS — Enterprise features unlock with a licence key.        │
│  Relevant for: regulated industries (finance, healthcare, government)        │
│  where audit trails, SAML SSO, and data access control are mandatory.       │
│                                                                             │
│  In this demo series: we use OSS only. Enterprise features are noted where  │
│  relevant so you understand the production upgrade path.                    │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  3. Grafana Cloud  (fully managed SaaS platform)                            │
│                                                                             │
│  What it is:   Grafana Labs hosts and operates the entire LGTM+ stack for  │
│                you. You send telemetry data to Grafana Cloud endpoints.     │
│                Grafana Labs manages scaling, upgrades, and availability.    │
│                                                                             │
│  Components:   Grafana (dashboards) + Mimir (metrics) + Loki (logs) +      │
│                Tempo (traces) + Pyroscope (profiles) + OnCall (incidents)  │
│                + Synthetic Monitoring — all managed.                        │
│                                                                             │
│  Pricing:      Free tier (10,000 metric series, 50GB logs/traces).          │
│                Paid tiers based on consumption volume.                      │
│                At scale: approaches Datadog pricing — evaluate carefully.   │
│                                                                             │
│  Relevant for: teams who want zero operational overhead for the stack.      │
│  Trade-off:    data leaves your infrastructure (GDPR/residency concern).    │
│                                                                             │
│  In this demo series: we self-host everything. The skills transfer         │
│  directly to Grafana Cloud — same query languages, same dashboards.        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The LGTM+ Stack — What Grafana Labs Owns

Grafana Labs is the primary maintainer of every backend in the LGTM+ stack.
Understanding each component's origin clarifies its maturity and governance:

```
┌──────────────────┬─────────────────────────────────────────────────────────┐
│  Component       │  Origin and Status                                      │
├──────────────────┼─────────────────────────────────────────────────────────┤
│  Grafana         │  Created by Torkel Ödegaard (2014)                      │
│  (visualisation) │  Always open source — the company's founding product    │
│                  │  Licence: AGPLv3 (changed from Apache 2.0 in 2021)      │
│                  │  Covered in: Demo 04                                    │
├──────────────────┼─────────────────────────────────────────────────────────┤
│  Grafana Loki    │  Built by Grafana Labs (2018)                           │
│  (logs)          │  Inspired by Prometheus — "like Prometheus, but for logs"│
│                  │  Label-based index — cheap object storage backend       │
│                  │  Licence: AGPLv3                                        │
│                  │  Covered in: Demos 05, 06, 15, 21                      │
├──────────────────┼─────────────────────────────────────────────────────────┤
│  Grafana Alloy   │  Replaces Promtail (EOL Mar 2026) + Grafana Agent       │
│  (collection)    │  (deprecated Nov 2025). OTel Collector distribution.   │
│                  │  Vendor-neutral — routes to any OTel-compatible backend │
│                  │  Licence: Apache 2.0                                    │
│                  │  Covered in: Demos 05, 09, 16                          │
├──────────────────┼─────────────────────────────────────────────────────────┤
│  Grafana Tempo   │  Built by Grafana Labs (2021)                           │
│  (traces)        │  Object storage only — no Elasticsearch/Cassandra needed│
│                  │  TraceQL — purpose-built trace query language           │
│                  │  Licence: AGPLv3                                        │
│                  │  Covered in: Demos 09, 10                              │
├──────────────────┼─────────────────────────────────────────────────────────┤
│  Grafana Mimir   │  Announced March 2022 — fork of Cortex (CNCF project)  │
│  (long-term      │  Previously commercial-only features open-sourced       │
│   metrics)       │  Scales to 1 billion active series                     │
│                  │  Licence: AGPLv3                                        │
│                  │  Covered in: Demo 22                                   │
├──────────────────┼─────────────────────────────────────────────────────────┤
│  Grafana         │  Acquired from Pyroscope Inc (2023)                     │
│  Pyroscope       │  Merged with Grafana Phlare into one codebase          │
│  (profiling)     │  eBPF auto-profiling — no code changes required        │
│                  │  Licence: AGPLv3                                        │
│                  │  Covered in: Demo 23                                   │
├──────────────────┼─────────────────────────────────────────────────────────┤
│  Grafana OnCall  │  Acquired from Amixr (2021)                             │
│  (incident mgmt) │  On-call schedules, escalation chains, incident routing │
│                  │  Licence: AGPLv3                                        │
│                  │  Covered in: Demo 20                                   │
└──────────────────┴─────────────────────────────────────────────────────────┘
```

### The AGPLv3 Licence — What It Means in Practice

In 2021, Grafana Labs relicensed Grafana, Loki, and Tempo from Apache 2.0 to
AGPLv3. Mimir launched directly under AGPLv3 in 2022. This was a deliberate
strategy to protect commercial sustainability while keeping code open.

```
What AGPLv3 means:

  For internal use (running Grafana/Loki/Tempo inside your organisation):
    ✅ Free to use, modify, and run — no restrictions
    ✅ Do not need to publish your modifications
    ✅ No licence fees for self-hosted internal use

  For building a SaaS product ON TOP of Grafana/Loki/Tempo:
    ⚠️  If you offer the software as a service to others, you must publish
        your source code modifications under AGPLv3
    ⚠️  This is the "copyleft" provision — it prevents companies from
        building competing managed services without contributing back
    ⚠️  This is why AWS, Google, and Azure don't offer Grafana, Loki,
        or Tempo as managed services — they would need to open-source
        their infrastructure modifications

  For this demo series:
    ✅ 100% internal use — no AGPLv3 obligations apply
    ✅ All demos run on your own infrastructure
    ✅ Nothing to publish, nothing to pay

  Grafana Alloy:
    ✅ Apache 2.0 — no copyleft, fully permissive
    ✅ Can be used in any context including SaaS without publishing source
```

### Grafana OSS vs Enterprise — Feature Comparison

```
┌────────────────────────────────────────┬──────────────┬──────────────────┐
│  Feature                               │  OSS (used)  │  Enterprise      │
├────────────────────────────────────────┼──────────────┼──────────────────┤
│  Dashboards and panels                 │  ✅ Full     │  ✅ Full         │
│  Prometheus data source                │  ✅ Full     │  ✅ Full         │
│  Loki data source                      │  ✅ Full     │  ✅ Full         │
│  Tempo data source                     │  ✅ Full     │  ✅ Full         │
│  Alerting (unified alerting)           │  ✅ Full     │  ✅ Full         │
│  Grafana OnCall integration            │  ✅ Full     │  ✅ Full         │
│  Variables and templating              │  ✅ Full     │  ✅ Full         │
│  Dashboard provisioning                │  ✅ Full     │  ✅ Full         │
│  Plugin ecosystem (community)          │  ✅ Full     │  ✅ Full         │
│  Basic RBAC (Viewer/Editor/Admin)      │  ✅ Full     │  ✅ Full         │
├────────────────────────────────────────┼──────────────┼──────────────────┤
│  SAML / SSO integration                │  ❌ Basic    │  ✅ Full SAML    │
│  LDAP team synchronisation             │  ❌ Basic    │  ✅ Full sync     │
│  Data source permissions               │  ❌ None     │  ✅ Team-level    │
│  Dashboard permissions (fine-grained)  │  ❌ Basic    │  ✅ Folder/dash   │
│  Audit logging                         │  ❌ None     │  ✅ Full          │
│  Scheduled PDF reporting               │  ❌ None     │  ✅ Full          │
│  Datadog / Splunk / New Relic plugins  │  ❌ None     │  ✅ Premium       │
│  Enterprise support SLA                │  ❌ Community │  ✅ SLA-backed   │
└────────────────────────────────────────┴──────────────┴──────────────────┘

Conclusion for this demo series:
  OSS covers 100% of what we need for Phases 1–3.
  Enterprise features become relevant when:
    - Production deployment has multiple teams sharing one Grafana
    - Compliance requires audit logging (SOC2, PCI-DSS, HIPAA)
    - SSO integration with corporate IdP is mandatory
    - Data source access must be restricted per team
```

### CNCF Status Summary for the Full Stack

```
┌─────────────────────────┬──────────────────────────────────────────────────┐
│  Component              │  CNCF Status                                     │
├─────────────────────────┼──────────────────────────────────────────────────┤
│  Prometheus             │  ✅ CNCF Graduated (August 2018)                 │
│  Alertmanager           │  ✅ CNCF Graduated (part of Prometheus project)  │
│  OpenTelemetry          │  ✅ CNCF Incubating (Collector + SDK)            │
│  Grafana OSS            │  ❌ Not CNCF — Grafana Labs owned               │
│  Grafana Loki           │  ❌ Not CNCF — Grafana Labs owned               │
│  Grafana Tempo          │  ❌ Not CNCF — Grafana Labs owned               │
│  Grafana Mimir          │  ❌ Not CNCF — Grafana Labs owned (Cortex is)   │
│  Grafana Alloy          │  ❌ Not CNCF — Grafana Labs owned               │
│  Grafana Pyroscope      │  ❌ Not CNCF — Grafana Labs owned               │
│  Prometheus Operator    │  ❌ Not CNCF — community maintained             │
│  kube-state-metrics     │  ✅ Kubernetes SIG-instrumentation project       │
│  Thanos (related)       │  ✅ CNCF Incubating                             │
│  Cortex (Mimir ancestor)│  ✅ CNCF Incubating                             │
└─────────────────────────┴──────────────────────────────────────────────────┘

Key insight: the non-CNCF components (Grafana Labs stack) are backed by
a $6B company with a direct commercial interest in their quality.
The CNCF status matters less when there is strong commercial sustainability.
The risk framework (Section 4) applies regardless of CNCF membership.
```

---

## 3. Why kube-prometheus-stack — and Production Adoption

### Why Not Run Prometheus Directly on Kubernetes

You could deploy the Prometheus binary as a plain StatefulSet with a ConfigMap
for `prometheus.yaml`. This works on day one. Here is what breaks from day two:

```
Problem 1: New service deployed → you manually edit prometheus.yaml
  Edit ConfigMap → kubectl apply → Prometheus does NOT auto-reload
  You must exec into the pod and POST to /-/reload manually
  Repeat for every new service every team deploys — this becomes a bottleneck

Problem 2: Pod restarts → IPs change → config is immediately stale
  Pod was at 10.244.0.12 — now it is 10.244.0.47 after a crash
  Static scrape_config still points to the old IP
  Prometheus scrapes fail silently. up{...} = 0. You notice during the incident.

Problem 3: Alert rules in ConfigMaps have no validation
  Bad PromQL syntax deploys successfully — ConfigMap accepts any text
  Prometheus loads config, hits invalid rule, silently skips the entire group
  Your critical alert is now disabled. You find out when it never fires.

Problem 4: Every component wired manually
  Grafana data source URL, Alertmanager URL, Node Exporter ServiceMonitor,
  kube-state-metrics RBAC, Prometheus RBAC — all separate manual steps
  Each upgrade of any one component risks breaking all the wiring

Problem 5: Pod IP changes on every rolling deployment
  Kubernetes replaces pods constantly. Static configs go stale constantly.
  In a team deploying 20 times per day, manual config management is untenable.
```

kube-prometheus-stack solves all of these through two mechanisms: the
**Prometheus Operator** (which replaces manual prometheus.yaml with self-service
CRDs and dynamic Kubernetes service discovery), and the **Helm chart** (which
pre-wires all component connections and manages upgrades as a single unit).

```
What kube-prometheus-stack gives you out of the box:

  ServiceMonitor CRD    → teams self-service their own scrape configs
  PrometheusRule CRD    → alert rules validated by admission webhook before apply
  Kubernetes discovery  → pod IP changes handled automatically, always current
  config-reloader       → Prometheus config reloads without pod restart
  All RBAC pre-built    → ServiceAccounts, ClusterRoles, ClusterRoleBindings
  PVC pre-configured    → TSDB data persists across pod restarts
  Grafana pre-wired     → Prometheus data source provisioned on first boot
  20+ dashboards        → K8s cluster dashboards loaded automatically
  Self-monitoring       → Prometheus, Alertmanager, Grafana all scrape themselves
  One upgrade command   → helm upgrade handles all component versions together
```

The Prometheus binary inside kube-prometheus-stack is unchanged — it is the
same binary from `prom/prometheus:v3.3.1`. You are not trading away Prometheus.
You are adding the scaffolding that makes it operationally manageable in a
dynamic Kubernetes environment.

### Production Adoption

kube-prometheus-stack is the de facto standard for Kubernetes monitoring in
corporate environments. It is deployed across:

- Financial services companies monitoring trading and payments infrastructure
- Telcos running network function monitoring on Kubernetes
- E-commerce platforms monitoring order pipelines and inventory systems
- SaaS companies using it as the monitoring backbone for their own products
- Cloud providers (AWS, GCP, Azure) who publish documented upgrade paths
  for it alongside their managed Kubernetes release notes

Red Hat ships a supported, security-patched version of the Prometheus Operator
as the monitoring foundation of every OpenShift cluster globally. This is the
same codebase — which means thousands of enterprise OpenShift deployments are
running production-grade Prometheus Operator, with Red Hat's security team
actively reviewing and patching it.

---

## 4. Security Posture — Full Stack Assessment

This is a question every responsible engineer should ask before adopting
infrastructure tooling. Here is an honest, detailed assessment of every
component in the stack.

### Evaluating Any Open-Source Tool — The Framework

The question "is this safe?" applies to every component across all 25 demos.
Use this framework consistently:

```
1. Maintainer health
   How many active maintainers from how many organisations?
   Single-person or single-company projects carry high bus-factor risk.

2. Commercial backing
   Is there a company with a financial interest in fixing CVEs fast?
   Red Hat shipping the Prometheus Operator in OpenShift = strong backing.

3. Attack surface
   Does it handle external internet traffic? (highest risk)
   Is it internal-only with read access? (manageable risk)
   Prometheus is monitoring-plane only — not in the path of user traffic.

4. Formal governance
   CNCF Graduated = security audit + disclosure process + governance structure.
   Community-only = review the maintainer list and contribution history yourself.

5. Exit strategy
   If this project disappeared tomorrow, what is your plan?
   For kube-prometheus-stack: Grafana Labs and Red Hat both maintain
   compatible distributions using the same Prometheus Operator codebase.
```

### What Is and Is Not Formally Audited

```
Prometheus binary (CNCF Graduated):
  ✅ Independent security audit completed as part of CNCF graduation requirement
  ✅ Formal CVE disclosure process via security@prometheus.io
  ✅ Mandatory CNCF Code of Conduct and governance structure
  ✅ Core Infrastructure Initiative Best Practices Badge maintained

Prometheus Operator:
  ✅ Active security review by Red Hat security team (commercial interest)
  ✅ CVE disclosures handled via maintainers listed in MAINTAINERS.md
  ✅ Admission webhook validates CRDs before apply — catches bad configs
  ⚠️  No independent third-party security audit on record (as of 2025)
  ⚠️  Not a CNCF project — no CNCF security infrastructure backing

kube-prometheus-stack Helm chart:
  ⚠️  Community maintained — no formal security SLA or CVE response process
  ⚠️  Bundles multiple components — a CVE in any bundled component
       (Grafana, Node Exporter) requires a chart upgrade to get the fix
  ✅  Apache 2.0 license — full source inspection is possible and encouraged
```

### Attack Surface — What Each Component Can and Cannot Access

```
Prometheus ServiceAccount ClusterRole permissions:
  get, list, watch on: nodes, nodes/metrics, services, endpoints, pods
  get on: /metrics (across all namespaces)
  Purpose: Kubernetes service discovery — Prometheus needs to find targets

  A compromised Prometheus pod could read cluster topology —
  which namespaces exist, which pods are running, which services are exposed.
  It cannot write to the Kubernetes API, cannot create/delete resources,
  and cannot read Kubernetes Secrets (unless you explicitly add that permission).

Prometheus network access:
  Outbound: scrapes /metrics on all pod IPs it discovers — cluster-internal only
  Inbound:  port 9090 receives PromQL queries — should be cluster-internal only
  ⚠️  Never expose Prometheus port 9090 externally without authentication
      Use Grafana as the authenticated query frontend instead

Alertmanager:
  Outbound: sends webhooks/emails to configured receivers (Slack, PagerDuty)
  Inbound:  port 9093 receives alerts from Prometheus — cluster-internal only
  No Kubernetes API access — only receives and routes alerts

Node Exporter:
  Mounts host filesystem read-only: /proc, /sys
  Has hostPID and hostNetwork access on the node
  ⚠️  Highest-privilege component in the stack — runs with broad host access
      Mitigate: restrict Node Exporter Service to cluster-internal access only
      Never expose port 9100 externally

kube-state-metrics:
  ClusterRole: get, list, watch across all Kubernetes API resources
  Broader than Prometheus — reads deployments, PVCs, ConfigMaps, etc.
  No write access. No Secrets access by default.
```

### Security Posture of the Grafana Stack

```
Grafana OSS:
  ⚠️  Highest CVE frequency of any component in the stack
      Reason: complex web application with SQL, HTML templating, OAuth
      CVE types: XSS, SQL injection (in older versions), auth bypass
  ✅  AGPLv3 — full source is auditable
  ✅  Grafana Labs security team actively responds to disclosures
  ✅  Monitor: github.com/grafana/grafana/security/advisories
  ✅  Mitigate: always enable authentication, never run anonymous access
               pin chart version, upgrade promptly when CVEs are published

Grafana Loki:
  ✅  Simpler attack surface — log ingestion and query API
  ✅  Multi-tenant isolation tested at Grafana Cloud scale
  ✅  No full-text index — reduces attack surface vs Elasticsearch
  ⚠️  LogQL injection possible if user-supplied input reaches queries
      Mitigate: use parameterised queries, never interpolate user input

Grafana Tempo:
  ✅  Object storage backend — read-only query API
  ✅  OTLP ingest endpoint — validate and drop malformed spans
  ✅  Limited attack surface — no web UI complexity like Grafana

Grafana Alloy:
  ✅  Apache 2.0 — permissive licence, no copyleft concerns
  ✅  OTel-native — standards-based, audited protocols
  ⚠️  Runs as DaemonSet with broad host access for log collection
      Mitigate: restrict Alloy ServiceAccount to minimum required permissions
               use NetworkPolicy to restrict Alloy outbound destinations

Grafana Mimir:
  ✅  Designed for multi-tenant isolation from day one
  ✅  X-Scope-OrgID header provides tenant boundary
  ⚠️  Distributor is internet-facing in managed deployments
      Mitigate: place behind authentication proxy in self-hosted environments

Mandatory practices for this demo series:
  1. Authentication always enabled in Grafana (adminPassword set in values.yaml)
  2. Never expose Grafana port 3000 externally without TLS + auth in production
  3. Pin Grafana version explicitly — never use latest tag
  4. Subscribe to: github.com/grafana/grafana/security/advisories
  5. In production: use SAML/OIDC — not local password authentication
```

### Known CVE Pattern and Response

Prometheus and its ecosystem components have a healthy CVE disclosure and
response pattern — vulnerabilities are found, reported responsibly, and patched.
No critical unauthenticated remote code execution vulnerabilities have been
disclosed in Prometheus core. The CVEs that have appeared are predominantly
medium-severity issues in bundled base images (busybox) or dependency libraries,
not in Prometheus's own code.

Grafana, bundled in the chart, has had a higher CVE frequency due to its
complexity as a web application. This is the most important component to keep
current in the stack.

### Mandatory Security Practices for This Demo Series

```
1. Never expose Prometheus, Alertmanager, or Node Exporter externally
   All access via kubectl port-forward or internal Grafana only

2. Always pin explicit image and chart versions
   helm install ... --version 68.4.4 (never omit --version)
   Prevents surprise breaking changes and supply chain substitution

3. Always use an explicit values.yaml
   Never helm install without --values — implicit defaults are not reviewed

4. Subscribe to security advisories for every bundled component
   github.com/prometheus/prometheus/security/advisories
   github.com/grafana/grafana/security/advisories
   github.com/prometheus-operator/prometheus-operator/releases

5. Scan images before production use
   trivy image prom/prometheus:v3.3.1
   trivy image grafana/grafana:11.6.0

6. Run Grafana with authentication always enabled
   In production: OIDC/SSO, not local passwords
   adminPassword in values.yaml is for demos only — use a Secret in production

7. In production: use SAML/OIDC for Grafana — not local password authentication
```

---

## 5. What the Helm Chart Installs

Running `helm install kube-prometheus-stack` installs the following
Kubernetes objects. Understanding the full list prevents surprises when
you inspect your cluster.

**Verify your installation matches — run these commands:**

```bash
kubectl get all -n monitoring
kubectl get crd | grep monitoring.coreos.com
kubectl get clusterrole | grep prometheus
kubectl get clusterrolebinding | grep prometheus
kubectl get cm -n monitoring
kubectl get secrets -n monitoring
```

### Actual Cluster Output — kubectl get all -n monitoring

```
NAME                                                           READY   STATUS    RESTARTS   AGE
pod/alertmanager-kube-prometheus-stack-alertmanager-0          2/2     Running   0          21m
pod/kube-prometheus-stack-grafana-5dcc9b7b8d-7j7jz             3/3     Running   0          21m
pod/kube-prometheus-stack-kube-state-metrics-cbbcc4559-skrw6   1/1     Running   0          21m
pod/kube-prometheus-stack-operator-7d4c7cf5dd-6xh22            1/1     Running   0          21m
pod/kube-prometheus-stack-prometheus-node-exporter-pq2x9       1/1     Running   0          21m
pod/prometheus-kube-prometheus-stack-prometheus-0              2/2     Running   0          21m

NAME                                                     TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)                      AGE
service/alertmanager-operated                            ClusterIP   None             <none>        9093/TCP,9094/TCP,9094/UDP   21m
service/kube-prometheus-stack-alertmanager               ClusterIP   10.105.187.53    <none>        9093/TCP,8080/TCP            21m
service/kube-prometheus-stack-grafana                    ClusterIP   10.100.178.25    <none>        80/TCP                       21m
service/kube-prometheus-stack-kube-state-metrics         ClusterIP   10.100.112.104   <none>        8080/TCP                     21m
service/kube-prometheus-stack-operator                   ClusterIP   10.108.100.15    <none>        443/TCP                      21m
service/kube-prometheus-stack-prometheus                 ClusterIP   10.96.181.154    <none>        9090/TCP,8080/TCP            21m
service/kube-prometheus-stack-prometheus-node-exporter   ClusterIP   10.99.182.126    <none>        9100/TCP                     21m
service/prometheus-operated                              ClusterIP   None             <none>        9090/TCP                     21m

NAME                                                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
daemonset.apps/kube-prometheus-stack-prometheus-node-exporter   1         1         1       1            1           kubernetes.io/os=linux

NAME                                                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/kube-prometheus-stack-grafana              1/1     1            1           21m
deployment.apps/kube-prometheus-stack-kube-state-metrics   1/1     1            1           21m
deployment.apps/kube-prometheus-stack-operator             1/1     1            1           21m

NAME                                                                 DESIRED   CURRENT   READY   AGE
replicaset.apps/kube-prometheus-stack-grafana-5dcc9b7b8d             1         1         1       21m
replicaset.apps/kube-prometheus-stack-kube-state-metrics-cbbcc4559   1         1         1       21m
replicaset.apps/kube-prometheus-stack-operator-7d4c7cf5dd            1         1         1       21m

NAME                                                               READY   AGE
statefulset.apps/alertmanager-kube-prometheus-stack-alertmanager   1/1     21m
statefulset.apps/prometheus-kube-prometheus-stack-prometheus       1/1     21m
```

### About Workloads

```
StatefulSet: prometheus-kube-prometheus-stack-prometheus-0
  Purpose:    The Prometheus TSDB, scraper, and rule evaluator
  Storage:    10Gi PVC (TSDB data)
  Containers: prometheus, config-reloader
    Container 1: prometheus        — TSDB + scraper + rule evaluator
    Container 2: config-reloader   — watches generated config, triggers /-/reload
  StatefulSet because TSDB data lives on a 10Gi PVC

StatefulSet: alertmanager-kube-prometheus-stack-alertmanager-0
  Purpose:    Alert deduplication, grouping, and routing
  Storage:    1Gi PVC (silence state)
  Containers: alertmanager, config-reloader
    Container 1: alertmanager      — the routing daemon
    Container 2: config-reloader   — watches for config changes, triggers reload
  StatefulSet because it stores silence state on a PVC

Deployment: kube-prometheus-stack-grafana
  Purpose:    Dashboard visualisation and unified alerting UI
  Storage:    1Gi PVC (Grafana SQLite database)
  Containers: grafana, grafana-sc-datasources, grafana-sc-dashboard
    Container 1: grafana                — the Grafana server
    Container 2: grafana-sc-datasources — sidecar: loads data sources from ConfigMaps
    Container 3: grafana-sc-dashboard   — sidecar: loads dashboards from ConfigMaps
  The sidecars enable provisioning — dashboards load automatically, no manual setup

Deployment: kube-prometheus-stack-operator
  Purpose:    Watches CRDs, generates Prometheus config, triggers reloads
  Containers: kube-prometheus-stack-operator
    Container 1: operator          — Kubernetes controller, reconciles CRDs to config

Deployment: kube-prometheus-stack-kube-state-metrics
  Purpose:    Queries Kubernetes API, exposes object state as metrics
  Containers: kube-state-metrics
    Container 1: kube-state-metrics — talks to kube-apiserver, serves /metrics on 8080

DaemonSet: kube-prometheus-stack-prometheus-node-exporter
  Purpose:    Exposes host-level OS metrics from every node
  Containers: node-exporter
    Container 1: node-exporter     — reads /proc and /sys, serves /metrics on 9100
  HostPID:    true (needed for process metrics — reads host /proc namespace)
  HostNetwork:true (needed for real network interface metrics, not just veth)
  One pod per node — kubernetes.io/os=linux node selector
```

### About Services

There are **8 Services** installed — 6 named ClusterIP services and 2 headless
services. The distinction matters: named ClusterIP services are for human access
and cross-component communication; headless services are for StatefulSet peer
discovery and internal cluster DNS.

```
Actual output: kubectl get svc -n monitoring

NAME                                             TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)
alertmanager-operated                            ClusterIP   None             <none>        9093/TCP,9094/TCP,9094/UDP
kube-prometheus-stack-alertmanager               ClusterIP   10.105.187.53    <none>        9093/TCP,8080/TCP
kube-prometheus-stack-grafana                    ClusterIP   10.100.178.25    <none>        80/TCP
kube-prometheus-stack-kube-state-metrics         ClusterIP   10.100.112.104   <none>        8080/TCP
kube-prometheus-stack-operator                   ClusterIP   10.108.100.15    <none>        443/TCP
kube-prometheus-stack-prometheus                 ClusterIP   10.96.181.154    <none>        9090/TCP,8080/TCP
kube-prometheus-stack-prometheus-node-exporter   ClusterIP   10.99.182.126    <none>        9100/TCP
prometheus-operated                              ClusterIP   None             <none>        9090/TCP
```

**Named ClusterIP Services — for access and scraping:**

```
kube-prometheus-stack-prometheus
  ClusterIP:  10.96.181.154
  Ports:      9090 (Prometheus UI + query API)
              8080 (metrics — Prometheus self-monitoring endpoint)
  Used by:    Grafana → queries PromQL via this service
              kubectl port-forward → your local browser access
              Prometheus Operator → validates config reload via /-/reload
  ⚠️  Use this service for port-forward and all external access.
      Do NOT use prometheus-operated for UI access (see headless section below).

kube-prometheus-stack-alertmanager
  ClusterIP:  10.105.187.53
  Ports:      9093 (Alertmanager API + UI)
              8080 (metrics — Alertmanager self-monitoring endpoint)
  Used by:    Prometheus → sends fired alerts via POST /api/v2/alerts
              kubectl port-forward → your local browser access
              amtool CLI → silence management
  ⚠️  Use this service for port-forward and all external access.
      Do NOT use alertmanager-operated for UI access.

kube-prometheus-stack-grafana
  ClusterIP:  10.100.178.25
  Port:       80 (proxies to container port 3000)
  Used by:    kubectl port-forward → your local browser access
              Ingress controller → if you expose Grafana externally

kube-prometheus-stack-operator
  ClusterIP:  10.108.100.15
  Port:       443 (admission webhook HTTPS endpoint)
  Used by:    Kubernetes API server → validates PrometheusRule and other CRDs
              before they are stored (admission webhook)
  Note:       This is not a UI — it is the webhook that validates CRD YAML

kube-prometheus-stack-kube-state-metrics
  ClusterIP:  10.100.112.104
  Port:       8080 (/metrics endpoint)
  Used by:    Prometheus → scrapes Kubernetes object state metrics every 15s

kube-prometheus-stack-prometheus-node-exporter
  ClusterIP:  10.99.182.126
  Port:       9100 (/metrics endpoint)
  Used by:    Prometheus → scrapes host OS metrics from each node every 15s
```

**Headless Services (ClusterIP: None) — for StatefulSet internal use:**

```
prometheus-operated
  ClusterIP:  None (headless)
  Port:       9090
  Created by: Prometheus Operator automatically when it creates the Prometheus StatefulSet
  Used by:    Kubernetes DNS — provides stable DNS name for each Prometheus replica:
                prometheus-kube-prometheus-stack-prometheus-0.prometheus-operated.monitoring.svc
              Thanos sidecar (if used) — discovers Prometheus peers for federation
              ⚠️  NOT used for kubectl port-forward or UI access
              ⚠️  NOT used by Grafana — Grafana uses kube-prometheus-stack-prometheus

alertmanager-operated
  ClusterIP:  None (headless)
  Ports:      9093 (API), 9094/TCP (gossip), 9094/UDP (gossip)
  Created by: Prometheus Operator automatically when it creates the Alertmanager StatefulSet
  Used by:    Alertmanager gossip mesh (port 9094) — when running HA with replicas: 3,
                Alertmanager pods discover each other via this headless service:
                alertmanager-kube-prometheus-stack-alertmanager-0.alertmanager-operated.monitoring.svc
                alertmanager-kube-prometheus-stack-alertmanager-1.alertmanager-operated.monitoring.svc
              Prometheus → sends alerts to Alertmanager via this service's DNS
              ⚠️  NOT used for kubectl port-forward or UI access
              ⚠️  For UI access always use kube-prometheus-stack-alertmanager

Why headless services exist:
  A headless Service (ClusterIP: None) does not get a virtual IP.
  Instead, DNS returns the actual pod IPs directly.
  This allows StatefulSet pods to address each other by stable, predictable
  DNS names regardless of pod IP changes — essential for:
    - Alertmanager gossip: peers must find each other after pod restarts
    - Thanos federation: Thanos sidecar must address specific Prometheus pods
    - Ordered StatefulSet startup: pod-0 must come up before pod-1
```

### About ConfigMaps

There are **33 ConfigMaps** installed. They fall into four groups:

```
Actual output: kubectl get cm -n monitoring

NAME                                                      DATA   PURPOSE
─────────────────────────────── Group 1: Grafana Config ────────────────────────────────
kube-prometheus-stack-grafana                              1     grafana.ini — main Grafana server config
                                                                 Sets: server root_url, auth, unified_alerting,
                                                                 SMTP, feature flags, security settings

kube-prometheus-stack-grafana-config-dashboards            1     Grafana dashboard provisioning config
                                                                 Tells Grafana which directories to watch
                                                                 for dashboard JSON files to auto-load

kube-prometheus-stack-grafana-datasource                   1     Prometheus data source definition
                                                                 Auto-provisioned on first boot by
                                                                 grafana-sc-datasources sidecar.
                                                                 Points Grafana at kube-prometheus-stack-prometheus:9090

─────────────────────────── Group 2: Pre-loaded Grafana Dashboards ─────────────────────
kube-prometheus-stack-alertmanager-overview                1     Alertmanager status dashboard
kube-prometheus-stack-apiserver                            1     Kubernetes API server dashboard
kube-prometheus-stack-cluster-total                        1     Cluster-level resource totals dashboard
kube-prometheus-stack-controller-manager                   1     kube-controller-manager dashboard
kube-prometheus-stack-etcd                                 1     etcd health and performance dashboard
kube-prometheus-stack-grafana-overview                     1     Grafana self-monitoring dashboard
kube-prometheus-stack-k8s-coredns                          1     CoreDNS dashboard
kube-prometheus-stack-k8s-resources-cluster                1     Cluster CPU/memory resource usage
kube-prometheus-stack-k8s-resources-multicluster           1     Multi-cluster resource overview
kube-prometheus-stack-k8s-resources-namespace              1     Per-namespace resource usage
kube-prometheus-stack-k8s-resources-node                   1     Per-node resource breakdown
kube-prometheus-stack-k8s-resources-pod                    1     Per-pod resource usage
kube-prometheus-stack-k8s-resources-workload               1     Per-workload (Deployment/StatefulSet) view
kube-prometheus-stack-k8s-resources-workloads-namespace    1     Workloads by namespace
kube-prometheus-stack-kubelet                              1     Kubelet health and performance
kube-prometheus-stack-namespace-by-pod                     1     Namespace resource view grouped by pod
kube-prometheus-stack-namespace-by-workload                1     Namespace resource view by workload
kube-prometheus-stack-node-cluster-rsrc-use                1     Node cluster resource utilisation
kube-prometheus-stack-node-rsrc-use                        1     Node resource utilisation detail
kube-prometheus-stack-nodes                                1     Node Exporter — full node dashboard
kube-prometheus-stack-nodes-aix                            1     Node dashboard for AIX systems
kube-prometheus-stack-nodes-darwin                         1     Node dashboard for macOS/Darwin nodes
kube-prometheus-stack-persistentvolumesusage               1     PersistentVolume usage dashboard
kube-prometheus-stack-pod-total                            1     Pod totals dashboard
kube-prometheus-stack-prometheus                           1     Prometheus self-monitoring dashboard
kube-prometheus-stack-proxy                                1     kube-proxy dashboard
kube-prometheus-stack-scheduler                            1     kube-scheduler dashboard
kube-prometheus-stack-workload-total                       1     Workload totals dashboard

─────────────────────────── Group 3: Generated Prometheus Rule Files ───────────────────
prometheus-kube-prometheus-stack-prometheus-rulefiles-0   35     All alerting and recording rules
                                                                 Generated by Prometheus Operator from
                                                                 PrometheusRule CRDs. Contains 35 rule
                                                                 groups covering: Kubernetes alerts,
                                                                 Node alerts, Prometheus self-alerts,
                                                                 etcd alerts, and community rules.
                                                                 Mounted into the Prometheus pod at
                                                                 /etc/prometheus/rules/

─────────────────────────── Group 4: System ────────────────────────────────────────────
kube-root-ca.crt                                           1     Cluster root CA certificate
                                                                 Standard Kubernetes ConfigMap injected
                                                                 into every namespace automatically.
                                                                 Not created by kube-prometheus-stack.
```

**How the dashboard ConfigMaps work:**

```
Each dashboard ConfigMap contains one key: the dashboard JSON file.
The ConfigMap has a specific label: grafana_dashboard=1

The grafana-sc-dashboard sidecar container in the Grafana pod:
  1. Watches all ConfigMaps cluster-wide for label grafana_dashboard=1
  2. When found: copies the JSON content to /tmp/dashboards/<folder>/
  3. Grafana's dashboard provisioner watches that directory
  4. New dashboard JSON files are loaded automatically without restart

This is the provisioning pattern — dashboards are declared in Git (ConfigMaps),
not manually imported. Adding a new dashboard = creating a new ConfigMap.
```

### About Secrets

There are **12 Secrets** installed. They fall into four groups:

```
Actual output: kubectl get secrets -n monitoring

NAME                                                                             TYPE
─────────────────────────── Group 1: Grafana ────────────────────────────────────────
kube-prometheus-stack-grafana                                                    Opaque
  Contains: admin-user (base64), admin-password (base64), ldap.toml (empty)
  Used by:  Grafana pod — mounts as environment variables for admin login
  ⚠️  In production: use adminCredentialsSecret to reference an external secret
       managed by Vault or AWS Secrets Manager — never commit these values to Git

─────────────────────────── Group 2: Alertmanager ────────────────────────────────────
alertmanager-kube-prometheus-stack-alertmanager                                  Opaque
  Contains: alertmanager.yaml — the main Alertmanager routing configuration
  Generated by: Prometheus Operator from the Alertmanager CRD + AlertmanagerConfig CRDs
  Mounted at:  /etc/alertmanager/config/ inside the Alertmanager pod
  Updated:     Operator regenerates and replaces this Secret when AlertmanagerConfig
               CRDs change. config-reloader sidecar detects change and reloads.

alertmanager-kube-prometheus-stack-alertmanager-cluster-tls-config               Opaque
  Contains: TLS configuration for Alertmanager cluster gossip mesh (peer-to-peer)
  Used by:  Alertmanager HA mode — encrypts gossip traffic between replicas
  Note:     Empty in single-replica setups but present for HA readiness

alertmanager-kube-prometheus-stack-alertmanager-generated                        Opaque
  Contains: The fully rendered Alertmanager config after all CRD merging
  Generated by: Prometheus Operator — the final merged config from
               alertmanager CRD + all AlertmanagerConfig namespace CRDs
  This is what Alertmanager actually reads — not the raw user config

alertmanager-kube-prometheus-stack-alertmanager-tls-assets-0                     Opaque
  Contains: TLS certificate assets for Alertmanager receivers
  Used by:  When Alertmanager sends to HTTPS receivers (PagerDuty, Slack)
  Note:     Empty if no TLS receiver certs are configured

alertmanager-kube-prometheus-stack-alertmanager-web-config                       Opaque
  Contains: Alertmanager web server TLS config (for HTTPS UI access)
  Used by:  Alertmanager web server — enables TLS on port 9093
  Note:     Contains empty config by default (HTTP mode) — populate for HTTPS

─────────────────────────── Group 3: Prometheus ──────────────────────────────────────
prometheus-kube-prometheus-stack-prometheus                                      Opaque
  Contains: prometheus.env.yaml — the fully generated Prometheus scrape config
  Generated by: Prometheus Operator from all ServiceMonitor/PodMonitor/ScrapeConfig CRDs
  Mounted at:  /etc/prometheus/config_out/ inside the Prometheus pod
  Updated:     Operator regenerates on every ServiceMonitor change.
               config-reloader sidecar detects Secret change via inotify → triggers /-/reload

prometheus-kube-prometheus-stack-prometheus-thanos-prometheus-http-client-file   Opaque
  Contains: HTTP client config for Thanos sidecar to call Prometheus API
  Used by:  Thanos sidecar (if enabled) — authenticates to Prometheus for federation
  Note:     Present even without Thanos — pre-provisioned for optional Thanos use

prometheus-kube-prometheus-stack-prometheus-tls-assets-0                         Opaque
  Contains: TLS certificate assets for scraping HTTPS targets
  Used by:  Prometheus — when scraping targets that require client TLS certificates
  Note:     Empty by default — populated when tlsConfig is set in ServiceMonitors

prometheus-kube-prometheus-stack-prometheus-web-config                           Opaque
  Contains: Prometheus web server TLS config (for HTTPS UI access)
  Used by:  Prometheus web server — enables TLS on port 9090
  Note:     Contains empty config by default (HTTP mode) — populate for HTTPS

─────────────────────────── Group 4: Admission Webhook ───────────────────────────────
kube-prometheus-stack-admission                                                  Opaque
  Contains: TLS certificate (tls.crt), TLS key (tls.key), CA certificate (ca.crt)
  Used by:  Prometheus Operator admission webhook server (port 443)
  Purpose:  The webhook validates PrometheusRule CRDs (checks PromQL syntax)
            before Kubernetes accepts them. Requires TLS — this Secret provides
            the certificate the webhook presents to the Kubernetes API server.
  Auto-rotated: The Operator manages certificate rotation automatically.

─────────────────────────── Group 5: Helm ───────────────────────────────────────────
sh.helm.release.v1.kube-prometheus-stack.v1                                      helm.sh/release.v1
  Contains: Full Helm release metadata (compressed, base64 encoded)
  Used by:  Helm CLI — stores release state for helm upgrade, helm rollback,
            helm history, helm status commands.
  Note:     Standard Helm release Secret — not specific to kube-prometheus-stack.
            v1 = first install. Each helm upgrade creates a new version (v2, v3...).
```

---

## 6. Component Deep Dive

### Prometheus Server

Prometheus is a single stateful Go binary. Inside the pod you have two containers:

```
Container: prometheus
  Binary:   /bin/prometheus
  Flags:    --config.file=/etc/prometheus/config_out/prometheus.env.yaml
            --storage.tsdb.path=/prometheus
            --storage.tsdb.retention.time=10d
            --web.enable-lifecycle          ← enables /-/reload API
            --enable-feature=native-histograms
  Volume mounts:
    /prometheus           ← PVC (TSDB data — persists across restarts)
    /etc/prometheus       ← generated config (from Secret, via volume)
    /etc/prometheus/rules ← rule files (from ConfigMap, via volume)

Container: config-reloader
  Binary:   /bin/prometheus-config-reloader
  Watches:  the config Secret and rule ConfigMaps via inotify
  On change: POST to http://localhost:9090/-/reload
  Purpose:  Prometheus reloads config without a pod restart
            A restart would lose the 2-hour head block data
```

**Prometheus internal subsystems:**

```
Scraper
  Reads the generated scrape_configs
  Sends HTTP GET /metrics to each target on its schedule
  Writes samples to the head block via the WAL

TSDB
  WAL (Write-Ahead Log): crash-safe buffer for incoming samples
  Head block: in-memory compressed storage for the last ~2 hours
  On-disk blocks: immutable 2-hour blocks flushed from head
  Compactor: background process merging small blocks into larger ones

Rule evaluator
  Runs every evaluation_interval (15s)
  Executes every recording rule → writes result as new metric series
  Executes every alerting rule → if result is non-empty, fires alert
  Fires alerts to Alertmanager via /api/v2/alerts endpoint

Query engine
  Handles HTTP requests to /api/v1/query and /api/v1/query_range
  Parses PromQL, loads data from TSDB, evaluates, returns JSON
  Used by Grafana, the Prometheus UI, and alert rule evaluation
```

### Prometheus Operator

The Operator is a Kubernetes controller following the operator pattern.
It uses client-go informers to watch CRD objects cluster-wide and reconcile
the Prometheus configuration to match the desired state.

```
Operator watch loop:
  1. Watches: ServiceMonitor, PodMonitor, Probe, ScrapeConfig,
              PrometheusRule, AlertmanagerConfig, Prometheus, Alertmanager
              (all via Kubernetes watch API — long-lived HTTP stream)

  2. On ServiceMonitor created/updated/deleted:
     a. Query Kubernetes Endpoints API for services matching spec.selector
     b. Generate scrape_config blocks for each matched endpoint
     c. Write the full prometheus.yaml to a Kubernetes Secret
     d. The config-reloader sidecar detects Secret change via inotify
     e. config-reloader POSTs to Prometheus /-/reload
     f. Prometheus reloads config (no restart) within 30 seconds

  3. On PrometheusRule created/updated/deleted:
     a. Validate the rule PromQL via the admission webhook
     b. Write rule files to a Kubernetes ConfigMap
     c. config-reloader detects ConfigMap change
     d. Prometheus reloads rules (no restart)

  4. On Prometheus CRD created (initial install):
     a. Create the StatefulSet for the Prometheus pod
     b. Create the ServiceAccount with required RBAC
     c. Create the Service for port 9090
     d. Create the PVC for TSDB storage (if storageSpec is set)

  Reconciliation is idempotent:
     The Operator continuously reconciles actual state to desired state.
     If the Secret is manually deleted, the Operator recreates it.
     If the StatefulSet is scaled down, the Operator scales it back up.
```

### Alertmanager

Alertmanager receives, deduplicates, groups, and routes alerts.
It does not evaluate alert expressions — that is Prometheus's job.

```
Alert lifecycle in Alertmanager:

  1. Prometheus fires: POST /api/v2/alerts
     [{
       "labels": {"alertname": "HighCPU", "severity": "warning", ...},
       "annotations": {"summary": "CPU is above 80%"},
       "startsAt": "2025-01-01T00:00:00Z",
       "endsAt": "0001-01-01T00:00:00Z"   ← zero time = still firing
     }]

  2. Alertmanager receives the alert
     Checks: is this alert already known? (deduplication by label fingerprint)
     If new: creates a new alert group entry

  3. Routing tree evaluation
     Walks the route tree top-to-bottom
     First matching route wins
     Determines: receiver, group_by labels, group_wait, group_interval

  4. Grouping
     Groups alerts with the same group_by label values together
     group_wait: how long to wait before sending first notification
                 (to batch related alerts arriving together)
     group_interval: how long to wait before sending subsequent notifications
                     for the same group

  5. Notification
     Sends to the matched receiver: Slack, PagerDuty, email, webhook
     repeat_interval: how long to wait before re-notifying if still firing
     resolve_timeout: if Prometheus stops sending an alert, Alertmanager
                     waits this long before marking it resolved

  6. Silence check
     Before notifying: check if any active silence matches the alert's labels
     If matched: suppress the notification (alert still tracked, just not sent)

  7. Inhibition check
     Before notifying: check if any inhibit_rules source alert is firing
     If matched: suppress the target alert notification
     (e.g. cluster-down alert inhibits all individual service alerts)
```

### Grafana

Grafana is a web application with a plugin architecture.
In the kube-prometheus-stack deployment, it has three containers:

```
Container: grafana
  Binary:   /run.sh (starts the Grafana server)
  Port:     3000
  Config:   /etc/grafana/grafana.ini (from ConfigMap)
  Database: SQLite at /var/lib/grafana/grafana.db (on PVC)
            Stores: dashboards, users, alert rules, API keys, teams
  Data sources: connected to Prometheus at http://prometheus-operated:9090

Container: grafana-sc-datasources (sidecar)
  Watches ConfigMaps with label: grafana_datasource=1
  Copies data source YAML files into /etc/grafana/provisioning/datasources/
  Grafana loads these on startup — no manual data source configuration
  This is how the Prometheus data source appears automatically on install

Container: grafana-sc-dashboard (sidecar)
  Watches ConfigMaps with label: grafana_dashboard=1
  Copies dashboard JSON into /tmp/dashboards/<folder>/
  Grafana watches the provisioning path and loads new dashboards hot
  This is how 20+ community dashboards appear automatically on install
```

**Grafana provisioning model:**

```
Data sources (auto-provisioned by sc-datasources sidecar):
  /etc/grafana/provisioning/datasources/
    prometheus.yaml → points to kube-prometheus-stack-prometheus:9090
  Grafana loads this on startup — never need to add data source manually

Dashboards (auto-provisioned by sc-dashboard sidecar):
  /tmp/dashboards/
    default/
      kubernetes-cluster.json      → K8s cluster overview (ID 15661)
      node-exporter-full.json      → Node Exporter full (ID 1860)
      alertmanager-overview.json   → Alertmanager status
      ... (20+ dashboards)
  ConfigMaps in the monitoring namespace provide these JSON files
  The sc-dashboard sidecar copies them into the provisioning path
  Grafana picks them up without restart
```

### Node Exporter

Node Exporter is the standard Prometheus exporter for Linux OS metrics.
It mounts the host filesystem read-only and reads from `/proc` and `/sys`.

```
Key metrics it exposes (subset):
  node_cpu_seconds_total            ← CPU time per mode (idle/user/system/iowait)
  node_memory_MemAvailable_bytes    ← available memory (MemAvailable from /proc/meminfo)
  node_memory_MemTotal_bytes        ← total physical RAM
  node_filesystem_avail_bytes       ← available disk space per device/mountpoint
  node_filesystem_size_bytes        ← total disk size per device/mountpoint
  node_network_receive_bytes_total  ← bytes received per network interface
  node_network_transmit_bytes_total ← bytes sent per network interface
  node_disk_read_bytes_total        ← bytes read from disk per device
  node_disk_write_bytes_total       ← bytes written to disk per device
  node_load1 / node_load5 / node_load15 ← system load averages
  node_systemd_unit_state           ← systemd service states
  node_uname_info                   ← kernel version info

DaemonSet host access requirements:
  hostPID: true           ← required for process metrics (process collector)
  hostNetwork: true       ← required for network interface metrics
  hostPath mounts:        /proc, /sys, /run/udev (all read-only)

Why these are safe:
  All mounts are read-only — Node Exporter cannot modify the host
  hostPID allows reading /proc/<pid>/ but not killing or signalling processes
  This is the standard, reviewed configuration used by every Node Exporter deployment
```

### kube-state-metrics

kube-state-metrics connects to the Kubernetes API server and exposes
Kubernetes object state as Prometheus metrics. It does not measure
resource consumption — it measures configuration state.

```
Metrics categories:
  kube_pod_*                   → pod phase, conditions, restarts, resource requests
  kube_deployment_*            → replica counts, rollout status, available replicas
  kube_replicaset_*            → replica sets
  kube_statefulset_*           → StatefulSet replica counts
  kube_daemonset_*             → DaemonSet scheduled/ready counts
  kube_node_*                  → node conditions, allocatable resources, taints
  kube_namespace_*             → namespace labels and conditions
  kube_persistentvolumeclaim_* → PVC status, capacity, storage class
  kube_resourcequota_*         → namespace quota usage vs limit
  kube_job_*                   → job completion, failure, duration
  kube_cronjob_*               → last schedule time, active jobs
  kube_service_*               → service type and labels
  kube_ingress_*               → ingress rules and TLS
  kube_configmap_*             → ConfigMap metadata
  kube_secret_*                → Secret metadata (no data — just existence)

Node Exporter vs kube-state-metrics:
  node_memory_MemAvailable_bytes       ← Node Exporter: actual RAM available NOW
  kube_node_status_allocatable         ← kube-state-metrics: RAM allocated to K8s
  node_cpu_seconds_total               ← Node Exporter: actual CPU time consumed
  kube_pod_container_resource_requests ← kube-state-metrics: CPU requested by pods
  These are completely different things — use both for complete visibility
```

---

## 7. CRDs — Every Custom Resource Explained

The Prometheus Operator installs **10 CRDs** in chart 84.5.0 (previously 9 — the
`prometheusagents` CRD was added to support Prometheus Agent mode, a new scrape-only
mode that forwards metrics without storing them locally).

**Actual output: kubectl get crd | grep monitoring.coreos.com**

```
alertmanagerconfigs.monitoring.coreos.com   2026-05-07T01:56:11Z
alertmanagers.monitoring.coreos.com         2026-05-07T01:56:11Z
podmonitors.monitoring.coreos.com           2026-05-07T01:56:11Z
probes.monitoring.coreos.com                2026-05-07T01:56:11Z
prometheusagents.monitoring.coreos.com      2026-05-07T01:56:11Z   ← NEW in 84.x
prometheuses.monitoring.coreos.com          2026-05-07T01:56:12Z
prometheusrules.monitoring.coreos.com       2026-05-07T01:56:12Z
scrapeconfigs.monitoring.coreos.com         2026-05-07T01:56:12Z
servicemonitors.monitoring.coreos.com       2026-05-07T01:56:12Z
thanosrulers.monitoring.coreos.com          2026-05-07T01:56:12Z
```

Each CRD replaces a specific manual configuration task that would otherwise
require editing files inside the Prometheus or Alertmanager pods.

### Prometheus CRD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: kube-prometheus-stack-prometheus
  namespace: monitoring
spec:
  # Which ServiceMonitors to discover (empty = all, via nil selector)
  serviceMonitorSelector: {}
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
  retention: 10d
  storage:
    volumeClaimTemplate:
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 10Gi
  alerting:
    alertmanagers:
      - namespace: monitoring
        name: kube-prometheus-stack-alertmanager
        port: http-web
```

**What the Operator does with this:**
Creates and manages the Prometheus StatefulSet, Service, ServiceAccount,
RBAC, and Secret — all derived from this single CRD object.

### Alertmanager CRD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Alertmanager
metadata:
  name: kube-prometheus-stack-alertmanager
  namespace: monitoring
spec:
  replicas: 1    # set to 3 for HA (requires gossip protocol)
  storage:
    volumeClaimTemplate:
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 1Gi
```

**What the Operator does with this:**
Creates and manages the Alertmanager StatefulSet. With replicas: 3,
Alertmanager uses a gossip protocol (mesh) to synchronise silence state
and notification deduplication across all three replicas.

### ServiceMonitor CRD

The most commonly created CRD by application teams. Tells Prometheus
which Service endpoints to scrape and how.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-api
  namespace: orders                 # lives in the app namespace
spec:
  selector:
    matchLabels:
      app: order-api                # matches Service labels
  endpoints:
    - port: http-metrics            # named port from the Service
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      scheme: http

      # TLS config if the /metrics endpoint requires HTTPS
      # tlsConfig:
      #   ca:
      #     secret:
      #       name: order-api-metrics-tls
      #       key: ca.crt

      # Drop specific metrics before storage (reduce cardinality)
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: 'go_gc_.*'         # drop Go GC metrics (reduce cardinality)
          action: drop

  namespaceSelector:
    matchNames:
      - orders                      # only look in the 'orders' namespace

  # Add extra labels to all scraped metrics
  targetLabels:
    - team                          # adds team="..." label from Service labels

```

**Key: the Operator generates this scrape_config from the ServiceMonitor:**

```yaml
- job_name: orders/order-api/0
  honor_timestamps: true
  scrape_interval: 15s
  scrape_timeout: 10s
  metrics_path: /metrics
  kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names: [orders]
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_label_app]
      regex: order-api
      action: keep
    - source_labels: [__meta_kubernetes_endpoint_port_name]
      regex: http-metrics
      action: keep
    # ... additional auto-generated relabeling for pod/service/namespace labels
```

### PodMonitor CRD

Scrapes pods directly without requiring a Service. Use when:
- The pod has no Service (e.g. a batch job, a DaemonSet with no ClusterIP)
- You want per-pod scraping with different configs than the Service provides

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: my-batch-job
  namespace: jobs
spec:
  selector:
    matchLabels:
      app: batch-processor
  podMetricsEndpoints:
    - port: metrics     # named port from the pod spec
      path: /metrics
      interval: 60s     # batch jobs — scrape less frequently
```

### PrometheusRule CRD

Defines alerting and recording rules. The Operator validates PromQL
via the admission webhook before the CRD is accepted.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: order-api-alerts
  namespace: orders
spec:
  groups:
    - name: order_api_slos
      interval: 15s
      rules:
        # Recording rule — pre-computed metric
        - record: namespace:http_requests:rate5m
          expr: sum by (namespace)(rate(http_requests_total[5m]))
        # Alerting rule
        - alert: OrderApiHighErrorRate
          expr: |
            sum(rate(http_requests_total{namespace="orders",status=~"5.."}[5m]))
            /
            sum(rate(http_requests_total{namespace="orders"}[5m]))
            > 0.01
          for: 2m         # must be true for 2 minutes before firing
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Order API error rate above 1%"
            description: "Error rate is {{ $value | humanizePercentage }}"
            runbook_url: "https://wiki.internal/runbooks/order-api-errors"
```

**Admission webhook validation — what gets caught before apply:**

```
Invalid PromQL:
  expr: rate(http_requests_total)   # missing [range]
  → Webhook rejects: "expected type range vector in call to function rate"

Invalid alert name:
  alert: "High Error Rate"          # spaces not allowed
  → Webhook rejects: "invalid metric name"

Valid PromQL, wrong semantic type:
  expr: rate(node_memory_MemAvailable_bytes[5m])  # gauge, not counter
  → Webhook accepts (PromQL is syntactically valid) but result is incorrect
  → This is why understanding metric types matters (covered in Demo 01)
```

### AlertmanagerConfig CRD

Defines Alertmanager routing config per-namespace. Application teams can
manage their own alert routing without touching the global Alertmanager config.

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: order-api-routing
  namespace: orders
spec:
  route:
    receiver: order-team-slack
    matchers:
      - name: namespace
        value: orders
    groupBy: [alertname]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
  receivers:
    - name: order-team-slack
      slackConfigs:
        - apiURL:
            name: order-team-slack-webhook
            key: url
          channel: '#order-alerts'
          title: '{{ .GroupLabels.alertname }}'
          text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

### ScrapeConfig CRD

For scraping targets that do not have a Kubernetes Service —
static IPs, external services, or non-Kubernetes workloads.

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: external-redis
  namespace: monitoring
spec:
  staticConfigs:
    - targets:
        - redis.internal.example.com:9121
      labels:
        job: redis
        environment: production
  metricsPath: /metrics
  scrapeInterval: 30s
```

### Probe CRD (Blackbox Exporter)

Configures HTTP/TCP/ICMP probes via the Blackbox Exporter.
Covered in full in Demo 19.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: checkout-api-probe
  namespace: monitoring
spec:
  prober:
    url: kube-prometheus-stack-blackbox-exporter:19115
  module: http_2xx
  targets:
    staticConfig:
      static:
        - https://checkout.example.com/health
        - https://checkout.example.com/api/status
```

### PrometheusAgent CRD

New in chart 84.x — deploys Prometheus in **agent mode**. Agent mode scrapes
targets and immediately remote_writes metrics to a central backend (Mimir, Thanos)
without storing any data locally. No TSDB, no local retention, no PromQL queries.

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: PrometheusAgent
metadata:
  name: edge-agent
  namespace: monitoring
spec:
  # Agent mode: scrape only, remote_write immediately, no local TSDB
  remoteWrite:
    - url: http://mimir-distributor.monitoring:8080/api/v1/push
      headers:
        X-Scope-OrgID: edge-cluster-1

  # Same ServiceMonitor/PodMonitor discovery as full Prometheus
  serviceMonitorSelector: {}

  resources:
    requests:
      cpu: 50m
      memory: 128Mi    # much lower than full Prometheus — no TSDB RAM cost
```

```
When to use PrometheusAgent vs Prometheus:

  Full Prometheus (Prometheus CRD):
    ✅ Local TSDB — historical queries without external backend
    ✅ PromQL queries locally
    ✅ Alerting rules evaluated locally
    ✅ Works standalone without a remote backend
    ❌ Requires significant RAM for TSDB head block
    ❌ Local disk for TSDB storage
    Use for: primary cluster monitoring, standalone environments

  PrometheusAgent (PrometheusAgent CRD):
    ✅ Very low RAM footprint — no TSDB
    ✅ No local disk needed
    ✅ Ideal for edge clusters, ephemeral nodes, large fleets
    ✅ Scales to many clusters cheaply when using central Mimir
    ❌ No local querying — Grafana must query the remote backend
    ❌ No local alerting — alerts must be evaluated at the remote backend
    Use for: Demo 22 (Mimir) multi-cluster pattern, agent mode deployments
```

### ThanosRuler CRD

For federated alerting across multiple Prometheus instances using Thanos.
Out of scope for the demo series — documented for completeness.

---

## 8. Configuration Files and How They Are Generated

### prometheus.yaml — The Generated Config

The Prometheus Operator generates `prometheus.yaml` and stores it in a Secret.
You never edit this file directly — it is regenerated on every ServiceMonitor change.

**Where it lives inside the pod:**
```bash
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  cat /etc/prometheus/config_out/prometheus.env.yaml
```

**Structure of the generated config:**
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

alerting:
  alertmanagers:
    - kubernetes_sd_configs:
        - role: endpoints
          namespaces:
            names: [monitoring]
      scheme: http
      path_prefix: /
      timeout: 10s

rule_files:
  - /etc/prometheus/rules/prometheus-kube-prometheus-stack-prometheus-rulefiles-0/*.yaml

scrape_configs:
  # One job per ServiceMonitor/PodMonitor/Probe — auto-generated
  - job_name: monitoring/kube-prometheus-stack-node-exporter/0
    honor_timestamps: true
    scrape_interval: 15s
    ...
  - job_name: default/test-app/0
    honor_timestamps: true
    scrape_interval: 15s
    ...
  # ... (one per ServiceMonitor)
```

### Alertmanager Config

Alertmanager config is stored in a Kubernetes Secret and mounted into the pod.
The Operator reconciles it from the Alertmanager CRD + AlertmanagerConfig CRDs.

```bash
# View the current Alertmanager config
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- \
  cat /etc/alertmanager/config_out/alertmanager.env.yaml
```

### Grafana Config

Grafana is configured via `grafana.ini` in a ConfigMap.

```bash
# View the Grafana config
kubectl get configmap kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.grafana\.ini}'
```

Key sections:
```ini
[server]
root_url = http://localhost:3000

[auth.anonymous]
enabled = false

[unified_alerting]
enabled = true

[alerting]
enabled = false       # legacy alerting disabled — unified_alerting only in Grafana 11
```

---

## 9. RBAC — Who Has Access to What

Understanding RBAC is essential for both security auditing and
debugging permission errors (the most common silent failure mode).

**Actual output: kubectl get clusterrole | grep prometheus**

```
kube-prometheus-stack-grafana-clusterrole     2026-05-07T01:56:21Z
kube-prometheus-stack-kube-state-metrics      2026-05-07T01:56:21Z
kube-prometheus-stack-operator                2026-05-07T01:56:21Z
kube-prometheus-stack-prometheus              2026-05-07T01:56:21Z
```

**Actual output: kubectl get clusterrolebinding | grep prometheus**

```
kube-prometheus-stack-grafana-clusterrolebinding   ClusterRole/kube-prometheus-stack-grafana-clusterrole     49m
kube-prometheus-stack-kube-state-metrics           ClusterRole/kube-prometheus-stack-kube-state-metrics       49m
kube-prometheus-stack-operator                     ClusterRole/kube-prometheus-stack-operator                 49m
kube-prometheus-stack-prometheus                   ClusterRole/kube-prometheus-stack-prometheus               49m
```

### Prometheus ServiceAccount

```
ServiceAccount: kube-prometheus-stack-prometheus
Namespace: monitoring

ClusterRole: kube-prometheus-stack-prometheus
Rules:
  - apiGroups: [""]
    resources: [nodes, nodes/metrics, services, endpoints, pods]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [configmaps]
    verbs: [get]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses]
    verbs: [get, list, watch]
  - nonResourceURLs: [/metrics, /metrics/cadvisor]
    verbs: [get]

Why these permissions:
  nodes/metrics   → kubelet metrics (/metrics/cadvisor)
  services        → service discovery — finds Services to scrape
  endpoints       → resolves Services to pod IPs for scraping
  pods            → PodMonitor pod discovery
  configmaps      → reads PrometheusRule configmaps (rule files)
  ingresses       → optional — for Ingress-based service discovery
```

### Prometheus Operator ServiceAccount

```
ServiceAccount: kube-prometheus-stack-operator
Namespace: monitoring

ClusterRole: kube-prometheus-stack-operator
Rules:
  - apiGroups: [monitoring.coreos.com]
    resources: [all CRDs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [statefulsets, deployments, services, secrets, configmaps]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apps]
    resources: [statefulsets]
    verbs: [get, list, watch, create, update, patch, delete]
  - Admission webhook management

Why these permissions:
  All CRDs:    reads ServiceMonitors, PrometheusRules, etc.
  StatefulSets: creates and manages Prometheus and Alertmanager pods
  Secrets:     writes the generated prometheus.yaml and alertmanager.yaml
  ConfigMaps:  writes rule file ConfigMaps
```

### kube-state-metrics ServiceAccount

```
ServiceAccount: kube-prometheus-stack-kube-state-metrics
Namespace: monitoring

ClusterRole: kube-prometheus-stack-kube-state-metrics
Rules:
  - apiGroups: [""]
    resources: [configmaps, secrets, nodes, pods, services,
                resourcequotas, replicationcontrollers, limitranges,
                persistentvolumeclaims, persistentvolumes, namespaces,
                endpoints]
    verbs: [list, watch]
  - apiGroups: [apps]
    resources: [daemonsets, deployments, replicasets, statefulsets]
    verbs: [list, watch]
  - apiGroups: [batch]
    resources: [cronjobs, jobs]
    verbs: [list, watch]
  ... (more resource types)

Note: kube-state-metrics has broader read access than Prometheus itself.
      It reads more Kubernetes resource types to expose their state.
      It has NO write access to any resource.
```

### Node Exporter — No RBAC Required

Node Exporter reads from the host filesystem (`/proc`, `/sys`) via hostPath
mounts — it does not interact with the Kubernetes API and requires no RBAC.
It runs with `hostPID: true` and `hostNetwork: true` at the pod level.

```bash
# Verify RBAC — no ServiceAccount binding for Node Exporter
kubectl get clusterrolebinding | grep node-exporter
# (should return nothing)
```

---

## 10. Message Flow and Component Interworking

### Full Message Flow — Metric Scrape to Dashboard

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  Application Pod (/metrics endpoint)                                        │
│       │                                                                     │
│       │ ① HTTP GET /metrics every 15s (pull model)                          │
│       │    Prometheus scraper → application pod IP:port                     │
│       ▼                                                                     │
│  Prometheus WAL (Write-Ahead Log)                                           │
│       │                                                                     │
│       │ ② Samples written to WAL for crash safety                           │
│       │    then stored in head block (in-memory)                            │
│       ▼                                                                     │
│  Prometheus TSDB (head block → disk blocks)                                 │
│       │                                                                     │
│       │ ③ Every 15s: rule evaluator runs                                    │
│       │    Recording rules → new metric series stored in TSDB               │
│       │    Alerting rules → if result non-empty, alert fires                │
│       ▼                                                                     │
│  Alertmanager (/api/v2/alerts)                                              │
│       │                                                                     │
│       │ ④ Alertmanager receives fired alert                                 │
│       │    Deduplicates, groups, applies routing tree                       │
│       │    Sends notification to Slack/PagerDuty/email                      │
│       ▼                                                                     │
│  On-call engineer receives Slack/PagerDuty notification                     │
│       │                                                                     │
│       │ ⑤ Engineer opens Grafana                                            │
│       ▼                                                                     │
│  Grafana (/api/ds/query → Prometheus /api/v1/query_range)                   │
│       │                                                                     │
│       │ ⑥ Grafana queries Prometheus via HTTP API                           │
│       │    Prometheus evaluates PromQL against TSDB                         │
│       │    Returns JSON result to Grafana                                   │
│       │    Grafana renders time-series panel                                 │
│       ▼                                                                     │
│  Engineer reads dashboard → investigates → resolves → alert resolves        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### ServiceMonitor to Scrape Config — Operator Message Flow

```
Developer creates ServiceMonitor CRD
       │
       │ ① Kubernetes API server stores the object
       │   Operator's informer receives the watch event
       ▼
Prometheus Operator (reconcile loop)
       │
       │ ② Operator reads ServiceMonitor spec.selector
       │   Queries Kubernetes Endpoints API for matching Services
       │   Gets: [{pod-ip-1:9797}, {pod-ip-2:9797}, {pod-ip-3:9797}]
       ▼
Generate prometheus.yaml scrape_config
       │
       │ ③ Operator writes updated prometheus.yaml to Kubernetes Secret
       │   Secret: prometheus-kube-prometheus-stack-prometheus
       ▼
config-reloader sidecar in Prometheus pod
       │
       │ ④ inotify detects Secret volume change (mounted as file)
       │   POST http://localhost:9090/-/reload
       ▼
Prometheus /-/reload endpoint
       │
       │ ⑤ Prometheus reloads config from disk (no restart)
       │   New scrape targets appear in /targets page within 30 seconds
       │   Pod IPs are current Kubernetes Endpoints — always accurate
       ▼
Prometheus scrapes new targets every 15s
```

### Alert Flow — Prometheus to Engineer

```
Alerting rule evaluates: HighErrorRate
  expr: rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.01
  for: 2m   ← must remain true for 2 full minutes (prevents flapping)
       │
       │ t=0s:   expression true → state: PENDING
       │ t=15s: still true → still PENDING
       │ t=30s: still true → still PENDING
       │ t=45s: still true → still PENDING
       │ t=60s: still true → still PENDING
       │ t=75s: still true → still PENDING
       │ t=90s: still true → still PENDING
       │ t=105s: still true → still PENDING
       │ t=120s: 2 minutes elapsed → state: FIRING
       ▼
Prometheus sends to Alertmanager:
  POST http://alertmanager:9093/api/v2/alerts
  [{labels: {alertname: "HighErrorRate", severity: "warning", namespace: "orders"},
    annotations: {summary: "Error rate above 1%"},
    startsAt: "2025-01-01T12:00:00Z",
    generatorURL: "http://prometheus:9090/graph?g0.expr=..."}]
       │
       ▼
Alertmanager receives alert
  Checks: new alert (not deduplicated)
  Route match: namespace="orders" → receiver: order-team-slack
  group_by: [namespace, alertname] → groups with other orders namespace alerts
  group_wait: 30s → waits 30s before first notification (to batch related alerts)
       │
       ▼
After group_wait (30s):
  Sends Slack message to #order-alerts:
    🔥 [FIRING] HighErrorRate
    Namespace: orders
    Error rate is 3.2%
    [View in Prometheus] [View in Grafana] [Silence]
       │
       ▼
Alert resolves (expression no longer true):
  Prometheus sends endsAt to Alertmanager
  Alertmanager sends Slack: ✅ [RESOLVED] HighErrorRate
```

---

## 11. UI, CLI, and API Endpoints

> **Important — Use Named Services for Port-Forward, Not Headless Services:**
> Two headless Services exist (`prometheus-operated` and `alertmanager-operated`,
> both with `ClusterIP: None`). These are for internal StatefulSet peer discovery
> and Alertmanager gossip — **never use them for kubectl port-forward or UI access**.
> Always use the named ClusterIP services shown below. Using a headless service
> in a port-forward will route to a random pod and behave unpredictably.

### Prometheus UI and API

```bash
# Port-forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Key UI pages
http://localhost:9090/              → Query UI (Graph + Table tabs)
http://localhost:9090/targets       → All scrape targets with status
http://localhost:9090/service-discovery → All discovered endpoints
http://localhost:9090/rules         → All alerting and recording rules
http://localhost:9090/alerts        → Currently firing alerts
http://localhost:9090/status        → Runtime info (version, config, TSDB stats)
http://localhost:9090/tsdb-status   → Cardinality analysis
http://localhost:9090/flags         → All command-line flags
http://localhost:9090/config        → Current prometheus.yaml

# Key API endpoints
GET  /api/v1/query?query=<expr>&time=<ts>              → instant query
GET  /api/v1/query_range?query=<expr>&start=&end=&step= → range query
GET  /api/v1/series?match[]=<selector>                 → list matching series
GET  /api/v1/label/__name__/values                     → all metric names
GET  /api/v1/metadata                                  → metric metadata
POST /-/reload                                         → reload config (no restart)
GET  /-/healthy                                        → health check
GET  /-/ready                                          → readiness check

# Useful CLI via promtool (run inside the Prometheus pod)
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool check config /etc/prometheus/config_out/prometheus.env.yaml

kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool tsdb analyze /prometheus

kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool query instant http://localhost:9090 'up'
```

### Alertmanager UI and API

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

http://localhost:9093/             → Alerts, Silences, Status pages
http://localhost:9093/#/alerts     → Currently active alerts
http://localhost:9093/#/silences   → Active and expired silences

# amtool CLI (run inside the Alertmanager pod)
AMTOOL="kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool"

$AMTOOL --alertmanager.url=http://localhost:9093 alert query
$AMTOOL --alertmanager.url=http://localhost:9093 silence add alertname=~HighCPU \
  --duration=2h --author=you --comment="Maintenance window"
$AMTOOL --alertmanager.url=http://localhost:9093 silence query
$AMTOOL --alertmanager.url=http://localhost:9093 config show
$AMTOOL --alertmanager.url=http://localhost:9093 config routes show
```

### Grafana UI and API

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

http://localhost:3000/                    → Login (admin / observability-demo)
http://localhost:3000/dashboards          → Dashboard browser
http://localhost:3000/explore             → Explore (ad-hoc queries)
http://localhost:3000/alerting            → Unified alerting
http://localhost:3000/connections/datasources → Data sources

# Grafana HTTP API (for automation)
curl -u admin:observability-demo http://localhost:3000/api/datasources
curl -u admin:observability-demo http://localhost:3000/api/dashboards/home
curl -u admin:observability-demo http://localhost:3000/api/health
```

### Node Exporter Metrics Endpoint

```bash
NODE_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus-node-exporter \
  -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n monitoring pod/$NODE_POD 9100:9100

curl http://localhost:9100/metrics | head -100
```

---

## 12. Verifying Stack Health

### Complete Health Check Script

```bash
#!/bin/bash
# Run this to verify the full stack is healthy

echo "=== Pod Status ==="
kubectl get pods -n monitoring

echo ""
echo "=== PVC Status ==="
kubectl get pvc -n monitoring

echo ""
echo "=== Prometheus Targets ==="
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF=$!
sleep 2
UP=$(curl -s http://localhost:9090/api/v1/targets | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len([t for t in d['data']['activeTargets'] if t['health']=='up']))
")
DOWN=$(curl -s http://localhost:9090/api/v1/targets | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len([t for t in d['data']['activeTargets'] if t['health']!='up']))
")
echo "  UP:   $UP targets"
echo "  DOWN: $DOWN targets"
kill $PF 2>/dev/null

echo ""
echo "=== Active Alerts ==="
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
PF=$!
sleep 2
curl -s http://localhost:9093/api/v2/alerts | python3 -c "
import json,sys
alerts=json.load(sys.stdin)
if not alerts: print('  No active alerts')
for a in alerts:
    print(f\"  {a['labels'].get('alertname','?')} [{a['labels'].get('severity','?')}]\")
"
kill $PF 2>/dev/null

echo ""
echo "=== Prometheus TSDB Stats ==="
PROM_POD=$(kubectl get pods -n monitoring \
  -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool tsdb analyze /prometheus 2>/dev/null | head -20

echo ""
echo "=== Config Validation ==="
kubectl exec -n monitoring $PROM_POD -c prometheus -- \
  promtool check config /etc/prometheus/config_out/prometheus.env.yaml
```

### Key Metrics for Monitoring the Stack Itself

```promql
# Is Prometheus healthy?
up{job="kube-prometheus-stack-prometheus"}

# Prometheus config reloads (increasing after each ServiceMonitor change)
prometheus_config_last_reload_success_timestamp_seconds

# Total active time series (cardinality)
prometheus_tsdb_head_series

# Scrape duration — flag slow exporters
scrape_duration_seconds > 5

# Number of failed scrapes (should be 0)
up == 0

# Alertmanager — is it receiving alerts?
alertmanager_alerts_received_total

# Grafana — is it reachable?
up{job="kube-prometheus-stack-grafana"}

# Operator — is it running?
up{job="kube-prometheus-stack-operator"}
```

---

## 13. High Availability — Patterns and Solutions

### The Prometheus HA Problem

Single Prometheus is a single point of failure. But making Prometheus HA
is not straightforward because of how it works:

```
Problem 1: Prometheus stores data locally (TSDB on disk)
  If the node fails, all local data is lost.
  Solution: PVC (survives pod restarts on same node)
            But not node failure. Different node = empty TSDB.

Problem 2: If you run two Prometheus instances, they scrape independently
  Both scrape the same targets.
  Both have slightly different timestamps for the same metric.
  Queries against either return different results.
  You cannot transparently load-balance between them.

Problem 3: Alerting with two Prometheus instances
  Both instances fire the same alert.
  Alertmanager receives duplicate alerts.
  Two notifications for every incident.

Problem 4: Long-term storage
  Local TSDB is limited to one node.
  Retention beyond 30–90 days requires enormous local disk.
  Historical queries get slow as data ages.
```

### Solutions Applied in Production

```
Layer 1: Prometheus HA pairs (short-term, local TSDB)
  Run two identical Prometheus instances with identical scrape configs.
  Both scrape everything. Both evaluate the same rules.
  Use Alertmanager's deduplication to suppress duplicate alerts:
    Two Prometheus → two identical alert fires to Alertmanager
    Alertmanager deduplicates by label fingerprint → one notification ✅
  Problem: queries return different results from each instance.
  Solution: use Thanos Querier or Mimir query frontend
    to fan out queries to both and deduplicate results.

Layer 2: Thanos or Mimir for long-term storage (Demo 22)
  Prometheus remote_write → Mimir (or Thanos Sidecar → object store)
  All data durably stored in S3.
  Mimir provides a Prometheus-compatible query API across all data.
  Grafana queries Mimir instead of Prometheus directly.
  Single pane of glass across all Prometheus instances.

Layer 3: Alertmanager HA cluster
  Run 3 Alertmanager replicas (set replicas: 3 in the Alertmanager CRD).
  Alertmanagers gossip using a mesh protocol (memberlist).
  Silence state and notification dedup state synchronised across all replicas.
  If one Alertmanager fails, the others continue routing without data loss.
```

**HA Alertmanager config in values.yaml:**

```yaml
alertmanager:
  alertmanagerSpec:
    replicas: 3         # 3-node gossip cluster
    # Prometheus sends alerts to ALL three replicas
    # Alertmanager cluster deduplicates across the mesh
```

**HA Prometheus with Mimir remote_write:**

```yaml
prometheus:
  prometheusSpec:
    replicas: 2         # two identical instances
    # Both scrape the same targets — data flows to both local TSDBs
    # Both remote_write to Mimir — Mimir deduplicates at ingest time
    remoteWrite:
      - url: http://mimir-distributor.monitoring:8080/api/v1/push
        headers:
          X-Scope-OrgID: production   # multi-tenancy header
```

---

## 14. Multi-Tenancy and Multi-Cluster

### Multi-Tenancy at Namespace Level (Single Cluster)

```
Pattern: one Prometheus, namespace-scoped scraping

  Platform team owns: Prometheus, Alertmanager, Grafana
  App team A (namespace: orders):
    Creates: ServiceMonitor, PrometheusRule, AlertmanagerConfig
    Prometheus auto-discovers via serviceMonitorSelector
    App team A sees only their metrics via Grafana team/org isolation

  App team B (namespace: payments):
    Same pattern — isolated ServiceMonitors and rules

  Isolation mechanisms:
    RBAC: ServiceMonitor CRD is namespaced — teams can only create in their namespace
    Label selectors: serviceMonitorNamespaceSelector restricts which namespaces
                     Prometheus discovers ServiceMonitors from
    Grafana: teams/orgs provide dashboard-level isolation
    Alertmanager: AlertmanagerConfig CRD is namespaced —
                  teams manage their own routing without touching global config
```

### Multi-Tenancy at Cluster Level (Mimir)

```
Mimir supports true multi-tenancy via the X-Scope-OrgID HTTP header.
Each tenant has completely isolated data — one Mimir for multiple teams.

  Prometheus (cluster A) remote_write:
    X-Scope-OrgID: cluster-a
    → All cluster A data stored under tenant "cluster-a"

  Prometheus (cluster B) remote_write:
    X-Scope-OrgID: cluster-b
    → All cluster B data stored under tenant "cluster-b"

  Grafana queries:
    Data source for team A: X-Scope-OrgID: cluster-a
    Data source for team B: X-Scope-OrgID: cluster-b
    Teams cannot see each other's data
    One Mimir cluster serves all tenants on isolated storage
```

### Multi-Cluster Monitoring

```
Pattern 1: One Prometheus per cluster, all remote_write to central Mimir
  Each cluster has its own kube-prometheus-stack installation.
  Each Prometheus remote_writes to a shared central Mimir.
  Grafana connects to Mimir as the single query backend.
  Cluster label identifies which cluster each metric came from:
    external_labels:
      cluster: production-eu-west-1

Pattern 2: Thanos federation
  Each cluster has Prometheus + Thanos Sidecar.
  Thanos Sidecar uploads TSDB blocks to S3.
  Central Thanos Querier fans out queries to all cluster Thanos Stores.
  More complex than Mimir remote_write — but keeps data close to cluster.

Pattern 3: Agent mode (Prometheus scrapes only, no local TSDB)
  Prometheus in --enable-feature=agent mode.
  Scrapes targets and immediately remote_writes — no local storage.
  Eliminates TSDB storage requirements at cluster level.
  All storage in central Mimir.
  Good for large numbers of clusters where local storage is expensive.
```

---

## 15. Storage Solutions

### Local TSDB (Phase 1 and 2 of this series)

```
Best for: development, learning, clusters up to ~50 nodes
Retention: 10–30 days
Storage:   hostPath or PVC (NFS, EBS, persistent-disk)
Setup:     built into Prometheus — no additional components
Limit:     single node, no HA, limited retention
```

### MinIO (Phase 3 — local S3-compatible storage)

```
What it is:    Open-source, Apache 2.0, S3-compatible object storage
               Runs inside Kubernetes — no external S3 account needed
Use in demos:  Loki backend (Demo 21), Mimir backend (Demo 22)
Production use: On-premise, air-gapped environments, private cloud

Deployment:    helm install minio oci://registry-1.docker.io/bitnamicharts/minio
API:           100% S3-compatible — Loki and Mimir config uses the same keys as AWS S3
               Only the endpoint URL differs:
               http://minio.monitoring:9000 vs s3.amazonaws.com

Backed by:     MinIO Inc — commercial entity with enterprise support
CNCF:          Not a CNCF project but widely adopted in the CNCF ecosystem
```

### AWS S3 (Phase 3 EKS demos)

```yaml
#Loki config:
  storage_config:
    aws:
      s3: s3://ap-southeast-2/my-loki-bucket
      region: ap-southeast-2
  auth_config:
    # Use IRSA (IAM Roles for Service Accounts) — no static credentials
    # Pod's ServiceAccount is bound to an IAM role with S3 permissions

#Mimir config:
  blocks_storage:
    backend: s3
    s3:
      bucket_name: my-mimir-bucket
      region: ap-southeast-2
      # IRSA-based auth — no static keys
```

---

## 16. Release Alignment — Chart vs Component Versions

The kube-prometheus-stack Helm chart bundles multiple components, each with
independent release cycles. The chart maintainers test compatibility before
each chart release.

```
Chart 68.4.4 bundles:
  Prometheus 3.3.1          ← monthly releases by prometheus/prometheus
  Prometheus Operator 0.82.2 ← monthly releases by prometheus-operator org
  Alertmanager 0.28.1       ← quarterly releases by prometheus/alertmanager
  Grafana 11.6.0             ← monthly releases by grafana/grafana
  Node Exporter 1.9.0        ← quarterly releases by prometheus/node_exporter
  kube-state-metrics 2.15.0  ← monthly releases by kubernetes/kube-state-metrics

Release cadence:
  kube-prometheus-stack: multiple releases per month (tracks component releases)
  Prometheus:            monthly minor releases (e.g. 3.3.0 → 3.3.1 → 3.4.0)
  Grafana:               monthly major/minor releases (11.5 → 11.6 → 12.0)
  Alertmanager:          less frequent, every 2–3 months

How to track new releases:
  GitHub:      github.com/prometheus-community/helm-charts/releases
  Subscribe:   Watch → Custom → Releases on the GitHub repo
  ArtifactHub: artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack

Chart version vs App version:
  Chart 68.4.4 — App Version 0.82.2 (this is the Prometheus Operator version)
  The App Version field in Helm tracks the Prometheus Operator version,
  not Prometheus itself. This is a confusing naming choice by the chart maintainers.
  Always check the chart's Chart.yaml to see all bundled component versions.

Upgrade process (production-safe):
  1. Check changelog:
     github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/CHANGELOG.md
  2. Check CRD migrations — some upgrades require CRD updates first
  3. Test in staging with the new chart version
  4. helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
       --version <new-version> --values values.yaml -n monitoring
  5. Verify all pods restart and reach Running state
  6. Verify /targets shows all targets UP
  7. Verify dashboards load in Grafana
```

---

## 17. Official Resources

| Resource | URL |
|---|---|
| kube-prometheus-stack GitHub | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack |
| kube-prometheus-stack CHANGELOG | https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/CHANGELOG.md |
| kube-prometheus-stack ArtifactHub | https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack |
| Prometheus Operator docs | https://prometheus-operator.dev/docs/ |
| Prometheus Operator API reference | https://prometheus-operator.dev/docs/api-reference/api/ |
| Prometheus documentation | https://prometheus.io/docs/prometheus/3.3/ |
| Prometheus data model | https://prometheus.io/docs/concepts/data_model/ |
| Alertmanager documentation | https://prometheus.io/docs/alerting/latest/alertmanager/ |
| Alertmanager config reference | https://prometheus.io/docs/alerting/latest/configuration/ |
| Grafana documentation | https://grafana.com/docs/grafana/latest/ |
| Grafana provisioning | https://grafana.com/docs/grafana/latest/administration/provisioning/ |
| Grafana security advisories | https://github.com/grafana/grafana/security/advisories |
| Node Exporter collectors | https://github.com/prometheus/node_exporter#collectors |
| kube-state-metrics metrics | https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics |
| Prometheus security advisories | https://github.com/prometheus/prometheus/security/advisories |
| Google SRE Book — Monitoring | https://sre.google/sre-book/monitoring-distributed-systems/ |
| Prometheus TSDB internals | https://ganeshvernekar.com/blog/prometheus-tsdb-the-head-block/ |

---

*This guide is a companion to [Demo 01 README](./README.md) and is referenced throughout the demo series.*
*For the full 25-demo roadmap and stack rationale, see the [project root README](../README.md).*