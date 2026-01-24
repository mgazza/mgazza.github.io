---
title: "From Zero to eBPF BNG in 15 Minutes: The GitOps Deployment Repo"
date: 2026-01-24
draft: false
author: "Mark Gascoyne"
description: "The infrastructure repo that lets you run a complete eBPF-accelerated BNG stack locally with one command"
tags: ["ebpf", "gitops", "kubernetes", "tilt", "k3d", "isp", "networking"]
categories: ["Engineering"]
menu:
  sidebar:
    name: ebpf-bng-infra
    identifier: ebpf-bng-infra
    weight: 4
---

Last week I [open-sourced the eBPF BNG](/posts/ebpf-bng/) itself. The response was great, but the most common question was: *"How do I actually run this thing?"*

Fair question. The BNG repo has a Dockerfile and some example configs, but spinning up a distributed system with multiple components, observability, and realistic test traffic isn't trivial. That's the hard part of infrastructure - not writing the code, but figuring out how to deploy it, test it, and debug it when things break.

So this week I'm open-sourcing the infrastructure repo: **bng-edge-infra**. One command gets you a complete eBPF BNG stack running locally.

## The Problem: "Works On My Machine" Doesn't Scale

When I was building the BNG, I spent more time on deployment tooling than I'd like to admit. The challenges:

1. **Multiple components with dependencies** - BNG needs Nexus for IP allocation. Nexus nodes need to discover each other. Everything needs networking configured correctly.

2. **No hardware to test on** - Real OLTs cost thousands. You can't ask contributors to buy one to test a PR.

3. **Distributed systems are hard to debug** - When a DHCP request fails, is it the eBPF program? The userspace fallback? Nexus? Network policy? You need visibility.

4. **The "getting started" cliff** - Vendor docs assume you already understand the system. They show you config snippets, not working examples.

The solution: a GitOps repo that codifies everything - from cluster creation to traffic testing - in a reproducible, one-command experience.

## What's In The Repo

```
bng-edge-infra/
├── clusters/
│   ├── local-dev/       # k3d cluster config
│   ├── staging/         # Staging Flux manifests
│   └── production/      # Production Flux manifests
├── components/
│   ├── bng/             # BNG Kubernetes manifests
│   ├── nexus/           # Nexus Kubernetes manifests
│   └── bngblaster/      # Traffic generator
├── charts/              # Generated Helm templates
├── scripts/
│   ├── helmfile.yaml    # Infrastructure definitions
│   └── hydrate.sh       # Manifest generation
├── src/
│   ├── bng/             # SUBMODULE: BNG source
│   └── nexus/           # SUBMODULE: Nexus source
└── Tiltfile             # The magic
```

The key insight is treating the *entire deployment experience* as code. Not just the Kubernetes manifests, but the cluster creation, the Helm chart hydration, the port forwarding, and the test harnesses.

## Four Demo Configurations

The repo ships with four progressively complex deployment modes. Each one teaches you something different about the architecture:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Demo A: Standalone BNG                                             │
│  ┌─────────┐                                                        │
│  │   BNG   │  ← Single BNG, local IP pool, no external deps        │
│  └─────────┘                                                        │
│  Good for: Understanding BNG internals, eBPF debugging              │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  Demo B: Single Integration                                         │
│  ┌─────────┐      ┌─────────┐                                       │
│  │  Nexus  │ ←──→ │   BNG   │  ← BNG gets IPs from Nexus           │
│  └─────────┘      └─────────┘                                       │
│  Good for: Testing the integration, API exploration                 │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  Demo C: Nexus P2P Cluster                                          │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐                            │
│  │ Nexus-0 │ ↔ │ Nexus-1 │ ↔ │ Nexus-2 │  ← CRDT sync via mDNS     │
│  └─────────┘   └─────────┘   └─────────┘                            │
│  Good for: Testing distributed state, partition tolerance           │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  Demo D: Full Distributed                                           │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐                            │
│  │ Nexus-0 │ ↔ │ Nexus-1 │ ↔ │ Nexus-2 │                            │
│  └────┬────┘   └────┬────┘   └────┬────┘                            │
│       │             │             │                                  │
│       └──────┬──────┴──────┬──────┘                                  │
│              ▼             ▼                                         │
│         ┌─────────┐   ┌─────────┐                                    │
│         │  BNG-0  │   │  BNG-1  │  ← Multiple BNGs, shared state    │
│         └─────────┘   └─────────┘                                    │
│  Good for: Production-like testing, HA validation                   │
└─────────────────────────────────────────────────────────────────────┘
```

You can run any specific demo or all of them at once:

```bash
tilt up                  # All demos
tilt up -- --demo=a      # Just standalone BNG
tilt up -- --demo=d      # Just full distributed
```

## The One-Command Experience

### Prerequisites

You need Docker and about 8GB of RAM. Then install the tools:

**macOS:**
```bash
brew install k3d kubectl tilt-dev/tap/tilt helmfile helm
```

**Linux:**
```bash
# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# tilt
curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash

