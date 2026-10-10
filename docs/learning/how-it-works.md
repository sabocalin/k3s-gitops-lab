# How the whole project works, in plain terms

This guide explains the entire lab from the ground up, for someone who has never seen it.
It doesn't assume you know Kubernetes, AWS or GitOps. Each section explains one layer in
everyday words, then gives the technical detail. At the end of each section, links point
to the learning notes that have the full reasoning, the alternatives and the proof.

If you only read one part, read [the short version](#the-short-version) and
[one change, start to finish](#one-change-start-to-finish).

## Contents
1. [The short version](#the-short-version)
2. [Words you'll meet](#words-youll-meet)
3. [The big picture](#the-big-picture)
4. [The machine: AWS and Terraform](#1-the-machine-aws-and-terraform)
5. [Getting in without open doors: Tailscale](#2-getting-in-without-open-doors-tailscale)
6. [From a blank server to a cluster: first boot, Ansible, K3s](#3-from-a-blank-server-to-a-cluster)
7. [The app and its container image](#4-the-app-and-its-container-image)
8. [Running the app on Kubernetes](#5-running-the-app-on-kubernetes)
9. [Reaching the app from the internet: DNS, Traefik, HTTPS](#6-reaching-the-app-from-the-internet)
10. [Two ways to deploy: push and pull](#7-two-ways-to-deploy-push-and-pull)
11. [Argo CD runs the platform too](#8-argo-cd-runs-the-platform-too)
12. [Secrets: where every secret lives](#9-secrets-where-every-secret-lives)
13. [Watching it: metrics, logs, alerts](#10-watching-it-metrics-logs-and-an-alert)
14. [Keeping it alive and cheap](#11-keeping-it-alive-and-cheap)
15. [Guardrails on the repository](#12-guardrails-on-the-repository)
16. [One change, start to finish](#one-change-start-to-finish)
17. [What happens when something goes wrong](#what-happens-when-something-goes-wrong)
18. [Where to go next](#where-to-go-next)

---

## The short version

The lab is **one small server in AWS** that runs **Kubernetes** (a system that keeps
programs running and restarts them when they fail). On it runs a **small web app**
(Python, FastAPI) that answers at **https://k3s-gitops-lab.duckdns.org**.

Everything about it is written down as code in this repository: the server, its network,
its configuration, the app, how the app is deployed, the monitoring and the alerts.
Nobody logs in to set anything up by hand. To prove it, **the server is destroyed and
rebuilt from this repository every Sunday**, and it comes back the same.

The app is deployed in **two different ways at once**, to compare them:
- **push:** when code is merged, GitHub's automation logs in to the cluster and installs
  the new version;
- **pull (GitOps):** a program inside the cluster (Argo CD) keeps watching this
  repository and makes the cluster match it.

The whole thing costs **about $3 a month**, because the server is stopped whenever it
isn't being used.

---

## Words you'll meet

| Word | Plain meaning |
|---|---|
| **AWS** | Amazon's cloud. We rent one virtual server (an **EC2 instance**) there, in Frankfurt (`eu-central-1`). |
| **Terraform** | A tool that creates cloud resources from text files. You describe "one server, this size, this network", and it makes reality match. |
| **Ansible** | A tool that configures a server from text files: "this file exists, this program is installed, this service runs". |
| **Container / image** | An **image** is a packaged program with everything it needs. A **container** is a running copy of it. |
| **Kubernetes (K8s)** | Software that runs containers and keeps them in the state you asked for: "keep 3 copies running" means a crashed copy gets replaced. |
| **K3s** | A small, single-binary Kubernetes, made for small machines like ours. |
| **Pod** | Kubernetes' smallest unit: one or more containers that run together. Our app runs as 3–5 pods. |
| **Namespace** | A folder inside the cluster. Our app runs twice, in namespaces `push` and `gitops`. |
| **Manifest** | A YAML file that describes a Kubernetes object ("a Deployment with 3 pods of this image"). |
| **Kustomize** | Builds the final manifests from a shared base plus small per-environment changes. |
| **GitOps** | "Git is the source of truth": a program in the cluster keeps the cluster equal to what git says. |
| **Argo CD** | The GitOps program we use. |
| **CI/CD, GitHub Actions** | Automation that runs on GitHub when code changes: tests, image builds, deploys. A run of a **workflow** is made of **jobs**. |
| **OIDC** | A way for one system to prove who it is to another with a short-lived signed token, instead of a stored password. |
| **Tailscale** | A private network (a "tailnet") between our own devices, encrypted, that works through firewalls. |
| **SSM Parameter Store** | AWS's free store for small values, including encrypted secrets. |
| **Digest** | The unique fingerprint of an image (`sha256:…`). Unlike a name tag, it can never point to different content. |

---

## The big picture

```
                          the internet
                               │  ports 80 and 443 only
                               ▼
          k3s-gitops-lab.duckdns.org  ──▶  AWS EC2 server (t4g.medium, 4 GiB, arm64)
                                            running K3s (Kubernetes)
                                             │
             ┌───────────────────────────────┼─────────────────────────────────┐
             │ Traefik (front door, HTTPS)   │ Argo CD (watches git)           │
             │   └▶ app, namespace push      │   └▶ app, namespace gitops      │
             │ cert-manager (certificates)   │ External Secrets (reads AWS)    │
             │ Alloy (ships metrics/logs)    │ system-upgrade (K3s upgrades)   │
             └───────────────────────────────┴─────────────────────────────────┘

you (laptop)    ──Tailscale──▶ SSH and the Kubernetes API (closed to the internet)
GitHub Actions  ──OIDC──────▶ AWS (no stored keys)
GitHub Actions  ──Tailscale─▶ Kubernetes API (push deploys)
Argo CD         ──polls─────▶ this GitHub repository (pull deploys)
Alloy           ────────────▶ Grafana Cloud (dashboards, an email alert)
```

Diagrams: [infrastructure](../architecture/k3s-gitops-lab-architecture.png) and
[push vs pull delivery](../architecture/k3s-gitops-lab-delivery.png).

The repository is laid out by layer:

| Folder | What's in it |
|---|---|
| `terraform/` | the cloud resources, in four separate "stacks" |
| `ansible/` | how the server is configured (swap, K3s, DNS updater) |
| `app/` | the web app, its tests and its Dockerfile |
| `k8s/` | every Kubernetes manifest: the app, its namespaces, the platform components |
| `scripts/` | the shell scripts behind `make` and the workflows |
| `.github/workflows/` | the GitHub Actions automation |
| `docs/learning/` | one note per task: what, why, how, and the proof |

---

## 1. The machine: AWS and Terraform

**In plain terms:** Terraform files describe the server and everything around it.
Running Terraform makes AWS match the files. The parts that cost nothing and never
change are kept apart from the server itself, so destroying the server can't touch them.

### Four stacks, four lifetimes
A **stack** is a folder of Terraform files with its own memory of what it created (its
**state**). The state files of all four stacks live in an S3 bucket (S3 is AWS's file
storage), encrypted, versioned and locked so two runs can't collide.

| Stack | Contains | Lifetime |
|---|---|---|
| `terraform/bootstrap` | the state bucket, a $5/month budget alert, AWS contact addresses, the roles GitHub Actions may use | permanent; only ever applied from the laptop |
| `terraform/platform` | the private network (VPC), its firewall rules, the server's permissions (IAM roles) | permanent, and free |
| `terraform/instance` | the server itself, and its nightly stop schedule | stopped when idle, destroyed and rebuilt weekly |
| `terraform/grafana` | the alert rule and its email contact in Grafana Cloud | permanent |

Why separate: if the server were in the same stack as the network, one wrong
`terraform destroy` could delete the network too. With separate stacks, the instance
stack doesn't even know the network exists.

### The network
- A **VPC** (a private network in AWS), `10.42.0.0/16`, with public subnets and an
  internet gateway. There's no NAT gateway or load balancer: they cost $16–$33 a month
  each, and K3s's built-in parts do the same job here.
- A **security group** (AWS's firewall) lets in **only ports 80 and 443** (web traffic).
  Port 22 (SSH) and 6443 (the Kubernetes API) are **closed to the internet**: admin
  access goes over Tailscale (section 2).

### The server
- `t4g.medium`: 2 ARM CPUs, 4 GiB of memory, Ubuntu 24.04, a 12 GB encrypted disk.
  (It started as a 2 GiB `t4g.small`; adding Argo CD needed more memory, #40 and #47.)
- **No SSH key exists.** Nobody has a key to log in with the classic way.
- **IMDSv2 only, hop limit 1.** The server asks AWS's metadata service (at
  `169.254.169.254`) for its temporary credentials. Requiring a session token first blocks
  a well-known attack where a web app is tricked into fetching that address. The hop limit
  means containers on the server can't reach it.
- **CPU credits "standard":** if the CPU is busy for long, AWS slows it down instead of
  sending a bill.
- The server has a **role** (`k3s-gitops-lab-node`) that can read only a few specific
  secrets from SSM, nothing else.

### Safety catches
- Every stack refuses to run against any AWS account but the lab's
  (`allowed_account_ids`). The laptop's default AWS profile belongs to an employer, so
  this check makes a wrong-profile mistake harmless. The `Makefile` also forces
  `AWS_PROFILE=personal`.
- The state bucket can't be deleted by `terraform destroy` (`prevent_destroy`), and
  refuses plain HTTP.
- The budget emails at 80% of $5 actually spent, or when the forecast for the month passes $5.

Read more: [8](8-terraform-bootstrap.md), [9](9-platform-stack.md),
[10](10-instance-and-security-group.md), [12](12-node-iam-and-secret.md),
[5 (cost model)](5-readme-cost-model.md).

---

## 2. Getting in without open doors: Tailscale

**In plain terms:** instead of opening SSH and the Kubernetes API to the whole internet,
the server, the laptop and GitHub's automation join a private, encrypted network
(Tailscale). Only members can see those ports. On the internet, the ports simply don't
answer.

### How the server joins
At first boot, the server reads a **Tailscale OAuth client secret** from SSM and uses it
to join the tailnet as `k3s-node`, tagged `tag:k3s`. A tagged device belongs to the tag,
not to a person, so its key never expires. The name `k3s-node.taild18d72.ts.net` only
resolves inside the tailnet.

### How the laptop gets in
- The laptop runs Tailscale in **userspace mode**: no admin rights, no system VPN, no
  route changes, so it can't interfere with the work VPN.
- **SSH:** `ssh k3s-node` goes through Tailscale SSH, which checks your Tailscale
  identity instead of an SSH key.
- **kubectl:** the Kubernetes config file (`~/.kube/k3s-gitops-lab.yaml`) sends traffic
  through Tailscale's local SOCKS5 proxy (`localhost:1055`) to `k3s-node…:6443`.

### Who may reach what
The tailnet has a written policy, with built-in tests that refuse a bad edit:

| Who | May reach |
|---|---|
| you and your own devices | everything on the node |
| `tag:ci` (GitHub Actions deploy jobs) | the node's Kubernetes API, **port 6443 only**; never 22 (SSH) or 10250 (kubelet) |

Read more: [13](13-tailscale-on-boot.md), [14](14-ansible-k3s.md),
[15](15-kubeconfig-over-tailscale.md).

---

## 3. From a blank server to a cluster

**In plain terms:** when a new server starts for the first time, it runs a script that
turns it into the lab node by itself: it gets its old identity back, joins the private
network, downloads this repository and configures itself. No human logs in.

### First boot, step by step
The script is `terraform/instance/user_data.sh.tftpl`. AWS runs it once, on first boot.

1. **Install the AWS CLI.**
2. **Restore the node's identity** from SSM (`/k3s-gitops-lab/node-identity/…`, 16
   encrypted files). These are the cluster's certificate authorities, its service-account
   signing keys, Tailscale's device state and the SSH host keys. Because they're restored
   **before** K3s and Tailscale start for the first time, a brand-new server looks exactly
   like the old one:
   - same Tailscale device and IP, so nothing that points at `k3s-node` breaks;
   - same cluster CA, so your existing kubeconfig and CI's trusted certificate still work;
   - same SSH host key, so there's no "REMOTE HOST IDENTIFICATION HAS CHANGED" warning.
3. **Start Tailscale.** With the restored state it reconnects as the same device. If that
   fails, it enrolls fresh with the OAuth secret.
4. **Clone this repository's `main` branch** and run `scripts/node-bootstrap.sh`.

### `node-bootstrap.sh`
1. Installs a pinned Ansible version in its own Python environment.
2. Runs `ansible/site.yml` **locally on the node**, which has three roles:
   - **swap:** a 1 GB swap file, a cushion for memory spikes;
   - **k3s:** downloads the pinned K3s release (`v1.37.1+k3s1`), checks its checksum,
     writes its config (certificate names, secrets encryption at rest, the pod and service
     address ranges `10.52.0.0/16` and `10.53.0.0/16`, chosen not to overlap the VPC)
     and starts it;
   - **ddns:** installs the service that updates the public DNS name at every boot
     (section 6).
3. Waits for Kubernetes to answer, then installs Argo CD and hands over: from here on,
   Argo CD installs everything else from git (section 8).

The same Ansible playbook can run from the laptop over Tailscale SSH (`make up` on an
existing node).

### Why K3s
Full Kubernetes needs several machines and services. K3s is one binary that includes the
pieces a small cluster needs: a container runtime (containerd), an ingress controller
(Traefik), a small load balancer (ServiceLB), DNS (CoreDNS), metrics-server and a network
policy engine. That's why the lab needs no paid AWS load balancer.

Read more: [14](14-ansible-k3s.md), [90](90-cluster-network-ranges.md),
[64](64-weekly-rebuild.md).

---

## 4. The app and its container image

**In plain terms:** the app is a tiny web service whose real job is to be a well-behaved
citizen of the cluster: it says when it's alive, when it's ready, and how busy it is.
Every version is packaged, scanned for known vulnerabilities, signed, and stored with a
list of what's inside.

### The app (`app/`, Python, FastAPI)
| Address | Answers | Who asks |
|---|---|---|
| `/health` | "the process is alive": always 200 once serving | Kubernetes' liveness probe; restarts the pod if it fails |
| `/ready` | "I can take traffic": 503 while starting and while shutting down | Kubernetes' readiness probe; takes the pod out of rotation, no restart |
| `/metrics` | request counts and timings, in Prometheus format | Alloy, for Grafana Cloud |
| `/` | the version (git commit) and which pod answered | humans |

Tests: `make test` runs ruff (lint and format) and pytest.

### The image (`app/Dockerfile`)
- **Two stages.** The first installs the exact locked dependencies, checking every file's
  hash. The final image is **distroless**: Python and nothing else, no shell, no package
  manager. It's 27.9 MB.
- It runs as user **65532**, not root, and needs no writable disk.
- Every base image is pinned by **digest**.

### The image pipeline (`.github/workflows/image.yml`)
On every merge that changes the app, a GitHub-hosted **ARM** machine (the same CPU type
as the server):
1. **builds** the image;
2. **scans** it with Trivy: fails on any HIGH or CRITICAL vulnerability that has a fix;
3. **smoke-tests** it from outside: `/health` 200, `/ready` goes from 503 to 200, it runs
   as 65532, there's no shell;
4. **pushes** it to GitHub's registry as `ghcr.io/sabocalin/k3s-gitops-lab/lab-api:<commit>`
   (there's no `latest` tag);
5. **attests** it: a signed record of which workflow and commit built it (provenance) and
   a signed list of every package inside (SBOM);
6. **signs** it with cosign, "keyless": no signing key exists anywhere. GitHub vouches for
   the workflow's identity, Sigstore issues a certificate valid for minutes, and the
   signature is recorded in a public log.

`scripts/verify-image.sh` accepts an image only if it's signed by **this repository's
image workflow on `main`**. Both deploy paths run it before deploying.

Read more: [19](19-fastapi-scaffold.md), [20](20-dockerfile.md), [21](21-app-ci.md),
[22](22-image-build.md), [23](23-image-scan.md), [24](24-attestations.md),
[25](25-cosign-signing.md).

---

## 5. Running the app on Kubernetes

**In plain terms:** the manifests in `k8s/` tell Kubernetes how to run the app safely:
how many copies, how to update without downtime, how much memory each may use, what it
may talk to, and what happens when it misbehaves.

### How the manifests are organised (Kustomize)
```
k8s/base/                the app itself: Deployment, Service, PodDisruptionBudget, HPA
k8s/components/lab-api-image/   the image digest, shared by both deploy paths
k8s/overlays/push/       base + namespace push + Ingress (public address) + HTTPS redirect
k8s/overlays/gitops/     base + namespace gitops (no public address)

k8s/namespace-base/      the guardrails every app namespace gets
k8s/namespaces/push/     Namespace push + guardrails + the deployer's permissions
k8s/namespaces/gitops/   Namespace gitops + guardrails
```
The split is about **who owns what**. The `namespaces/` part (limits, quotas, network
rules, permissions) is applied by an admin. The `overlays/` part (the app) is applied by
the deployer. A deployer therefore can't loosen its own guardrails.

### What each setting does
| Setting | Value | What it means |
|---|---|---|
| Replicas (HPA) | 3 to 5 | the autoscaler adds pods when average CPU passes 70% of the request, removes them after 5 calm minutes |
| Rolling update | `maxUnavailable 0`, `maxSurge 1` | a new pod must be ready before an old one goes; measured 0 failed requests out of 1181 during a rollout |
| `preStop` sleep 5 s | | a pod being removed keeps answering for 5 s while traffic moves away |
| Probes | startup, liveness, readiness | startup waits up to 60 s; liveness restarts a stuck pod; readiness removes a pod from traffic without restarting it |
| Resources | requests 50m CPU / 64Mi, limits 250m / 128Mi | over 128Mi the pod is killed; over 250m it's slowed |
| LimitRange, ResourceQuota | per namespace | defaults for anything that declares nothing; a total budget for the namespace |
| PodDisruptionBudget | at least 2 ready | a voluntary eviction (a drain) is refused if it would leave fewer than 2 |
| Security context | non-root, read-only disk, no capabilities, seccomp, no API token | and the namespace enforces Pod Security **restricted**, so a pod that isn't hardened like this is rejected |
| NetworkPolicy | default deny, plus three exceptions | nothing may talk to the app except Traefik (the front door) and Alloy (to read `/metrics`); Traefik may also reach cert-manager's short-lived challenge pod |

### The render check: `make k8s`
`scripts/render-k8s.sh` builds every manifest with a pinned Kustomize and **refuses**
anything that breaks the rules above: an image without a digest, a container without
limits, a missing PDB or quota, a guardrail placed in the deployer's part, an Ingress
without HTTPS, and more. It runs on every pull request (check `k8s-render`) and before
every push deploy.

Read more: [27](27-kustomize-layout.md), [28](28-rollout.md), [29](29-probes.md),
[30](30-resources.md), [31](31-security-context.md), [32](32-pod-disruption-budget.md),
[33](33-network-policy.md), [34](34-hpa.md), [38](38-deployer-rbac.md).

---

## 6. Reaching the app from the internet

**In plain terms:** the server gets a new public IP every time it starts, so a free
dynamic DNS name follows it. A front-door program (Traefik) receives the web traffic and
passes it to a healthy copy of the app. Another program (cert-manager) gets a free,
trusted HTTPS certificate and renews it on its own.

### The name
The public IP changes on every start (a fixed Elastic IP would cost money even while
stopped). At every boot, a small service on the node:
1. asks the metadata service for the new public IP;
2. reads the DuckDNS token from SSM;
3. tells DuckDNS: `k3s-gitops-lab.duckdns.org` now points to that IP (TTL 60 s).

The token never touches the disk, the command line or the logs.

### The path of one request
```
browser ─▶ k3s-gitops-lab.duckdns.org ─▶ the server's public IP, port 443
        ─▶ security group (80/443 allowed)
        ─▶ ServiceLB (K3s): forwards ports 80/443 to Traefik
        ─▶ Traefik: matches the Ingress rule (host, path /, /health), serves the certificate
        ─▶ NetworkPolicy allows Traefik → app port 8000
        ─▶ one READY lab-api pod in namespace push
```
Plain HTTP (port 80) is redirected to HTTPS, except Let's Encrypt's challenge path.

### The certificate
cert-manager asks **Let's Encrypt** for a certificate using the **HTTP-01** challenge:
Let's Encrypt gives a token, cert-manager serves it at
`http://k3s-gitops-lab.duckdns.org/.well-known/acme-challenge/<token>`, and Let's Encrypt
fetches it to confirm we control the name. The certificate (90 days) is stored as a
Kubernetes Secret, which Traefik serves. cert-manager renews it 30 days before it expires.
Two issuers exist, **staging** (for tests, generous rate limits) and **production**.

Read more: [35](35-ingress.md), [36 (DNS)](36-dynamic-dns.md),
[36 (certificates)](36-cert-manager.md).

---

## 7. Two ways to deploy: push and pull

**In plain terms:** the same app is deployed twice, in two namespaces, by two different
methods, to compare them. **Push:** the automation in GitHub logs in to the cluster and
installs the new version. **Pull:** a program in the cluster notices the change in git and
installs it itself.

### The shared starting point: the image pin
Both namespaces run the image whose digest is written in one file,
`k8s/components/lab-api-image`. After every new image is published, a bot (a GitHub App,
`k3s-gitops-lab-bot`) opens a pull request that changes that one line. The PR runs every
check, then **merges itself**. The bot's commit is signed by GitHub.

### Push path (`deploy-push.yml`, namespace `push`)
When a merge to `main` changes the app's manifests or the image pin, a GitHub Actions job:
1. renders and checks the manifests (`render-k8s.sh`);
2. checks the image's signature (`verify-image.sh`);
3. **joins the tailnet** as a temporary device tagged `tag:ci`, using GitHub's OIDC token
   (no stored Tailscale key);
4. **logs in to Kubernetes** with another GitHub OIDC token. K3s is configured to trust
   GitHub's tokens, but only for this repository's `production` environment, which only
   runs on `main`;
5. as the `github-deployer` identity, which may only manage the app's objects in
   namespace `push`, runs `kubectl apply` and waits for the rollout;
6. checks the public `/health`, then leaves the tailnet, and the temporary device
   disappears.

No password, key or token is stored anywhere: every credential is minted for this one job
and expires within minutes.

### Pull path (Argo CD, namespace `gitops`)
An Argo CD **Application**, `lab-api-gitops`, says: "namespace `gitops` must equal
`k8s/overlays/gitops` on `main`". Argo CD:
- **polls git every 3 minutes**; when `main` changes, it applies the difference;
- **self-heals:** if someone changes the app in the cluster by hand, it puts it back
  within seconds (it watches the cluster live; it only polls git);
- **prunes:** an object removed from git is deleted from the cluster.

### Comparing the two
| | Push | Pull |
|---|---|---|
| Who holds access to the cluster | GitHub Actions, per job | Argo CD, inside the cluster |
| Starts | seconds after the merge | at the next poll (up to ~3 min) |
| Manual change in the cluster | stays until the next deploy | reverted in seconds |
| If the cluster is off | the job fails (red) | catches up when it's back |
| Credentials crossing the internet into the cluster | a short-lived OIDC token | none |

### Rolling back
A rollback is a normal change: `git revert` the bot's bump commit, through a PR. Both
paths deploy the previous digest. Kubernetes reuses the previous ReplicaSet and the image
is still cached, so it's quick. It holds until the next build.

Read more: [39](39-push-deploy.md), [41](41-gitops-image-bump.md),
[42](42-argocd-application.md), [44](44-end-to-end.md), [45](45-rollback-drill.md).

---

## 8. Argo CD runs the platform too

**In plain terms:** Argo CD doesn't only deploy the app. It also installs and maintains
every platform component, including itself. After the first boot, the only way to change
anything in the cluster is to change git.

### App-of-apps
One **root** Application points at `k8s/platform/argocd-apps/`. That folder holds every
other Application, and the root's own definition. So adding a component means adding a
file there, and the root picks it up.

| Application | Installs | Folder |
|---|---|---|
| `root` | every Application below, and itself | `k8s/platform/argocd-apps` |
| `argocd` | Argo CD | `k8s/platform/argocd` |
| `cert-manager`, `cluster-issuers` | certificates; the Let's Encrypt issuers | `k8s/platform/cert-manager`, `…/cluster-issuers` |
| `external-secrets`, `secret-stores` | copies secrets from AWS into the cluster | `k8s/platform/external-secrets`, `…/secret-stores` |
| `monitoring` | Alloy and kube-state-metrics | `k8s/platform/monitoring` |
| `system-upgrade`, `upgrade-plans` | K3s upgrades, described as a Plan | `k8s/platform/system-upgrade`, `…/upgrade-plans` |
| `lab-api-gitops` | the app, namespace `gitops` | `k8s/overlays/gitops` |

Third-party manifests are copied into `vendor/` folders at a pinned version. Changes are
made by patches in each folder's `kustomization.yaml`, never by editing `vendor/`, so an
upgrade is a clean replacement.

### AppProjects: limits on Argo CD itself
Argo CD can technically change anything in the cluster. **AppProjects** limit each
Application. `gitops` may only touch namespace `gitops` and four kinds of object.
`platform` lists exactly the namespaces and kinds the platform components need. The render
check requires each project's list to **equal** what its Applications actually contain,
so the lists can't drift from reality.

### "Core" mode
Argo CD runs without its web UI, API server or login system. That's less memory and
nothing to attack. You see its state with `kubectl -n argocd get applications`.

Read more: [40](40-argocd-core.md), [42](42-argocd-application.md),
[43](43-app-of-apps.md).

---

## 9. Secrets: where every secret lives

**In plain terms:** the repository is public, so no secret is ever in it. Secrets live in
AWS SSM Parameter Store, encrypted, and are read only by what needs them, only when it
needs them. GitHub Actions has no AWS keys at all.

| Secret | Stored in | Read by | When |
|---|---|---|---|
| Tailscale OAuth client secret | SSM `/k3s-gitops-lab/tailscale/oauth-client-secret` | the node | first boot, only if the restored identity fails |
| DuckDNS token | SSM `/k3s-gitops-lab/duckdns/token` | the node | every boot |
| Node identity (16 files) | SSM `/k3s-gitops-lab/node-identity/…` | the node | first boot |
| Grafana Cloud token for Alloy | SSM `/k3s-gitops-lab/grafana-cloud/alloy-token` | External Secrets → Secret in `monitoring` | kept in sync |
| Grafana Cloud token for Terraform | SSM `/k3s-gitops-lab/grafana-cloud/terraform-token` | `scripts/tf-grafana.sh` on the laptop | per run; never written to Terraform state |
| Alert email address | SSM `/k3s-gitops-lab/grafana-cloud/alert-email` | the Grafana stack | per run; kept out of the public repo |
| GitHub App private key | a GitHub environment secret | the image-bump job | after each image publish |
| Gemini API key | a GitHub secret | the AI reviewer | per PR |

### How GitHub Actions gets into AWS without keys
GitHub gives each job a signed OIDC token that says, for example, "this is repository
`k3s-gitops-lab`, environment `production`". AWS checks the signature and the exact
claims, then hands out credentials for one hour. Three roles exist:

| Role | Who may use it | Can |
|---|---|---|
| `github-plan` | any pull request | read-only, for `terraform plan` |
| `github-apply` | jobs in environment `production` (main only) | create, start, stop and destroy the project's server, nothing else |
| `github-lab` | jobs in environment `lab` (main only) | start and stop the server, set its stop timer |

All three are explicitly **denied** reading the project's secrets. None can change IAM, so
CI can't widen its own permissions.

### External Secrets Operator (ESO)
ESO turns a reference in git ("the value at this SSM path") into a real Kubernetes
Secret, and keeps it current. It uses a dedicated AWS role that can read
`/k3s-gitops-lab/grafana-cloud/*` and nothing else, and its store is usable from
namespace `monitoring` only. (ESO runs on the node's network so it can reach the
metadata service while the hop limit stays at 1 for every other pod.)

Read more: [12](12-node-iam-and-secret.md), [16](16-github-oidc-roles.md),
[54](54-external-secrets.md), [63](63-start-lab-button.md).

---

## 10. Watching it: metrics, logs and an alert

**In plain terms:** a collector in the cluster (Alloy) sends the app's numbers and every
pod's logs to Grafana Cloud's free tier. If a copy of the app stays unhealthy for 2
minutes, Grafana sends an email, and another when it recovers.

```
lab-api pods ──/metrics──┐
kube-state-metrics ──────┤ Alloy (namespace monitoring), every 30 s
                         ├──▶ Grafana Cloud Prometheus (metrics)
every pod's logs ────────┘──▶ Grafana Cloud Loki (logs), read through the Kubernetes API
```
- **kube-state-metrics** turns Kubernetes' own state into numbers, such as "is this pod
  ready?" (`kube_pod_status_ready`).
- **Staying free:** only six metrics are kept, about 826 active series, far below the
  free limit.
- **The alert** is defined in Terraform (`terraform/grafana`): if any lab-api pod in `push`
  or `gitops` is not ready for **2 minutes**, email. A normal rollout makes a pod not-ready
  for about 5 seconds, which never reaches 2 minutes. "No data" isn't alerted: that means
  monitoring is down, which is a different problem.

Read more: [48](48-alloy-grafana-cloud.md), [49](49-readiness-alert.md).

---

## 11. Keeping it alive and cheap

**In plain terms:** the server runs only while someone uses it, and it stops itself if
forgotten. Upgrades are written in git and done by a program in the cluster. Once a week,
the whole server is thrown away and rebuilt from git, which proves the repository really
contains everything.

### Daily use
| Command | Does |
|---|---|
| `make start` | starts the server, sets a 3-hour stop timer (the **lease**), waits until the public name answers |
| `make extend` | moves the stop timer to 3 hours from now |
| `make stop` | stops it now |
| `make status` | state, address, timer, tailnet |
| `make up` / `make down` | builds the server from nothing / destroys it (shows the plan, asks `yes`) |
| **Actions → lab → Run workflow** | start, stop or extend from a browser or a phone, without the laptop |

### Three ways a forgotten server gets stopped
1. **The lease:** every start schedules a stop (EventBridge Scheduler) 3 hours later.
2. **Nightly stop:** every night at 23:00 Bucharest time.
3. **The weekly rebuild** ends with a stop.

### What it costs
| Item | Per month |
|---|---|
| Server, about 40 hours of use | ~$1.54 |
| Disk (billed even while stopped) | ~$1.14 |
| Public IP while running | ~$0.20 |
| **Total** | **~$2.90** |
| The same server running 24/7, for comparison | ~$33 |

Everything else is free: the network, SSM, the scheduler, GitHub Actions and the
registry for a public repo, and the free tiers of Tailscale, Grafana Cloud, DuckDNS and
Gemini. The "never create" list in the README names what would break this: load
balancers, NAT gateways, EKS, Elastic IPs, Route 53 zones, paid encryption keys.

### Upgrading Kubernetes itself
The **system-upgrade-controller** reads a **Plan** from git (`k8s/platform/upgrade-plans`):
"this node should run K3s v1.37.1+k3s1". When the version differs, it runs a job that
cordons the node (no new pods land), replaces the K3s binary and restarts K3s, then
uncordons. Running containers keep running during the restart. The first upgrade,
v1.36.4 → v1.37.1, lost 1 request out of 215 during a check that sent requests the whole
time. That one failure came from the new version replacing its bundled Traefik.

### The weekly rebuild (`rebuild.yml`, Sundays 03:17 UTC)
```
terraform destroy ─▶ terraform apply ─▶ first boot restores the identity, configures itself
─▶ Argo CD installs the platform ─▶ the push deploy installs the app in namespace push
─▶ public HTTPS /health = 200 ─▶ stop the server
```
The second, fully automated run took **23 min 45 s**. The slowest part (about 11 minutes)
is waiting for every component to download and for the new certificate. Anything fixed by
hand on the old server is gone after this; only what's in git comes back.

Read more: [47](47-memory-headroom.md), [51](51-k3s-upgrade.md),
[61](61-make-lifecycle.md), [62](62-nightly-autostop.md), [63](63-start-lab-button.md),
[64](64-weekly-rebuild.md).

---

## 12. Guardrails on the repository

**In plain terms:** because the cluster deploys whatever is on `main`, protecting `main` is
protecting the cluster. Nothing reaches it without a pull request and passing checks, and
everything the project depends on is pinned to an exact, verified version.

- **Ruleset on `main`:** no direct pushes, no force pushes, signed commits only, squash
  merges only, open review comments must be resolved. No exceptions, not even for the
  owner.
- **Required checks on every PR:**

  | Check | Proves |
  |---|---|
  | `zizmor` | the workflows have no known security mistakes |
  | `terraform-lint` | Terraform is formatted and valid, and passes tflint and Trivy's security rules |
  | `ruff`, `pytest` | the app is linted and its tests pass |
  | `k8s-render` | every manifest renders and keeps the invariants in section 5 |

- **Pin everything.** Actions by commit SHA (a tag can be moved by an attacker; this
  happened to a popular action in March 2025). Images by digest. Tools such as kubectl,
  kustomize, tflint, trivy and cosign by exact version **and** SHA-256
  (`scripts/lib/tools.sh`); a download that doesn't match is refused.
- **Dependabot** proposes version bumps weekly, only for releases at least 7 days old (a
  hijacked release is usually caught within days).
- **AI review:** every PR gets an advisory review from Gemini. It's a second pair of eyes,
  not a gate; its findings are checked, and rejected with evidence when wrong.

Read more: [3](3-dependabot.md), [4](4-pin-actions.md), [6](6-main-ruleset.md),
[17](17-terraform-lint.md), [57](57-ai-review.md).

---

## One change, start to finish

What happens when someone changes one line of the app and merges it:

```
1. Pull request          checks: zizmor, terraform-lint, ruff, pytest, k8s-render, image-build,
                         plus the AI review ─▶ all green ─▶ squash merge to main
2. image.yml (main)      build on ARM ─▶ scan ─▶ smoke test ─▶ push lab-api:<commit>
                         ─▶ attest (provenance, SBOM) ─▶ cosign sign
3. image-bump job        verify the signature ─▶ the bot opens a PR changing one line in
                         k8s/components/lab-api-image to the new digest ─▶ checks ─▶ it
                         merges itself
4a. deploy-push.yml      (triggered by the bot's merge) render + check ─▶ verify signature
                         ─▶ join tailnet ─▶ OIDC login ─▶ kubectl apply ─▶ rollout
                         ─▶ namespace push serves the new version
4b. Argo CD              (next poll, within ~3 min) sees the new commit ─▶ applies it
                         ─▶ namespace gitops serves the new version
5. Rollout, each side    one new pod starts ─▶ /ready 200 ─▶ an old pod is removed
                         ─▶ repeat, never fewer than 3 ready pods
6. Watching              Alloy ships metrics and logs; if a pod stayed not-ready for 2 min,
                         an email would go out
```
After step 1, nobody does anything by hand. `curl https://k3s-gitops-lab.duckdns.org/`
shows the new commit in `version`.

---

## What happens when something goes wrong

| Situation | What the system does |
|---|---|
| An app pod crashes | Kubernetes starts a new one; the other 2+ keep serving |
| An app pod hangs | liveness fails 3 times (30 s) ─▶ container restarted |
| An app pod is starting or draining | readiness fails ─▶ out of rotation, no restart; back when `/ready` answers 200 |
| CPU load rises | the autoscaler adds pods, up to 5 |
| A pod stays not-ready for 2 minutes | email from Grafana Cloud; another when it recovers |
| Someone edits the gitops app in the cluster | Argo CD reverts it within seconds |
| Someone edits the push app in the cluster | it stays until the next push deploy (no self-heal on that path) |
| A bad image is merged | `git revert` the bot's bump commit ─▶ both paths roll back |
| A vulnerable dependency gets into the image | the scan fails the build; nothing is pushed |
| An unsigned image is pinned | `verify-image.sh` refuses it before any deploy |
| A merge needs a deploy while the server is stopped | the push deploy fails red; re-run it after `make start` |
| The server is forgotten | the lease or the 23:00 stop turns it off |
| The server is lost entirely | run **rebuild** (about 24 minutes); identity restored, everything from git |
| A secret leaks | rotate it in SSM (each lives in one place); CI holds no AWS keys to leak |

---

## Where to go next

- The task-by-task notes, with the reasoning, the alternatives and the proof of each
  step: [the index](README.md).
- How to run things locally (`make test`, `make k8s`, `make lint`): the repository
  [README](../../README.md).
- Diagrams: [`docs/architecture/`](../architecture/).
- The rebuild-from-zero runbook: [64, Runbook](64-weekly-rebuild.md#runbook-rebuild-from-zero-52).
