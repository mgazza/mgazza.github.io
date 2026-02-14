---
title: "The Unglamorous Work: Hardening an eBPF BNG for Production"
date: 2026-02-14
draft: false
author: "Mark Gascoyne"
description: "124 issues, 88 PRs, and 81,000 lines changed — the work that separates a prototype from something you'd actually deploy"
tags: ["ebpf", "xdp", "networking", "isp", "distributed-systems", "go", "linux", "testing", "security"]
categories: ["Engineering"]
menu:
  sidebar:
    name: ebpf-bng-production
    identifier: ebpf-bng-production
    weight: 3
---

A month ago I wrote about [building an eBPF-accelerated BNG](/posts/ebpf-bng/) and the [infrastructure repo](/posts/ebpf-bng-infra/) that lets you run it locally. The response was better than I expected — the post hit 94 points on Hacker News and sparked some good discussion.

It also sparked some fair criticism.

One commenter called the code "vibe coded." Another wrote a detailed comment about why distributed BNG has never achieved commercial success, despite attempts by Cisco, Metaswitch, and others. Someone asked about CPU-to-NPU bandwidth in whitebox OLTs. Someone else pointed to 6WIND's commercial DPDK-based BNG as a more production-ready alternative.

All valid. The initial post was a prototype — working, but not something you'd put in front of real subscribers. This post is about what happened next: the unglamorous work that separates a proof of concept from something you'd actually deploy.

## The Numbers

Since the initial release, across three repositories (BNG, Nexus, Infra):

- **124 issues closed**
- **88 pull requests merged**
- **81,000 lines changed**
- **4 releases** (v0.1 → v0.4.0)

Most of that wasn't new features. It was testing, security hardening, failure injection, and fixing the kind of bugs that only appear when you start trying to break things on purpose.

## Test Coverage: The Biggest Gap, Now Filled

The most damning thing about the initial release was the test coverage. You can't call something production-ready when the DHCP server — the core of a BNG — has 29% test coverage.

So we fixed it:

| Package | Before | After | Change |
|---------|--------|-------|--------|
| DHCP | 29.9% | 76.9% | +47pp |
| RADIUS | 23.0% | 87.1% | +64pp |
| NAT | 23.8% | 74.4% | +50pp |
| Subscriber | 86.9% | 100% | +13pp |
| eBPF Loader | 39.3% | 45.6% | +6pp |

That's 3,600+ lines of new test code covering the paths that actually matter: DHCP message handling, RADIUS authentication and accounting, NAT port allocation and hairpinning, CoA processing, rate limiting, and concurrent access patterns.

The eBPF loader is still at 45% — eBPF C code is genuinely hard to unit test. The coverage there comes from the 15 integration test scenarios that exercise the full stack end-to-end rather than mocking the kernel.

### 15 Integration Test Scenarios

The infra repo now ships with 15 test configurations that run in k3d, covering every major BNG function:

```
tilt up e2e              # Full DHCP → BNG → Nexus → allocation flow
tilt up pppoe-test       # PPPoE lifecycle: PADI → PADS → LCP → Auth → IPCP
tilt up nat-test         # NAT44/CGNAT: port blocks, hairpinning, EIM/EIF
tilt up ipv6-test        # SLAAC + DHCPv6 (IA_NA and IA_PD)
tilt up qos-test         # Per-subscriber TC rate limiting
tilt up bgp-test         # BGP session + BFD + route injection
tilt up ha-p2p-test      # Active/standby failover with P2P state sync
tilt up ha-nexus-test    # HA pair with shared Nexus
tilt up failure-test     # Nexus failure, BNG failover, split-brain recovery
tilt up wifi-test        # TTL-based short-lived allocations
tilt up radius-time-test # IP pre-allocation at RADIUS auth time
tilt up peer-pool-test   # Hashring coordination without Nexus
tilt up walled-garden-test # Captive portal for unauth'd subscribers
tilt up blaster-test     # BNG Blaster traffic generation
```

