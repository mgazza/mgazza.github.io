---
title: "Killing the ISP Appliance: An eBPF/XDP Approach to Distributed BNG"
date: 2026-01-16
draft: false
author: "Mark Gascoyne"
description: "An open-source, eBPF-accelerated BNG that runs directly on OLT hardware - eliminating expensive centralised appliances"
tags: ["ebpf", "xdp", "networking", "isp", "distributed-systems", "go", "linux"]
categories: ["Engineering"]
menu:
  sidebar:
    name: ebpf-bng
    identifier: ebpf-bng
    weight: 5
---

I used to work for an ISP startup that was building next-generation infrastructure. The company didn't make it, but the problems we were trying to solve stuck with me. So I spent a few weeks building what we never got to: an open-source, eBPF-accelerated BNG that runs directly on OLT hardware.

This post explains the architecture and why I think it's the future of ISP edge infrastructure.

## The Problem: Centralised BNG is a Bottleneck

Traditional ISP architecture looks like this:

```
Customer → ONT → OLT → [BNG Appliance] → Internet
                            ↑
               Single point of failure
               Expensive proprietary hardware
               All subscriber traffic flows through here
```

Every subscriber's traffic - DHCP, authentication, NAT, QoS - flows through a central BNG appliance. These boxes cost six figures, require vendor support contracts, and create a single point of failure. When they go down, everyone goes down.

The industry's answer has been to buy bigger boxes with more redundancy. But what if we flipped the model entirely?

## The Idea: Distribute the BNG to the Edge

What if, instead of funneling all traffic through a central appliance, we ran BNG functions directly on the OLT hardware at each edge site?

```
Customer → ONT → OLT(+BNG) → Internet
                    ↑
       Subscriber traffic stays LOCAL
       No central bottleneck
       Each site operates independently
```

This isn't a new idea - it's essentially what hyperscalers do with their edge infrastructure. But ISPs have been slow to adopt it because:

1. Traditional BNG software assumes a central deployment
2. State management (IP allocations, sessions) is hard to distribute
3. Performance requirements seemed to need specialised hardware

The key insight is that modern Linux with eBPF/XDP can handle ISP-scale packet processing on commodity hardware.

## Why eBPF/XDP, Not VPP?

When I started this project, I evaluated two approaches:

**VPP (Vector Packet Processing)** - The industry darling for high-performance networking. Used in production by big telcos. Handles 100+ Gbps easily.

**eBPF/XDP** - Linux kernel's programmable packet processing. Lower peak throughput, but much simpler operations.

For edge deployment (10-40 Gbps per OLT), I chose eBPF/XDP:

| Aspect | eBPF/XDP | VPP |
|--------|----------|-----|
| Performance | 10-40 Gbps ✓ | 100+ Gbps (overkill) |
| Deployment | Standard Linux kernel | DPDK, hugepages, dedicated NICs |
| Operations | systemd service | Complex dedicated setup |
| Debugging | tcpdump, bpftool, perf | Custom tools |
| Learning curve | Steep but well-documented | Very steep, less documentation |

VPP is the right choice for core aggregation. But for edge sites? eBPF/XDP is simpler and sufficient.

## The Architecture

Here's what I built:

```
┌─────────────────────────────────────────────────────────────┐
│  CENTRAL (Kubernetes)                                        │
│  Nexus: CRDT state sync, hashring IP allocation             │
│  (Control plane only - NO subscriber traffic)               │
└──────────────────────────┬──────────────────────────────────┘
                           │ Config sync, metrics
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
   ┌───────────┐     ┌───────────┐     ┌───────────┐
   │ OLT-BNG 1 │     │ OLT-BNG 2 │     │ OLT-BNG N │
   │ eBPF/XDP  │     │ eBPF/XDP  │     │ eBPF/XDP  │
   │ 1500 subs │     │ 2000 subs │     │ 1800 subs │
   └─────┬─────┘     └─────┬─────┘     └─────┬─────┘
         │                 │                 │
    Traffic LOCAL     Traffic LOCAL     Traffic LOCAL
         ↓                 ↓                 ↓
       ISP PE           ISP PE           ISP PE
```

**Key principle**: Subscriber traffic never touches central infrastructure. The central Nexus server only handles control plane operations - config distribution, IP allocation coordination, monitoring.

### Two-Tier DHCP: Fast Path + Slow Path

The performance-critical insight is that most DHCP operations are renewals from known subscribers. We can handle these entirely in the kernel:

