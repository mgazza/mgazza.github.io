---
title: "GitOps PR Diffs: Review What You Deploy"
date: 2025-01-14T10:00:00Z
description: "Generate Kubernetes manifest diffs at PR time, not deployment time"
menu:
  sidebar:
    name: gitops-pr-diffs
    identifier: gitops-pr-diffs
    weight: 11
---

**Introduction**
A common pattern I see promoted is using tools that show you what will change in your cluster *at sync time* - after your code is already merged. In my view, this is already too late and goes against GitOps principles. How can Git be the source of truth if there are extra steps between merge and understanding impact?

In this post, I'll show you how to generate manifest diffs *during PR review*, so reviewers see exactly what will change in the cluster before they approve.

---

## **The Problem**

Consider the typical Argo CD diff plugin workflow:

1. Developer creates PR
2. Reviewer approves (without seeing cluster impact)
3. Code merges
4. **Now** you see the diff of what will change
5. Sync happens

The diff comes too late. The reviewer has already approved. If something looks wrong, you need another PR to fix it.

**GitOps should mean**: what's in Git *is* what's in the cluster. Reviewers should understand the full impact before approving.

---

## **The Solution**

Generate diffs at PR time by:

1. Building manifests from the **main branch**
2. Building manifests from the **PR branch**
3. Diffing the two
4. Posting the result as an artifact or comment

This way, reviewers see the actual Kubernetes resources that will change - deployments, services, configmaps, everything.

---

## **Key Principle: Absorb Your Helm Charts**

Before we can diff manifests, we need actual manifests to diff. If you're deploying Helm charts directly via `helm install`, you don't have rendered manifests in Git.

**Instead, absorb them:**

```bash
helm template my-release my-chart \
  --namespace my-namespace \
  > components/my-service/manifests.yaml
```

Or better, use **Helmfile** to declaratively manage this:

```yaml
# helmfile.yaml - keep charts vanilla, use inline values only
releases:
  - name: prometheus
    namespace: monitoring
    chart: prometheus-community/prometheus
    version: 25.0.0
    # Minimal inline values - external values files don't work with template
```

Then render to disk:

```bash
helmfile template > components/monitoring/prometheus.yaml
```

**Important**: Keep absorbed charts as vanilla as possible. Don't try to configure everything via Helm values. Instead, push customisation to Kustomize overlays where changes are visible and diffable:

```yaml
# groups/monitoring/kustomization.yaml
resources:
  - ../../components/monitoring/prometheus.yaml
patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 3
    target:
      kind: Deployment
      name: prometheus-server
```

This separation means:
- **Components**: Vanilla absorbed charts (rarely change)
- **Groups/Clusters**: Environment-specific patches (visible in diffs)

---

## **Building and Diffing**

The core CI logic is straightforward:

```bash
# Build manifests from main branch
git checkout origin/main
kustomize build clusters/prod > /tmp/main-manifests.yaml

# Build manifests from PR branch
git checkout $PR_BRANCH
kustomize build clusters/prod > /tmp/pr-manifests.yaml

# Generate diff
diff -u /tmp/main-manifests.yaml /tmp/pr-manifests.yaml > diff.txt
```

For multiple clusters or kustomization roots, iterate:

```bash
for root in clusters/*/; do
  cluster=$(basename $root)
  kustomize build $root > /tmp/main-$cluster.yaml
  # ... diff each
done
```

---

## **GitLab CI Example**

```yaml
generate-diffs:
  rules:
    - if: $CI_MERGE_REQUEST_IID
      changes:
        - deployments/**/*
  script: |
    # Fetch main branch
    git fetch origin main

    # Build main branch manifests
    git checkout origin/main
    for root in clusters/*/; do
      cluster=$(basename $root)
      kustomize build $root > /tmp/main-$cluster.yaml
    done

    # Build PR branch manifests
    git checkout $CI_COMMIT_SHA
    for root in clusters/*/; do
      cluster=$(basename $root)
      kustomize build $root > /tmp/pr-$cluster.yaml
      diff -u /tmp/main-$cluster.yaml /tmp/pr-$cluster.yaml > diffs/$cluster.diff || true
    done
  artifacts:
    paths:
      - diffs/
    when: always
```

