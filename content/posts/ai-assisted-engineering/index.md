---
title: "AI Didn't Design This BNG. Experience Did."
date: 2026-02-14
draft: false
author: "Mark Gascoyne"
description: "On the difference between vibe coding and using AI tools with a decade of domain expertise, real specifications, and proper engineering discipline"
tags: ["ebpf", "ai", "software-engineering", "networking", "isp", "distributed-systems"]
categories: ["Engineering"]
menu:
  sidebar:
    name: ai-assisted-engineering
    identifier: ai-assisted-engineering
    weight: 2
---

When I [open-sourced the eBPF BNG](/posts/ebpf-bng/) last month, someone on Hacker News called it "vibe coded."

I understand why. The project moved fast — a working distributed BNG with eBPF/XDP packet processing, DHCP, RADIUS, NAT, PPPoE, BGP, and a coordination service, all open-sourced within weeks. That's suspicious. When something appears quickly, people assume it was thrown together quickly.

But speed of implementation isn't the same as absence of design. And using AI tools to write code isn't the same as letting AI design your system.

## The Backstory

I used to work for an ISP startup called [Vitrifi](https://www.ispreview.co.uk/index.php/2025/12/vitrifi-calls-in-the-administrators-over-uk-wholesale-platform-for-full-fibre-altnets.html). We were building next-generation broadband infrastructure — the platform layer that sits between physical fibre networks and the services running on them. I spent years there working on the problems that a distributed BNG needs to solve: subscriber management, IP allocation, DHCP at scale, RADIUS integration, QoS enforcement, edge deployment models.

Vitrifi went into administration in December 2025. The company didn't make it, but the problems we were working on didn't go away. Neither did the specifications I'd written, the architecture decisions I'd argued about, or the understanding of why certain approaches work and others don't at ISP scale.

I can't use any of Vitrifi's code. But I can use what I learned.

When I sat down to build the open-source BNG, I wasn't starting from a blank prompt. I had years of specifications, architecture diagrams, failure mode analyses, and hard-won opinions about how subscriber traffic should flow through an edge network. The system design existed before a single line of code was written.

## What Vibe Coding Actually Is

Andrej Karpathy coined the term in early 2025. His definition is specific: you describe what you want to a language model, accept what it generates, and keep prompting until it works. You "forget that the code even exists." You don't review diffs. You don't understand the implementation. You work around bugs rather than fixing them.

Simon Willison drew a useful line: "I won't commit any code to my repository if I couldn't explain exactly what it does to somebody else."

That's the distinction. It's not about whether AI was involved in writing the code. It's about whether a human with relevant expertise is directing the architecture, reviewing the output, and taking responsibility for the result.

## What We Actually Did

Here's what the development process for the BNG looked like in practice:

**1. Specification first, code second.**

Every major component started as a design document. How should IP allocation work across distributed BNG nodes? What happens during a network partition? What's the failure mode when a Nexus coordinator goes down? How do you prevent circuit-ID hash collisions in eBPF maps?

These aren't questions an LLM can answer. They come from watching real ISP infrastructure break in production and understanding why.

The two-tier DHCP design — eBPF fast path for renewals, Go slow path for cache misses — came from understanding that 95%+ of DHCP traffic in a real network is renewals from known subscribers. The decision to allocate IPs at RADIUS authentication time rather than DHCP time came from years of dealing with IP conflict bugs in distributed systems. The offline-first edge design came from working with rural ISPs where backhaul connectivity is unreliable.

None of that is something you'd arrive at by prompting.

**2. Architecture drives implementation, not the other way around.**

The system has a clear architecture: central coordination (Nexus) handles only control plane, subscriber traffic stays local at the edge (BNG), state is synchronised via CRDTs, resource allocation uses consistent hashing. This architecture was designed before implementation began — drawn on whiteboards, argued about, refined based on real-world constraints.

AI tools helped implement that architecture faster. They didn't choose it. When an LLM generates a DHCP server, it'll give you a straightforward single-node implementation. It won't give you a two-tier kernel/userspace split with eBPF map-backed caching and deterministic IP pre-allocation via a hashring. That design comes from domain expertise.

**3. Every line of code is reviewed and understood.**

I can explain what every function in this codebase does, why it exists, and what the alternative approaches were. The eBPF programs are hand-specified — you don't prompt your way to correct XDP packet processing. The Go code uses AI assistance for implementation speed, but every function gets reviewed, tested, and often rewritten.

When the AI generates a RADIUS client, I know whether the authenticator calculation is correct because I've implemented RADIUS before. When it generates NAT44 logic, I know whether the port allocation strategy will scale because I've seen the failure modes. The AI accelerates the typing. The engineering judgment is human.

**4. Testing is not optional.**

The v0.4.0 release includes 3,600+ lines of test code, taking DHCP coverage from 29% to 77%, RADIUS from 23% to 87%, NAT from 24% to 74%. There are 15 integration test scenarios that run real traffic through real eBPF programs in a real Kubernetes cluster.

Vibe coding doesn't produce this. Vibe coding produces something that works for the demo. Engineering produces something that works when the demo breaks.

## The 4GL Analogy

The reaction to AI-assisted development reminds me of every previous abstraction shift in programming.

When developers moved from assembly to C, purists said you couldn't trust a compiler to generate correct machine code. When we moved from C to higher-level languages, people worried about performance and control. When ORMs replaced hand-written SQL, the same arguments appeared.

Each time, the abstraction layer handled more of the implementation detail. Each time, the domain expertise of the engineer became *more* important, not less. Nobody argues that using Python instead of assembly makes you less of an engineer. The value moved upstream — from knowing how to write instructions to knowing which instructions to write.

AI-assisted development is the same pattern. The implementation is increasingly automated. The specification, architecture, testing, and domain knowledge remain human. If anything, they matter more now, because the bottleneck has moved from "can we write it fast enough" to "do we know what to write."

The difference between a junior developer prompting ChatGPT and a domain expert using AI tools is the same difference there's always been between someone who can write code and someone who knows what code to write.

## The Real Risk Isn't AI Tooling

The Hacker News commenter who called this "vibe coded" was pointing at a real concern, just the wrong one. The real risk in infrastructure software isn't whether AI was involved in writing it. It's whether the people building it understand the domain.

I've seen beautifully hand-crafted ISP infrastructure that fell over in production because the developer had never worked with real subscriber traffic. I've seen quick-and-dirty scripts hold up for years because the person who wrote them understood exactly what failure modes mattered.

The question to ask about any infrastructure project isn't "was this written with AI?" It's:

- Does the architecture reflect real operational experience?
- Are the failure modes understood and handled?
- Is there adequate test coverage for the paths that matter?
- Can the maintainers explain why it works, not just that it works?

For this project, the answer to all four is yes. Not because we avoided AI tools, but because we used them within a framework of domain expertise, specifications, and engineering discipline.

## What This Means For Open Source Infrastructure

There's an uncomfortable truth in the Hacker News thread about commercial viability: traditional ISPs won't adopt this. They have procurement processes, vendor relationships, and support contracts. They need 100% feature parity with their existing Cisco or Juniper BNG before they'll even evaluate an alternative.

But there's a growing market of smaller ISPs, WISPs, and altnets who are building on Linux and open-source tooling already. For them, the alternative to this project isn't a six-figure vendor appliance — it's stitching together FreeRADIUS, ISC DHCP, and iptables scripts. An integrated, tested stack built by someone who's spent years working on exactly this problem is a genuine step up.

The fact that AI tools accelerated the implementation is a feature, not a bug. It means a small team (or even a single engineer) can build infrastructure that previously required a funded startup with 56 employees. That's the real shift — not replacing engineering judgment, but making it economically viable for smaller players to compete.

Vitrifi burned through £16 million and didn't ship. This project cost nothing and is running. The difference isn't the tools — it's that the specifications already existed in my head before the first line was written.

---

**Links:**
- [Killing the ISP Appliance: An eBPF/XDP Approach to Distributed BNG](/posts/ebpf-bng/)
- [The Unglamorous Work: Hardening an eBPF BNG for Production](/posts/ebpf-bng-production/)
- [bng](https://github.com/codelaboratoryltd/bng) — The eBPF BNG
- [nexus](https://github.com/codelaboratoryltd/nexus) — Distributed coordination service
- [HN discussion](https://news.ycombinator.com/item?id=46735179)
- [Simon Willison: Not all AI-assisted programming is vibe coding](https://simonwillison.net/2025/Mar/19/vibe-coding/)

*The BNG project is open source and looking for collaborators — particularly ISPs with edge hardware interested in real-world testing. Reach out if that's you.*