# helm + helmfile
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# helmfile from GitHub releases or brew
```

### Clone and Run

```bash
git clone --recurse-submodules git@github.com:codelaboratoryltd/bng-edge-infra.git
cd bng-edge-infra
tilt up
```

That's it. Go make a coffee.

### What Happens Under The Hood

When you run `tilt up`, here's what happens:

1. **k3d cluster creation** - A local Kubernetes cluster named `bng-edge` spins up with Flannel disabled (we'll use Cilium instead).

2. **Helmfile hydration** - Infrastructure charts (Cilium, Prometheus, Grafana) are templated and applied.

3. **Docker builds** - BNG and Nexus images are built from the submodules with live reload enabled.

4. **Namespace creation** - Each demo gets its own namespace (`demo-standalone`, `demo-single`, `demo-p2p`, `demo-distributed`).

5. **Workload deployment** - Deployments and StatefulSets are created with appropriate configurations.

6. **Port forwarding** - Services are exposed to localhost automatically.

After a few minutes, you'll have:

| Service | URL |
|---------|-----|
| Tilt UI | http://localhost:10350 |
| BNG API (Demo A) | http://localhost:8080 |
| Nexus API (Demo B) | http://localhost:9001 |
| BNG API (Demo D) | http://localhost:8083 |
| Hubble UI | http://localhost:12000 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 |

## Testing Without Real Hardware

One of the biggest challenges with BNG development is that you normally need real subscriber hardware to generate DHCP/PPPoE traffic. We solve this with built-in test harnesses.

### Verification Buttons

Each demo has a "verify" button in the Tilt UI. Click it to run a quick health check:

- **Demo A**: Queries the BNG sessions API
- **Demo B**: Creates a pool in Nexus, allocates an IP, verifies the integration
- **Demo C**: Creates a pool on Nexus-0, waits for CRDT sync, verifies it appears on Nexus-1
- **Demo D**: Full integration test across the distributed cluster

### BNG Blaster

For serious traffic testing, we include [BNG Blaster](https://github.com/rtbrick/bngblaster) - an open-source traffic generator designed for BNG testing:

```bash
tilt up -- --demo=blaster
```

This gives you pre-configured test scenarios:
- IPoE session establishment
- PPPoE session establishment
- DHCP stress testing

### Realistic DHCP Testing

For quick DHCP validation without BNG Blaster's complexity, there's a lightweight test harness:

```bash
tilt up -- --demo=blaster-test
```

This spins up a BNG with a sidecar container that can generate real DHCP traffic over a veth pair. The Tilt UI has buttons for:

- **Single DHCP request** - One udhcpc request to verify basic functionality
- **Stress test** - 10 virtual clients requesting IPs concurrently
- **Check sessions** - Query the BNG API to see allocated sessions

Example output from the stress test:

```
=== Multi-Client DHCP Stress Test ===
Creating 10 virtual clients...
Running DHCP requests...
  Client 1: 10.100.0.2/24
  Client 2: 10.100.0.3/24
  Client 3: 10.100.0.4/24
  ...