```
DHCP Request arrives
        │
        ▼
┌───────────────────────────────────────────────────────┐
│               XDP Fast Path (Kernel)                   │
│                                                        │
│  1. Parse Ethernet → IP → UDP → DHCP                  │
│  2. Extract client MAC                                 │
│  3. Lookup MAC in eBPF subscriber_pools map           │
│                                                        │
│  CACHE HIT?                                           │
│  ├─ YES: Generate DHCP ACK in kernel                  │
│  │       Return XDP_TX (~10μs latency)                │
│  └─ NO:  Return XDP_PASS → userspace                  │
└───────────────────────────────────────────────────────┘
        │ XDP_PASS (cache miss)
        ▼
┌───────────────────────────────────────────────────────┐
│            Go Slow Path (Userspace)                    │
│                                                        │
│  1. Lookup subscriber in Nexus cache                  │
│  2. Get pre-allocated IP from subscriber record       │
│  3. Update eBPF cache for future fast path hits       │
│  4. Send DHCP response                                │
└───────────────────────────────────────────────────────┘
```

**Results**:
- Fast path: ~10μs latency, 45,000+ requests/sec
- Slow path: ~10ms latency, 5,000 requests/sec
- Cache hit rate after warmup: >95%

### IP Allocation: Hashring at RADIUS Time

Here's a design decision that simplified everything: **IP allocation happens at RADIUS authentication time, not DHCP time.**

```
1. Subscriber authenticates via RADIUS
2. RADIUS success → Nexus allocates IP from hashring (deterministic)
3. IP stored in subscriber record
4. DHCP is just a READ operation (lookup pre-allocated IP)
```

This means:
- No IP conflicts between distributed BNG nodes
- DHCP fast path can run entirely in eBPF (no userspace allocation decisions)
- Subscribers get the same IP every time (hashring determinism)

### Offline-First Edge Operation

What happens when an edge site loses connectivity to central Nexus?

**Keeps working:**
- Existing subscriber sessions (cached in eBPF maps)
- DHCP lease renewals
- NAT translations
- QoS enforcement

**Degraded:**
- New subscriber authentication (no RADIUS)
- New IP allocations (falls back to local pool)
- Config updates (queued until reconnect)

The edge sites are designed to be autonomous. Central coordination is nice to have, not required.

## The Implementation

The BNG is a single Go binary with embedded eBPF programs:

```
bng/
├── cmd/bng/              # Main binary
├── pkg/
│   ├── ebpf/             # eBPF loader and map management
│   ├── dhcp/             # DHCP slow path server
│   ├── nexus/            # Central coordination client
│   ├── radius/           # RADIUS client
│   ├── qos/              # QoS/rate limiting
│   ├── nat/              # NAT44/CGNAT
│   ├── pppoe/            # PPPoE server
│   ├── routing/          # BGP/FRR integration
│   └── metrics/          # Prometheus metrics
├── bpf/
│   ├── dhcp_fastpath.c   # XDP DHCP fast path
│   ├── qos_ratelimit.c   # TC QoS eBPF
│   ├── nat44.c           # TC NAT eBPF
│   └── antispoof.c       # TC anti-spoofing
```

Running it:

```bash
# Standalone mode (local IP pool)
sudo ./bng run \
  --interface eth1 \
  --pool-network 10.0.1.0/24 \
  --pool-gateway 10.0.1.1

# Production mode (with Nexus coordination)
sudo ./bng run \
  --interface eth1 \
  --nexus-url http://nexus.internal:9000 \
  --radius-enabled \
  --radius-servers radius.isp.com:1812
```

## Hardware: White-Box OLTs

This runs on any Linux box with a modern kernel (5.10+), but the target is white-box OLTs like the Radisys RLT-1600G:

- 16 GPON/XGS-PON ports
- Runs Debian Linux
- ~$7,400 USD (vs six figures for traditional BNG)
- 1,500-2,000 subscribers per unit

The same approach works with any OLT that runs Linux and exposes its network interfaces to the OS.

## What's Next

The code is working but not production-ready. Missing pieces:

1. **Device authentication** - TPM attestation or similar to prevent rogue OLT-BNG devices
2. **IPv6 support** - DHCPv6 and SLAAC
3. **Full RADIUS accounting** - Currently basic
4. **Management UI** - Currently CLI and Prometheus metrics only

I'm considering open-sourcing the entire thing. The BNG market is dominated by expensive proprietary solutions, and there's no good open-source alternative. Maybe there should be.

## The Bigger Picture

Traditional ISP infrastructure was designed when compute was expensive and networks were slow. Centralised appliances made sense when you needed specialised hardware for packet processing.

But compute is cheap now, and eBPF lets us do packet processing in the Linux kernel at line rate. The economics have shifted - it's now cheaper to distribute the BNG to hundreds of edge sites than to build a few massive central boxes.

This isn't just about saving money. Distributed architecture is more resilient (no single point of failure), lower latency (traffic stays local), and operationally simpler (it's just Linux).

The hyperscalers figured this out years ago. ISPs are slowly catching up.

---

**Interested in this approach?** The code is at [github.com/codelaboratoryltd/bng](https://github.com/codelaboratoryltd/bng) and [github.com/codelaboratoryltd/nexus](https://github.com/codelaboratoryltd/nexus). I'd love to hear from anyone working on similar problems in the ISP/altnet space.

*If you're building ISP infrastructure and want to chat about eBPF, distributed systems, or why vendor BNG appliances are a racket, reach out.*
