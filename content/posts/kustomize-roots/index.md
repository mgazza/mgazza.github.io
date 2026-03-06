---
title: "Stop Building Every kustomization.yaml in CI"
date: 2026-03-06
draft: false
author: "Mark Gascoyne"
description: "A graph-based approach to finding which kustomizations actually need building"
tags: ["kustomize", "gitops", "ci", "github-actions"]
categories: ["Engineering"]
menu:
  sidebar:
    name: kustomize-roots
    identifier: kustomize-roots
    weight: 12
---

You have a GitOps repo. It has 35 `kustomization.yaml` files across clusters, components, demos, and tests. You want CI to validate that your manifests actually build. Simple enough — run `kustomize build` on each one and fail the pipeline if anything breaks.

Except it's not that simple.

---

## The Problem

There are three obvious approaches, and they all have problems.

**Build everything.** Walk the repo, find every `kustomization.yaml`, build it. This breaks immediately. Most kustomization files are intermediates — bases and components that aren't designed to build standalone. A base might define a Deployment without a namespace. A component might use patches that only make sense when composed into an overlay. Building these directly gives you cryptic errors: duplicate resources, missing targets, undefined transformers.

**Hardcode a list.** `clusters/prod clusters/staging clusters/local-dev` — put the roots in a variable and build those. This works until someone adds a new cluster, restructures the repo, or forgets to update the list. Stale lists mean new roots silently skip validation. The whole point of CI is catching mistakes automatically.

**Glob the clusters directory.** `for root in clusters/*/; do kustomize build $root; done`. Works for flat repos where every root lives under `clusters/`. Breaks when you have roots elsewhere — test harnesses, monitoring overlays, demo configurations — or when clusters have nested subdirectories.

In a [previous post](/posts/gitops-pr-diffs/) I showed a bash script that walked `resources` and `bases` references to find the "real" roots. It worked, but it was fragile — it didn't handle the `components` field, couldn't distinguish local from remote references, and broke on repos with unusual directory structures.

What you actually need is to find the roots automatically and correctly.

---

## What's a Kustomization Root?

A kustomization root is a `kustomization.yaml` that no other kustomization references. It's a terminal node — the thing you'd actually pass to `kustomize build` or point Flux/Argo at.

Think of the kustomization files as a directed graph. Each file can reference others via `resources`, `components`, or `bases`. A root is a node with in-degree zero: nothing points to it.

In a real repo, most files are intermediates:

```
clusters/local-dev        <-- ROOT (nothing references this)
├── components/demos/standalone
│   └── components/base/bng
├── components/demos/distributed
│   ├── components/base/bng
│   └── components/base/nexus
└── components/monitoring
    ├── charts/prometheus
    └── charts/grafana
```

35 kustomization files. Only a handful are roots. The rest are building blocks.

---

## The Algorithm

Finding roots is a four-step process:

1. **Discover** — walk the directory tree and find every `kustomization.yaml` (also `kustomization.yml` and `Kustomization`). Apply exclusion patterns to skip directories like `.git`, `vendor`, or `src`.

2. **Parse** — read each file and extract its `resources`, `components`, and `bases` lists. Filter out remote references — anything with `://`, `?ref=`, or a `github.com/`/`gitlab.com/` prefix.

3. **Graph** — build a directed graph from the references. For each local reference, resolve the relative path and increment the target's in-degree counter.

4. **Roots** — collect every node with in-degree zero. These are your roots.

The key edge case is remote references. Kustomize supports referencing other repos directly via URL (`github.com/org/repo//path?ref=v1.0`). These aren't local directories and shouldn't affect the graph. A naive implementation that doesn't filter these will either crash on missing paths or incorrectly mark local directories as non-roots.

---

## kustomize-roots

I built [kustomize-roots](https://github.com/mgazza/kustomize-roots) to do exactly this. It's ~500 lines of Go with a single external dependency (`gopkg.in/yaml.v3`).

### Install

```bash
go install github.com/mgazza/kustomize-roots@latest
```

### CLI

```bash
# List roots
$ kustomize-roots /path/to/repo
clusters/local-dev
clusters/staging
clusters/production

# Build each root (validates they render cleanly)
$ kustomize-roots -build /path/to/repo

# JSON output for scripting
$ kustomize-roots -json /path/to/repo

# Debug: show the reference graph
$ kustomize-roots -verbose /path/to/repo
```

The `-build` flag runs `kustomize build` on each discovered root, falling back to `kubectl kustomize` if kustomize isn't installed. The `-output-dir` flag writes rendered manifests to files — useful if you want to archive or diff them.

### GitHub Action

For CI, there's a GitHub Action that wraps the CLI:

```yaml
name: Kustomize Validate

on:
  push:
    branches: [main]
    paths: ['clusters/**', 'components/**', 'charts/**']
  pull_request:
    branches: [main]
    paths: ['clusters/**', 'components/**', 'charts/**']

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate kustomize roots
        uses: mgazza/kustomize-roots@v1
        with:
          build: "true"
          exclude: ".git src scripts docs tests"
```

No hardcoded paths. No stale lists. Add a new cluster directory and CI picks it up automatically.

---

## Combining with PR Diffs

In the [PR diffs post](/posts/gitops-pr-diffs/), I showed how to generate manifest diffs at review time instead of deployment time. The weak point was finding which kustomizations to build — I used a bash script that was one edge case away from breaking.

kustomize-roots with `-build` replaces that entire script. It discovers the roots *and* builds them in one step. The bash script from that post — find kustomizations, walk references, figure out what's a root, build each one — is exactly what `kustomize-roots -build` does, minus the fragility.

For the full PR diff workflow — rendering manifests on both branches and diffing the output — the `-output-dir` flag writes each root's rendered manifests to individual files, which you can then diff between branches. See the [PR diffs post](/posts/gitops-pr-diffs/) for the complete pattern.

---

## Conclusion

If you're running `kustomize build` in CI, you need to know which files to build. Hardcoded lists rot. Globs are fragile. Building everything fails on intermediates.

The answer is a graph walk: discover all kustomization files, trace their references, find the ones nothing points to. That's what kustomize-roots does.

---

**Links:**
- [kustomize-roots](https://github.com/mgazza/kustomize-roots) — The tool
- [Practical GitOps Pattern](/posts/gitops/) — Repository structure
- [GitOps PR Diffs](/posts/gitops-pr-diffs/) — Manifest diffs at PR time
