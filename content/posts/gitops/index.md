---
title: "Practical GitOps Pattern"
date: 2025-02-25T19:02:12Z
description: "A Practical GitOps Pattern for Kubernetes: Hierarchical Folders, Helm, and Kustomize"
menu:
  sidebar:
    name: gitops
    identifier: gitops
    weight: 10
---


**Introduction**  
If you’ve spent any time working with Kubernetes, you’ve probably heard of *GitOps* -a methodology that treats Git as the source of truth for defining and operating infrastructure and applications. In this post, I’ll walk you through a GitOps setup that uses a hierarchical folder structure, combining Helm, Helmfile, and Kustomize to give you robust, testable, and scalable deployments. We’ll also see how tools like Flux and Tilt fit into the workflow, enabling both automated deployments and seamless local development.

---

## **Why GitOps?**

Before we dive into the specifics, let’s revisit what GitOps brings to the table:

* **Version Control**: Every change to your Kubernetes configurations is committed to Git, providing an audit trail and easy rollbacks.
* **Single Source of Truth**: Teams can rely on the repo as the canonical description of what’s running in each cluster.
* **Automation**: Changes in Git trigger updates to your clusters, reducing manual operations and ensuring consistency.

This post assumes you’re already sold on GitOps and are looking for a tangible organizational pattern. Let’s jump in.

---

## **The Repository Structure**

Our GitOps repository is divided into **four main folders** -plus a special `src` directory for source code and a `Tiltfile` for local dev. Here’s a quick overview:

```
.
├── helm-charts  
├── components  
├── groups 
├── clusters
├── src
└── Tiltfile
```

### **1\. Helm Charts**

* **Purpose**: This directory stores all Helm charts -whether first-party or third-party dependencies -that form the foundation of your Kubernetes services.
* **Workflow**:
   1. **Render**: Helm charts are templated to disk.
   2. **Include in Kustomize**: You use Kustomize to ingest those templates.
   3. **Manage with Helmfile**: Helmfile can orchestrate multiple Helm releases, ensuring everything is installed/updated consistently.

This approach decouples the raw Helm charts from the environment-specific overlays, making it easier to plug them into different clusters in a standardized way.

### **2\. Components**

* **Purpose**: Store Kubernetes manifests that are *not* part of Helm charts.
   * This could include CRDs (Custom Resource Definitions), operator manifests, or any other resources you want to keep separate.
* **Usage**: Directly reference these components in your cluster definitions or in a higher-level grouping concept (more on that next).

### **3\. Groups**

* **Purpose**: Group related services and configurations together under a single overlay.
   * For example, a `monitoring` group might include Prometheus, Grafana, and other supporting components.
* **Hierarchy**:
   * Groups can reference other groups, enabling layering.
   * A `dev` group might inherit from a `default` group, adding environment-specific patches for development clusters (e.g., less resource allocation, debug logging).

### **4\. Clusters**

* **Purpose**: Each cluster folder describes exactly *what* should be running on that cluster, pulling in components and groups as needed.
* **Structure**:
   * Each cluster has its own folder, which Flux (or another GitOps tool like Argo CD) monitors.
   * Subfolders often map to namespaces or functional areas.
   * Environment-specific customizations, such as image overrides or domain-specific settings, also live here.
* **Benefits**: This design ensures that each cluster references only the resources it needs, with any environment-specific overrides captured in a single place.

### **5\. `src` (Git Submodules)**

* **Purpose**: Each application or service your team develops has its own dedicated repo, added to this GitOps repo as a submodule.
* **Motivation**: Separating source code lifecycles from infrastructure while still keeping them in close proximity.
   * Each service can evolve at its own pace (with separate versioning and pull requests).
   * When you’re ready to deploy, you update references in the GitOps repo to point to the correct version or commit.

### **6\. Tilt for Local Development**