---

## **GitHub Actions Example**

```yaml
name: Generate Manifest Diffs

on:
  pull_request:
    paths:
      - 'clusters/**'
      - 'components/**'
      - 'groups/**'

jobs:
  diff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Kustomize
        uses: imranismail/setup-kustomize@v2

      - name: Generate diffs
        run: |
          mkdir -p diffs

          for root in clusters/*/; do
            cluster=$(basename $root)

            # Build from main
            git checkout origin/main
            kustomize build $root > /tmp/main-$cluster.yaml 2>/dev/null || echo "" > /tmp/main-$cluster.yaml

            # Build from PR
            git checkout ${{ github.sha }}
            kustomize build $root > /tmp/pr-$cluster.yaml

            # Diff
            diff -u /tmp/main-$cluster.yaml /tmp/pr-$cluster.yaml > diffs/$cluster.diff || true
          done

      - name: Upload diffs
        uses: actions/upload-artifact@v4
        with:
          name: manifest-diffs
          path: diffs/

      - name: Comment on PR
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const diffs = fs.readdirSync('diffs');
            let comment = '## Manifest Diffs\n\n';

            for (const file of diffs) {
              const content = fs.readFileSync(`diffs/${file}`, 'utf8');
              if (content.trim()) {
                comment += `<details><summary>${file}</summary>\n\n\`\`\`diff\n${content}\n\`\`\`\n</details>\n\n`;
              }
            }

            github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: comment
            });
```

---

## **Handling Multiple Layers**

In more complex setups, you might have:

- Multiple clusters (prod, staging, dev)
- Flux Kustomizations that reference different paths
- Wave-based rollouts for multi-tenant systems

The approach scales: **diff each root that changed**.

```bash
# Detect which roots changed
changed_roots=$(git diff --name-only origin/main | grep "^clusters/" | cut -d'/' -f1-2 | sort -u)

for root in $changed_roots; do
  # Build and diff only affected roots
done
```

For Flux-managed clusters, you can even generate diffs per Flux Kustomization by parsing the `spec.path` from each Kustomization resource.

---

## **Making It Visual**

Plain diffs work, but an HTML visualization makes review easier:

- Tree view of changed files/resources
- Side-by-side comparison
- Kubernetes metadata (kind, namespace, name)
- Collapsible sections for large changes

You can build this with Go templates, React, or even a simple script that wraps `diff2html`.

---

## **Key Benefits**

1. **No Surprises**: Reviewers see exactly what will change before approving
2. **Git Is Truth**: The merged state *is* the deployed state - no extra steps
3. **Faster Reviews**: Clear diffs mean faster, more confident approvals
4. **Catch Mistakes Early**: Spot accidental changes (wrong image tag, missing resource limits) before they hit the cluster
5. **Audit Trail**: Diffs become part of the PR history

---

## **Conclusion**

Showing diffs at deployment time is too late. By the time you see the impact, the code is already merged. True GitOps means understanding the full impact *during review*.

The pattern is simple:

1. **Absorb** Helm charts into your repo as vanilla rendered manifests
2. **Kustomize** via Kustomize overlays (not Helm values)
3. **Build** kustomize roots for both branches
4. **Diff** and present to reviewers
5. **Review** with full knowledge of cluster impact

This approach has saved me countless "oops" moments and makes PR reviews genuinely meaningful for infrastructure changes.

---

**Further Reading**

* [Practical GitOps Pattern](/posts/gitops/) - Repository structure and workflow
* [Kustomize](https://kustomize.io/)
* [Helmfile](https://github.com/helmfile/helmfile)
* [diff2html](https://diff2html.xyz/) - For visual diff rendering
