# 09: Kubernetes

Kubernetes manifest set: StatefulSet, split liveness/readiness probes, a NetworkPolicy that's actually tested against a policy-enforcing CNI. Every other example is Docker Compose.

## What this deploys

- **StatefulSet**, 1 replica. Per-project storage and UID/GID identity need to survive pod restarts predictably. Single replica because the default `standard` StorageClass (local-path-provisioner) doesn't support `ReadWriteMany`. Scaling past 1 needs an RWX StorageClass (NFS, EFS, Filestore, CephFS) swapped into `manifests/02-statefulset.yaml`.
- **Headless Service** on ports 22 (SFTP) and 9100 (metrics).
- **Split liveness/readiness probes**: `sshd -t` for liveness, the Dockerfile `HEALTHCHECK`'s TCP-banner check for readiness. Docker only has one combined check; conflating the two in Kubernetes risks a slow-starting pod getting killed by what should have just failed readiness.
- **NetworkPolicy**: default-deny ingress, then two allows. Port 22 is open to everyone (auth is SSH's job), port 9100 only to pods labelled `role=monitoring` in a `monitoring` namespace (metrics are unauthenticated by design; see main README).
- **Two Secrets, one ConfigMap**: see below.

## Kubernetes-specific issues, found by running this on a real cluster

1. **`automountServiceAccountToken: false` is required.** The default token mount resolves (via `/var/run` → `/run`) to the same path our own Secret volume occupies (`/run/secrets`). Leaving it on breaks the mount and the pod never starts. Also correct least-privilege: this pod never talks to the K8s API.

2. **`DAC_OVERRIDE` capability is required.** `/etc/shadow` ships mode `0000` on Wolfi, so even root needs this to read/write it. The main README's Kubernetes snippet includes it too.

3. **`FSETID` capability is required.** Without it the kernel silently drops the setgid bit that `chmod 2770` sets on project directories (the caller is not a member of the project group), so files created in a project would no longer inherit the project's group.

4. **Secret file *modes* must differ within one mount.** sshd refuses a world-readable host key, but drops privileges to the connecting user before reading their `AuthorizedKeysFile`, so that one must be world-readable. Docker Compose gets this split for free (bind mounts inherit `ssh-keygen`'s host file modes: 0600 private key, 0644 `authorized_keys`); Kubernetes Secret volumes materialize everything at one mode unless told otherwise.

5. **sshd's `StrictModes` fails against any Secret/projected volume.** Kubernetes mounts these at `1777` (world-writable, tmpfs-backed, symlink-swapped on update), and `StrictModes` correctly refuses to trust `HostKey`/`AuthorizedKeysFile` through it. Worked around with a `StrictModes no` drop-in via the project's own `sshd_config.d` mechanism; doesn't affect any other check (ciphers, chroot, capabilities, no shell).

## Why two Secrets, not one

`manifests/02-statefulset.yaml` combines `zocalo-host-key` and `zocalo-user-secrets` into one `/run/secrets` mount via a `projected` volume, at two file modes (see issue 3). Two Secret *objects*, not one with per-key overrides: `zocalo-user-secrets` has no `items` list, so every key it holds is mounted automatically. Add users by updating that Secret (e.g. [External Secrets Operator](https://external-secrets.io/) syncing from Vault) without touching this manifest. Only the host key, which is singular, is named explicitly.

## Prerequisites

`kind` and `kubectl` (`brew install kind kubectl` on macOS). Nothing else: `test.sh`/`setup.sh` create their own disposable kind cluster with [Calico](https://www.tigera.io/project-calico/) for real NetworkPolicy enforcement and tear it down after. kind's default CNI (kindnet) does not enforce NetworkPolicy.

## Running it

```bash
./test.sh    # automated: cluster, deploy, assert, teardown
./setup.sh   # interactive: cluster, deploy, print connection info, wait, teardown
```

Both are self-contained and disposable. Nothing pre-existing assumed, nothing left behind.

## Applying manually

```bash
kubectl apply -k manifests/
kubectl -n zocalo-example create secret generic zocalo-host-key \
    --from-file=ssh_host_ed25519_key=./secrets/ssh_host_ed25519_key
kubectl -n zocalo-example create secret generic zocalo-user-secrets \
    --from-file=byron.authorized_keys=./secrets/byron.authorized_keys \
    --from-file=lochley.authorized_keys=./secrets/lochley.authorized_keys
kubectl -n zocalo-example set image statefulset/zocalo-sftp sftp=<your-image>
```

## What `test.sh` verifies

- Pod reaches `Ready` under the full hardened `securityContext`
- SFTP login and file upload/download round-trip via `kubectl port-forward`
- Metrics (`:9100`) unreachable from an unlabeled pod anywhere in the cluster
- Metrics reachable from a `role=monitoring` pod in a `monitoring` namespace: the allow rule is scoped, not blanket
- SFTP (`:22`) still open to an unlabeled pod: the deny didn't sweep up the wrong port
- Liveness and readiness are distinct probe commands

## Limitations of this example

- Single replica only (see StorageClass note above)
- `readOnlyRootFilesystem` not set: this container mutates `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/ssh/sshd_config`
- Cannot run under the Kubernetes **restricted** Pod Security Standard, since sshd's privilege-separation model needs `root`, `SETUID`, `SETGID`, `SYS_CHROOT`. Fits **baseline**.
- No Ingress/LoadBalancer example: exposing port 22 externally is infrastructure-specific, left to you, same as storage backend choice. If you add a `LoadBalancer`/`NodePort` Service, set `externalTrafficPolicy: Local` or SFTP logs will show node IPs instead of real client IPs; see the main README's [Client IP Behind a Proxy or Load Balancer](../../README.md#client-ip-behind-a-proxy-or-load-balancer) section