* **Tiltfile**: A single `Tiltfile` at the root of your GitOps repo configures local Kubernetes development using [Tilt](https://tilt.dev/) and [k3d](https://k3d.io/).
* **Realtime Feedback**:
   1. Tilt builds Docker images locally as you code and pushes them into your `k3d` cluster.
   2. You can check out feature branches across multiple submodules and test them all together in a local environment.
* **Developer Happiness**: This local dev approach drastically shortens the feedback loop, letting you iterate faster than if you had to push and wait for a remote pipeline to run.

---

## **CI/CD Flow**

Now that we’ve broken down the structure, let’s see how changes flow from a developer’s pull request to a cluster.

### **1\. Pull Request → Image Build**

* **Trigger**: A developer creates or updates a pull request in the `src` project repository.
* **Automation**: A CI pipeline (e.g., GitHub Actions, Jenkins, GitLab CI) builds a Docker image for the new code.

### **2\. CI Environment Setup in Dev Cluster**

* The pipeline references the GitOps repo (specifically the **Dev cluster folder**).
* A **CI folder** under that Dev cluster is used to stand up a temporary environment for tests.
   * This CI folder typically isn’t referenced by the main Dev cluster overlay, so it doesn’t affect production-like resources.
* The pipeline applies a Kustomization overlay that includes the new Docker image (and possibly “latest” versions of other services).

### **3\. Readiness & Integration Tests**

1. **Wait for Ready**: The pipeline checks that all pods in the CI environment reach a “Ready” state.
2. **Integration Tests**:
   * Another folder within the CI path (e.g., `integration-test`) includes job manifests that run your test suite.
   * The pipeline applies these manifests, waits for the jobs to complete, then collects logs/results.

### **4\. Cleanup**

* Once tests finish, the pipeline tears down the temporary namespace to keep clusters clean.
* If tests pass, the pipeline can merge the pull request or notify that the new image is ready for promotion.

---

## **Key Benefits**

1. **Modular & Extensible**: By separating Helm charts, components, groups, and clusters, you can easily add new resources or reuse existing ones.
2. **Consistent Environments**: Groups let you define and share sets of configurations across multiple stages (e.g., dev, staging, prod).
3. **Automated Testing**: The CI process ensures each new feature or fix is validated in an ephemeral environment, mirroring production as closely as you need.
4. **Local Development**: Tilt and k3d let you replicate the cluster environment on your machine, enabling quicker feedback loops and more productive debugging.
5. **Auditability & Traceability**: Since every change is committed to Git, you get a clear history of who changed what and when.

---

## **The Single Pane of Glass**

Beyond the technical benefits, this pattern fundamentally changes how teams collaborate.

**One entry point, any role.** Whether you're a backend engineer, frontend dev, SRE, or even a PM wanting to understand the system - you clone one repo and run `tilt up`. Within minutes you have a working `https://localhost.company.co/` with the entire stack running locally.

**Cross-functional debugging.** I've watched frontend engineers fix backend bugs by running `grep -r "error message"` from the repo root. The pseudo mono-repo structure means the answer is always *somewhere* in your checkout - you just need to find it.

**No onboarding tax.** Switching teams doesn't mean spending a week setting up a new development environment. The same `tilt up` command works whether you're on payments, auth, or the data pipeline.

**Declarative infrastructure as documentation.** New joiners can understand the entire system topology by reading the `clusters/` and `groups/` directories. The infrastructure *is* the documentation.

---

## **Conclusion**

Adopting GitOps with a well-thought-out repository structure can dramatically simplify your Kubernetes workflows. By combining Helm, Helmfile, Kustomize, and tools like Flux or Argo CD, you can create modular, scalable, and testable deployments. And with a local development pipeline powered by Tilt and k3d, you can iterate quickly without sacrificing best practices.

If you’re looking for a GitOps pattern that balances clarity, flexibility, and collaboration, give this structure a try. You’ll enjoy:

* Fewer manual steps.
* A predictable CI process.
* An environment that’s friendly for both new and experienced team members.

**Ready to dive deeper?** Experiment with a small cluster or side project first. Once you’re comfortable with the structure, scale it up to your full production workloads. Happy deploying\!

---

**Further Reading**

* [Flux CD](https://fluxcd.io/)
* [Helm](https://helm.sh/)
* [Kustomize](https://kustomize.io/)
* [Tilt](https://tilt.dev/)
* [k3d Docs](https://k3d.io/)
