# 31 · securityContext and Pod Security "restricted"

> Issue: #31 (3.5) · Phase 3

## What
The app pod runs **non-root** (UID/GID 65532), with a **read-only root filesystem**, **no
privilege escalation**, **every Linux capability dropped**, the runtime's default **seccomp**
filter, and **no service-account token**. Both namespaces enforce Kubernetes' Pod Security
Standard **`restricted`**, so any pod that is not hardened like this is rejected at admission.

## Why
If the app is compromised, the attacker gets an unprivileged process that cannot write files,
cannot gain privileges through setuid binaries or capabilities, makes only common syscalls,
and holds no credential for the Kubernetes API. The image already provides some of this
(non-root user, no shell, #20). The securityContext makes Kubernetes *enforce* it, whatever the
image does. The namespace label makes it the rule for every pod, not just this manifest.

Alternatives considered:
- **Rely on the image** — a different image (or a bad base update) could run as root.
- **Pod Security `baseline`** — still allows root and most capabilities.
- **A policy engine (Kyverno, Gatekeeper)** — more flexible, but Pod Security Admission is
  built in and covers these rules with one label.

## How it works
| Setting | Level | Effect |
|---|---|---|
| `runAsNonRoot: true`, `runAsUser/Group: 65532` | pod | the kubelet refuses to start the container as root |
| `seccompProfile: RuntimeDefault` | pod | containerd's syscall filter (`Seccomp: 2` = filter mode) |
| `readOnlyRootFilesystem: true` | container | every write fails; the app writes nothing (bytecode precompiled, #20) |
| `allowPrivilegeEscalation: false` | container | sets `no_new_privs` (`NoNewPrivs: 1`): setuid/setcap cannot raise privileges |
| `capabilities.drop: ["ALL"]` | container | all capability sets zero; port 8000 needs no `NET_BIND_SERVICE` |
| `automountServiceAccountToken: false` | pod | no `/var/run/secrets/kubernetes.io/serviceaccount` |
| `pod-security.kubernetes.io/enforce: restricted`, `-version: v1.36` | namespace | the API server rejects non-compliant pods; the version is pinned so a K3s upgrade cannot change the rules silently; `warn` shows violations on apply |

The render check (`k8s-render`) now also requires these container settings and the
`restricted` namespace label.

## Verification
| Check | Result |
|---|---|
| **Done-when: write to the root filesystem** (`touch` does not exist in distroless; Python's `open()` instead) | `/x`, `/tmp/x`, `/app/lab_api/x`: `OSError: [Errno 30] Read-only file system` |
| **Done-when: no capabilities** (`/proc/1/status`) | `CapInh/CapPrm/CapEff/CapBnd/CapAmb: 0000000000000000`, `NoNewPrivs: 1`, `Seccomp: 2` |
| User | `uid 65532 gid 65532 groups [65532]` |
| Service-account token | not mounted (`False`) |
| App after the rollout | 3/3 Running, 0 restarts |
| **Negative: an unhardened pod in `push`** | `Forbidden: violates PodSecurity "restricted:v1.36": allowPrivilegeEscalation != false …, unrestricted capabilities …, runAsNonRoot != true …, seccompProfile …` |
| Applying the label to the running namespace | `Warning: existing pods … violate the new PodSecurity enforce level`: the old pods, replaced by the rollout right after |
| **Negative: render check** | `readOnlyRootFilesystem: false` → `containers missing the #31 securityContext`; namespace `baseline` → `does not enforce Pod Security 'restricted'` |
| Restored | `kubectl diff -k` clean |

## Gotchas
- **The issue's `kubectl exec … touch /x` cannot work on distroless:** there is no `touch`, so it
  would fail with "executable file not found", for the wrong reason. The test writes with Python
  (present: it runs the app) and checks the error is `Read-only file system`.
- **Ad-hoc test pods now need a securityContext:** `kubectl run` without one is rejected in
  these namespaces. Earlier tasks' curl clients would now need `--overrides`.
- **Enforcement applies at pod creation:** labelling a namespace never evicts running pods; it
  only warns about them.

## Further reading
- [Pod Security Standards: restricted](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted)
- [Pod Security Admission labels](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Configure a security context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Linux capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)
