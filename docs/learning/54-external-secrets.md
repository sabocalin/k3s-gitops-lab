# 54 · External Secrets Operator + SSM Parameter Store

> Issue: #54 (5.0b) · Phase 5

## What
External Secrets Operator (ESO) runs in the cluster and turns an `ExternalSecret` (a
reference: "the value at this SSM parameter, as this key") into an ordinary Kubernetes
`Secret`, and keeps it current. One `ClusterSecretStore`, `aws-ssm`, points at AWS SSM
Parameter Store in this account. The first consumer is Alloy (#48), which needs the
Grafana Cloud token; nothing secret is committed to git or created with `kubectl`.

## Why
Alloy needs a token to push metrics and logs. The options were to commit it, to create
the Secret by hand (which then doesn't exist after a rebuild, #52/#64), or to have the
cluster fetch it from the place that already holds the project's secrets: SSM Parameter
Store (SecureString, AWS-managed key, $0).

Alternatives considered:
- **SOPS + a customer-managed KMS key**: secrets encrypted in git. The KMS key costs
  $1/month, and the issue rules it out.
- **Sealed Secrets**: encrypted in git with a key that lives in the cluster. A rebuild
  makes a new key, so every sealed secret would have to be re-sealed (or the key backed up
  somewhere, which is the original problem again).
- **Argo CD + a vault plugin**: Argo CD would read secrets while rendering, and they'd
  pass through its manifest cache.
- **Raise the instance metadata (IMDS) hop limit to 2**, as the issue suggests, so the
  ESO pod can reach the node's credentials. That would let **every** pod use the node role,
  which can read the Tailscale secret, the DuckDNS token and the node identity (#64).
  Rejected for the design below.

## How it works
```
ExternalSecret (namespace monitoring) ──▶ ESO controller (hostNetwork)
   │                                         │ IMDSv2 from the node's own network: hop limit 1 OK
   │                                         ▼
   │                                   node role credentials
   │                                         │ sts:AssumeRole (ClusterSecretStore .provider.aws.role)
   │                                         ▼
   │                                   k3s-gitops-lab-eso: ssm:GetParameter(s) on
   │                                   /k3s-gitops-lab/grafana-cloud/* only
   │                                         │
   ▼                                         ▼
Secret (owned by the ExternalSecret) ◀── SSM Parameter Store (SecureString, aws/ssm key)
```
- **Why hostNetwork.** IMDSv2 answers a token request with a TTL of 1 hop (the instance's
  `http_put_response_hop_limit`). A pod's packets cross the pod network bridge, one hop
  more, so its token request times out. The controller shares the node's network
  namespace, so its requests come from the node itself. Only this one Deployment gets the
  node's credentials; the hop limit stays at 1 for everything else.
- **Why a second role.** The node role must read the Tailscale secret and the DuckDNS
  token at boot, and the node identity on a rebuild (#64). ESO uses it only to assume
  `k3s-gitops-lab-eso`, which can read one path. An ExternalSecret that names any other
  parameter gets `AccessDenied` from IAM, whatever its YAML says.
- **Who may use the store.** `spec.conditions` limits the ClusterSecretStore to namespace
  `monitoring`. An ExternalSecret elsewhere is refused by ESO before any AWS call.
- **The price of hostNetwork.** Pod Security "restricted" (and "baseline") forbid it, so
  namespace `external-secrets` enforces "privileged". It still warns on "restricted", and
  the three upstream Deployments keep their restricted security context (non-root,
  read-only root, no capabilities, seccomp). Only ESO lives there.

## Implementation
- `terraform/platform/iam_eso.tf`: role `k3s-gitops-lab-eso`, trusted by the node role.
  Inline policy: `ssm:GetParameter`, `ssm:GetParameters` on
  `parameter/k3s-gitops-lab/grafana-cloud/*`. `iam_node.tf`: the node may assume it, and
  nothing else changes. Applied from a saved plan: 2 to add, 1 to change.
- `k8s/platform/external-secrets/`:
  - `vendor/external-secrets-v2.11.0.yaml`: the release asset, unmodified. Its sha256
    matched GitHub's published asset digest; v2.12.0 was 3 days old (7-day cooldown).
  - The image is pinned by digest and cosign-verified: keyless, workflow `release.yml` of
    `external-secrets/external-secrets`, logged in Rekor.
  - Upstream installs into `default`. `namespace: external-secrets` moves every object;
    Kustomize also rewrites the webhooks' service namespace and the bindings' subjects.
    Three flags that name the namespace are patched with `test` + `replace`, so a reorder
    upstream fails the build instead of patching the wrong flag.
  - The controller gets `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet` (in-cluster
    names still resolve), with metrics on `127.0.0.1:8080` (on the host network, `:8080`
    would listen on every node address, the tailnet included).
  - Resources: controller 48/160 Mi, cert-controller and webhook 32/128 Mi.
  - `Prune=false` on the CRDs and the Namespace (#43).
  - `namespace.yaml`: enforce `privileged`, warn `restricted`, with the reason in the
    annotation `k3s-gitops-lab/pod-security-exception`.
- `k8s/platform/secret-stores/clustersecretstore-aws-ssm.yaml`: provider `aws`, service
  `ParameterStore`, region `eu-central-1`, `role` = the ESO role, no credentials;
  conditions: namespace `monitoring`.
- Argo CD (`k8s/platform/argocd-apps/`):
  - Application `external-secrets` with `ServerSideApply=true`: several ESO CRDs exceed
    client-side apply's 256 KiB annotation;
  - Application `secret-stores`, which retries until ESO's webhook answers, like
    `cluster-issuers` (#43);
  - the `platform` AppProject gains namespace `external-secrets` and kind
    `ClusterSecretStore` (the render check named exactly those two).
- `scripts/render-k8s.sh`: a platform namespace that doesn't enforce "restricted" now
  needs a non-empty `k3s-gitops-lab/pod-security-exception` and `warn: restricted`, and
  the render prints the reason as a note.

## Verification
Before the merge, `root` can't sync a branch, and it would revert a hand edit of the
`platform` project. So the two Applications ran from the branch in a temporary project
(`test-54`, wildcard, deleted after the merge); `root` adopted them after the merge.

| Check | Result |
|---|---|
| `terraform plan` (platform), saved and applied | 2 to add, 1 to change, 0 to destroy |
| IAM simulator, role `k3s-gitops-lab-eso` | `grafana-cloud/alloy-token` allowed; Tailscale secret, DuckDNS token, node-identity CA key denied |
| Applications from the branch | `external-secrets` Synced/Healthy in about 1 min 40 s; `secret-stores` retried until ESO's webhook answered, then Synced/Healthy |
| Pods | 3/3 ready, 0 restarts; only the controller on `hostNetwork` (node IP) |
| ClusterSecretStore `aws-ssm` | `Ready=True`, `store validated` (the assume-role works) |
| **Done when:** ExternalSecret in `monitoring` for `/k3s-gitops-lab/grafana-cloud/alloy-token` | `SecretSynced`; Secret `probe-alloy` with key `token` (224 bytes, value not shown), owned by the ExternalSecret |
| Memory | ESO's three pods: 28 + 39 + 26 Mi; node `MemAvailable` 1396 Mi, swap 0 (Gate B, #47: Alloy's estimate + 200 Mi still fits) |

Negative controls:

| Test | Result |
|---|---|
| ExternalSecret in `monitoring` for the Tailscale OAuth secret | `AccessDeniedException` for `assumed-role/k3s-gitops-lab-eso`: IAM, not YAML, stops it |
| ExternalSecret in another namespace (`eso-neg`) for the allowed token | `using cluster store "aws-ssm" is not allowed from namespace "eso-neg": denied by spec.condition` |
| An ordinary pod (namespace `monitoring`): IMDSv2 token request | timed out (curl exit 28), while the same pod reached the internet (200). Only the host-network controller gets credentials |
| `make k8s` with the exception reason removed, or `warn: privileged` | both refused |

The probes and the temporary namespaces were deleted afterwards. Alloy (#48) creates
`monitoring` from git.

## Gotchas
- **The ESO error on the resource is generic** ("could not get secret data from
  provider"). The specific reason (`AccessDenied`, `denied by spec.condition`) is in the
  ExternalSecret's events and the controller log.
- **`ssm:DescribeParameters` wasn't needed.** ESO read the parameter with `GetParameter`
  alone, so the role doesn't have it (it would have listed every parameter name in the
  account).
- **`root` reverts hand edits to the `platform` project within seconds** (#43), so a
  branch can't be tested by editing the real project. A temporary project, untracked by
  `root`, works, and `root` adopts the same-named Applications after the merge.
- **hostNetwork ports are node ports.** The webhook (port 10250) stays on the pod network:
  on the host it would collide with the kubelet's 10250.

## Further reading
- [External Secrets Operator: AWS Parameter Store](https://external-secrets.io/latest/provider/aws-parameter-store/)
- [ESO: ClusterSecretStore conditions](https://external-secrets.io/latest/api/clustersecretstore/)
- [EC2: IMDSv2 and the hop limit](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-metadata-options.html)
- [Kubernetes: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