Each one runs a real BNG with real DHCP traffic in a real Kubernetes cluster. Not mocks, not simulations — actual packets flowing through actual eBPF programs. When any of these break, we know about it before a subscriber would.

## Security Hardening

The initial release had basic security — mTLS for Nexus communication, PSK authentication. But "basic" isn't enough when you're handling subscriber traffic. Here's what v0.4.0 added:

### RADIUS Rate Limiting

A BNG without rate limiting on RADIUS is an amplification vector. We added per-server token-bucket rate limiting:

```go
// Default: 1000 req/s sustained, burst of 100
config := RateLimitConfig{
    Rate:  1000,
    Burst: 100,
}
```

Both authentication and accounting requests go through the limiter. If a server is being hammered, requests get cleanly rejected rather than forwarded.

### CAP_BPF Capability Verification

Before v0.4.0, running the BNG without the right Linux capabilities produced a cryptic kernel `EPERM` error. Now it checks upfront:

```
$ ./bng run --interface eth1
Error: eBPF requires CAP_BPF (Linux 5.8+) or CAP_SYS_ADMIN.
Current capabilities: CAP_NET_ADMIN, CAP_NET_RAW
Run with: sudo setcap cap_bpf+ep ./bng
```

Small thing, but it's the difference between a 30-second fix and a 30-minute debugging session.

### Secrets Out of Process Lists

RADIUS shared secrets passed via CLI flags are visible in `ps aux`. New flags read secrets from files instead:

```bash
# Before (secret visible in ps output)
./bng run --radius-secret "my-shared-secret"

# After
echo "my-shared-secret" > /etc/bng/radius-secret
./bng run --radius-secret-file /etc/bng/radius-secret
```

### Other Security Fixes

- **PPPoE password zeroing** — credentials are wiped from memory after authentication completes
- **Option 82 buffer alignment** — fixed buffer size constants to prevent potential overflows
- **Data race fixes** — all shared counters moved to `atomic` operations (caught by `-race` flag in CI)

## New Features That Matter

Not everything was hardening. Some features were needed to make the architecture viable for real deployments.

### BGP Controller Integration

A BNG needs to announce subscriber routes to the upstream network. v0.4.0 wires in a BGP controller with BFD for fast failure detection:

```bash
./bng run \
  --interface eth1 \
  --bgp-enabled \
  --bgp-local-as 65001 \
  --bgp-neighbors "10.0.0.1:65000" \
  --bgp-bfd-enabled
```

When a subscriber session comes up, the route is injected. When it goes down, the route is withdrawn. BFD gives sub-second failure detection — important when you're distributing routing across hundreds of edge sites.

### HA with TLS/mTLS State Sync

The HA implementation from v0.3 worked, but peer state sync was unencrypted. v0.4.0 adds full TLS and mutual TLS for the SSE-based state replication between active/standby BNG pairs. In a deployment where BNG peers might communicate over untrusted networks, this matters.

### Circuit-ID Collision Detection

Circuit-ID is how we identify subscriber ports — but it's hashed to a 32-bit key for eBPF map lookups. Hash collisions are rare but catastrophic (two subscribers sharing an identity). v0.4.0 detects collisions at load time and exports Prometheus metrics:

```
bng_circuit_id_collisions_total    # Total collisions detected
bng_circuit_id_collision_rate      # Current collision rate
```

At 2,000 subscribers per OLT, the collision probability is negligible. But monitoring it means you'll know before it becomes a problem.

### Dynamic Pool Configuration from Nexus

Previously, gateway and DNS settings were hardcoded per BNG instance. Now they're pulled from Nexus pool configuration, so a central change propagates to all edge sites. One less thing to configure per-site.

## What's Still Missing

Honesty about gaps is more useful than pretending they don't exist.