=== Results ===
Successful: 10 / 10
Failed:     0
Duration:   3s
Rate:       3 sessions/sec
```

## Observability Built In

Debugging distributed systems without observability is misery. The repo comes with a full stack pre-configured.

### Cilium + Hubble

We use Cilium as the CNI instead of the default Flannel. This gives us:

- **eBPF-based networking** - Fitting, given the BNG itself uses eBPF
- **Network policies** - If you want to test isolation
- **Hubble** - Real-time network flow visibility

The Hubble UI (http://localhost:12000) shows you every packet flowing through the cluster. When a DHCP request fails, you can see exactly where it got dropped.

```bash
# Or use the CLI
hubble observe --namespace demo-distributed
hubble observe --protocol udp --port 67  # DHCP traffic only
```

### Prometheus + Grafana

Both BNG and Nexus export Prometheus metrics. The repo includes:

- Pre-configured scrape configs
- Basic dashboards for BNG session counts, DHCP latency, Nexus allocation rates

Grafana is available at http://localhost:3000 (admin/admin).

### Why This Matters

When you're debugging "DHCP isn't working", the question is always *where* in the stack it's failing:

1. Is the packet reaching the BNG pod? → Hubble
2. Is the eBPF fast path matching? → BNG metrics (`dhcp_fastpath_hits`)
3. Is the slow path timing out on Nexus? → Nexus metrics + traces
4. Is the response getting back to the client? → Hubble again

Having all of this in one place, with one command, makes the difference between debugging for hours and debugging for minutes.

## Taking It To Production

The local-dev setup is designed for experimentation, but the repo structure supports real deployments.

### Staging and Production Clusters

The `clusters/staging/` and `clusters/production/` directories are set up for FluxCD:

```
clusters/
├── local-dev/
│   └── k3d-config.yaml
├── staging/
│   ├── flux-system/      # Flux bootstrap
│   ├── infrastructure/   # Cilium, monitoring
│   └── apps/             # BNG, Nexus
└── production/
    ├── flux-system/
    ├── infrastructure/
    └── apps/
```

Point Flux at the appropriate directory, and it'll keep your cluster in sync with Git. The same manifests that work locally work in production - that's the point of GitOps.

### Extending For Your Deployment

The demo configurations are intentionally simple. For a real deployment, you'd add:

1. **RADIUS integration** - The BNG supports FreeRADIUS. Add your RADIUS server config.
2. **Real IP pools** - Replace the `10.x.x.x` demo pools with your actual allocations.
3. **TLS everywhere** - The demos use HTTP for simplicity. Production should use mTLS.
4. **Persistent storage** - Nexus supports persistent state. Configure a StorageClass.
5. **Network interfaces** - The demos use standard CNI networking. Real OLTs need interface configuration for subscriber-facing ports.

## The Bigger Picture

This repo represents a philosophy: **infrastructure should be runnable by anyone**.

Too often, infrastructure projects assume you'll figure out deployment yourself. They give you a binary and some config flags and wish you luck. That's fine for simple tools, but distributed systems are different. The deployment *is* the product.

By open-sourcing not just the BNG code but the entire deployment experience, we're saying: this is how we think it should work. Clone it, run it, break it, improve it.

If you're building ISP infrastructure, evaluating the architecture, or just curious about GitOps patterns for edge systems - this is your starting point.

---

**Try it:**

```bash
git clone --recurse-submodules git@github.com:codelaboratoryltd/bng-edge-infra.git
cd bng-edge-infra
tilt up
```

**Links:**
- [bng-edge-infra](https://github.com/codelaboratoryltd/bng-edge-infra) - This repo
- [bng](https://github.com/codelaboratoryltd/bng) - The eBPF BNG itself
- [nexus](https://github.com/codelaboratoryltd/nexus) - Distributed coordination service

*Questions? Feedback? Found a bug? Open an issue or reach out.*