**Real hardware validation.** Everything runs in k3d on simulated interfaces. The architecture is sound, the code is tested, but nobody has run this on an actual OLT with real subscriber traffic yet. That's the next step, and it's the one I can't do alone.

**eBPF fast path coverage.** The Go code is well-tested. The eBPF C programs are validated through integration tests but don't have unit-level coverage. eBPF testing tooling is still immature — there's no good equivalent of `go test` for BPF programs.

**Scale testing under load.** The BNG Blaster tests generate traffic, but we haven't done sustained load testing at 1,500+ concurrent subscribers. The architecture should handle it (eBPF maps scale well), but "should" isn't "proven."

**Operational tooling.** There's Prometheus metrics and a CLI, but no management UI, no alerting templates, no runbooks. The kind of operational tooling that on-call engineers expect.

## The Market Question

The most thoughtful HN comment was about why distributed BNG hasn't succeeded commercially. The barriers aren't technical — they're organisational. ISPs have procurement processes, vendor relationships, regulatory requirements, and staff whose expertise is in existing platforms. You don't displace a Cisco ASR9000 with a GitHub repo.

I don't think that's the target market though. The opportunity is with smaller ISPs, WISPs, and altnets who:

- Can't afford six-figure BNG appliances
- Run on white-box hardware already (MikroTik, Ubiquiti, or bare Linux)
- Have engineering teams comfortable with Linux and containers
- Are building new networks rather than migrating legacy ones

For them, the alternative to this project isn't a Cisco BNG — it's bolting together FreeRADIUS, ISC DHCP, and iptables scripts. An integrated, tested, eBPF-accelerated stack is a genuine improvement over that.

## What Changed, Really

If you read the [original post](/posts/ebpf-bng/) a month ago and thought "interesting prototype, but I wouldn't run it" — that was the right reaction. Here's what's different now:

| Aspect | January (v0.1) | February (v0.4.0) |
|--------|----------------|---------------------|
| Test coverage | Minimal | 76-100% across core packages |
| Security | Basic mTLS | Rate limiting, capability checks, secret management, memory zeroing |
| HA | Not implemented | Active/standby with encrypted state sync |
| Routing | Static | BGP with BFD |
| Test scenarios | 4 demos | 15 integration tests |
| Data races | Present | Fixed (atomic ops, CI race detection) |
| IPv6 | Not implemented | SLAAC + DHCPv6 |
| NAT | Basic | Full CGNAT with hairpinning, EIM/EIF, ALG |
| PPPoE | Basic | Full lifecycle with proper auth |

It's not production-ready in the sense that you can deploy it tomorrow with no risk. But it's production-ready in the sense that the engineering work has been done to make that deployment possible — the testing, the security hardening, the failure handling. What's missing now is validation on real hardware with real traffic.

## Try It

If you're running edge infrastructure and want to test this on real OLT hardware, I want to hear from you. The entire stack runs locally in 15 minutes:

```bash
git clone --recurse-submodules git@github.com:codelaboratoryltd/bng-edge-infra.git
cd bng-edge-infra
./scripts/init.sh
tilt up e2e
```

---

**Links:**
- [bng](https://github.com/codelaboratoryltd/bng) — The eBPF BNG (v0.4.0)
- [nexus](https://github.com/codelaboratoryltd/nexus) — Distributed coordination service (v0.1.0)
- [bng-edge-infra](https://github.com/codelaboratoryltd/bng-edge-infra) — Infrastructure and test harnesses (v0.1.0)
- [Original post: Killing the ISP Appliance](/posts/ebpf-bng/)
- [Infra post: From Zero to eBPF BNG in 15 Minutes](/posts/ebpf-bng-infra/)
- [HN discussion](https://news.ycombinator.com/item?id=46735179)

*If you're an ISP, WISP, or altnet with edge hardware and want to collaborate on real-world testing, reach out. That's the one thing I can't do from a k3d cluster.*
