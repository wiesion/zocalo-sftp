# Zocalo SFTP

SFTP server for container environments. Access control uses native Linux groups and file permissions instead of a database or virtual-user layer. Users and projects are declared in mounted config files; a reconciliation loop converges the container to match. Prometheus metrics are built in; logs are plain text, ready for whatever log shipper you already run.

Users land directly in `/projects/` and see only the projects they're authorized for.

*[Zocalo](https://babylon5.fandom.com/wiki/Z%C3%B3calo) is a marketplace in [Babylon 5](https://en.wikipedia.org/wiki/Babylon_5) (the 1990s sci-fi TV series), which is also why the examples use its character names.*

## What This Is (and Isn't)

This project composes existing tools: `openssh-server`, `tini`, `socat`, standard Unix permissions, plus one purpose-built component, `sftp-reconciled` (config validation, sshd_config rendering, user/project reconciliation). Nothing more.

**What this is:**
- A hardened OpenSSH server configured for SFTP-only access
- Group-based project isolation using native Linux permissions
- Migration path from `atmoz/sftp` or `emberstack/sftp-server` (config needs adaptation)
- Works with any SFTP client: FileZilla, WinSCP, Cyberduck, or command-line tools (`sftp`, `pscp -sftp`)
- Suitable for human users and automated deployment scripts
- Logs and metrics for integration with your monitoring stack

**What this is not:**
- A competitor to [sftpgo](https://github.com/drakkan/sftpgo) (virtual users, web UI, S3 backends, a different league entirely)
- A complete security solution (no built-in IP banning, rate limiting, or intrusion detection)
- A dynamic user management system
- Supporting anything other than `openssh-server` as the SFTP engine

**Security monitoring:** IP banning and intrusion detection are **not** part of this project. Your SIEM or log aggregator handles that: parse logs, detect brute force patterns, update firewall rules, or run external fail2ban as a sidecar.

**Use this if you need:**
- SFTP access for developers, clients, or automated systems
- File sharing or collaboration via standard SFTP clients
- Deployment targets for applications that push files via SFTP
- Legacy FTP server replacement
- Something you can understand completely by reading ~400 lines of shell/config and ~1200 lines of Rust. No framework, no runtime magic

**Don't use this if you need:** web UI for user management, virtual/database-backed users, S3 or cloud storage backends, advanced quota management, REST API for automation.

## Quick Start

Create `config/sftp_users.conf` and `config/sftp_projects.conf`:

```
# sftp_users.conf - username:uid
sheridan:1001
garibaldi:1002
franklin:1003
```

```
# sftp_projects.conf - project_name:gid:user1,user2,...
station-ops:2001:sheridan,garibaldi
medical:2002:franklin
```

```yaml
services:
  sftp:
    image: wiesion/zocalo-sftp:latest
    ports:
      - "2222:22"
    secrets:
      - ssh_host_ed25519_key
      - sheridan.authorized_keys
      - garibaldi.authorized_keys
      - franklin.authorized_keys
    volumes:
      - ./data:/sftp-jail/projects
      - ./config:/config:ro

secrets:
  ssh_host_ed25519_key:
    file: ./secrets/ssh_host_ed25519_key
  sheridan.authorized_keys:
    file: ./secrets/sheridan_key.pub
  garibaldi.authorized_keys:
    file: ./secrets/garibaldi_key.pub
  franklin.authorized_keys:
    file: ./secrets/franklin_key.pub
```

Generate keys:
```bash
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
ssh-keygen -t ed25519 -f secrets/sheridan_key -N ""
ssh-keygen -t ed25519 -f secrets/garibaldi_key -N ""
ssh-keygen -t ed25519 -f secrets/franklin_key -N ""
```

Connect:
```bash
sftp -P 2222 -i secrets/sheridan_key sheridan@localhost
sftp> cd station-ops
sftp> put report.txt
```

## How It Works

When the container starts, it creates users and project directories from your config. Users log in and see only the projects they're authorized for.

```
/projects/
  ├── station-ops/     # sheridan, garibaldi
  └── medical/         # franklin only
```

Project directories use setgid permissions so new files inherit the project group. The parent directory is owned by root, so users can't delete entire projects.

For the startup sequence, the Rust reconciler's internals, and the logging/sshd_config implementation details, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Build & Publish

Published images are built and signed by [`.github/workflows/release.yml`](./.github/workflows/release.yml): `wiesion/zocalo-sftp:latest`/`vX.Y.Z` on a tagged release, `wiesion/zocalo-sftp:nightly` tracking Wolfi's continuously-rebuilt base. Verify a pulled image with keyless [Cosign](https://github.com/sigstore/cosign):

```bash
cosign verify wiesion/zocalo-sftp:latest \
  --certificate-identity-regexp="https://github.com/wiesion/zocalo-sftp/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

**Building your own instead:** if you're Chainguard-licensed and want an audited base tag, need a different registry, or just don't want to trust a third-party build for something this security-sensitive, the Dockerfile builds standalone, no CI required:

```bash
docker build \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg VERSION="1.0.0" \
  -t zocalo-sftp:1.0.0 .
```

Generate an SBOM for what you built (see [Security](#security) for details):

```bash
./scripts/generate-sbom.sh zocalo-sftp:1.0.0
```

Tag for your own registry, sign it yourself if you want to, and push:

```bash
docker tag zocalo-sftp:1.0.0 your-registry.example.com/zocalo-sftp:1.0.0
cosign generate-key-pair                                                    # one-time
cosign sign --key cosign.key your-registry.example.com/zocalo-sftp:1.0.0    # optional
docker push your-registry.example.com/zocalo-sftp:1.0.0
```

Either way, deploy it the same way as any container image. See [Examples](#examples) for working Docker Compose setups, and [examples/09-kubernetes](./examples/09-kubernetes) for a StatefulSet.

## Configuration

### Users

Format: `username:uid`, one per line, `#` comments ignored.

```
# config/sftp_users.conf
sheridan:1001
garibaldi:1002
franklin:1003
```

Mount the config directory:
```yaml
volumes:
  - ./config:/config:ro
```

To disable a user without removing their UID record, append `:disabled`:
```
sheridan:1001:disabled
```
The user's shadow entry is locked (`!*`), so no login is possible. Remove `:disabled` to re-enable. The reconcile loop picks up the change within `SFTP_RECONCILE_INTERVAL` seconds.

UIDs must be in range 1000-59999.

### Projects

Format: `project_name:gid:user1,user2,...`, one per line, `#` comments ignored.

```
# config/sftp_projects.conf
station-ops:2001:sheridan,garibaldi
medical:2002:franklin
```

GIDs must be in range 1000-59999.

### Runtime Reconciliation

Mount `./config` as a directory and `sftp-reconciled` converges `/etc/passwd`, `/etc/shadow`, and `/etc/group` toward the declared state: immediately on a `.generation` change, and at least every `SFTP_RECONCILE_INTERVAL` seconds (default: 15) otherwise.

To force an immediate reconcile without waiting for the interval, increment the generation counter:
```bash
printf '%s\n' "$(($(cat config/.generation) + 1))" > config/.generation
```

See [ARCHITECTURE.md § Reconciliation Internals](./ARCHITECTURE.md#reconciliation-internals) for how the watch loop and idempotent reapply are implemented.

### Authentication

Authentication is controlled by a single `SFTP_AUTH_MODE` environment variable. Default: `pubkey` (ed25519 public key only).

| Mode                 | Accepts                            | Requires secret(s)                               |
|----------------------|-------------------------------------|--------------------------------------------------|
| `pubkey` *(default)* | ed25519 public key                 | `username.authorized_keys`                       |
| `cert`               | CA-signed certificate              | `ssh_user_ca.pub`                                |
| `pubkey\|cert`       | Public key **or** certificate      | `username.authorized_keys` + `ssh_user_ca.pub`   |
| `password`           | Password                           | `username.password`                              |
| `pubkey\|password`   | Public key **or** password         | `username.authorized_keys` + `username.password` |
| `cert\|password`     | Certificate **or** password        | `ssh_user_ca.pub` + `username.password`          |
| `any`                | Any of the above                   | All or some of the above                         |
| `pubkey,password`    | Public key **and** password (2FA)  | `username.authorized_keys` + `username.password` |
| `cert,password`      | Certificate **and** password (2FA) | `ssh_user_ca.pub` + `username.password`          |

`|` = OR, any listed mechanism is sufficient. `,` = AND, all listed mechanisms are required (2FA).

**Public key secrets** at `/run/secrets/username.authorized_keys`. Ed25519 only.

**Certificate mode** requires a CA public key at `/run/secrets/ssh_user_ca.pub`. Certificates must be signed by that CA; by default OpenSSH requires the certificate's principal to match the login username.

**Password secrets** at `/run/secrets/username.password`, plaintext. Hashed with SHA-512 crypt and written to `/etc/shadow`. `sftp-reconciled` re-checks every password secret on each reconciliation pass, so rotating a password file takes effect without a restart. Public keys rotate even faster: `AuthorizedKeysFile` is read fresh by sshd on every connection attempt, independent of the reconcile interval.

```yaml
environment:
  SFTP_AUTH_MODE: "pubkey|cert"  # accept either a key or a certificate

secrets:
  - ssh_host_ed25519_key
  - ssh_user_ca.pub
  - sheridan.authorized_keys  # optional when cert covers all users
```

### SSH Configuration

Drop-in files extend or adjust the base sshd config:

```yaml
volumes:
  - ./custom.conf:/config/sshd_config.d/custom.conf:ro
```

**First-match-wins:** the `Include /config/sshd_config.d/*.conf` is positioned deliberately:

- **Before** the Include (drop-ins **cannot** override): `AllowGroups`, `PermitRootLogin`, `PermitEmptyPasswords`, `KexAlgorithms`, `Ciphers`, `MACs`, `ChrootDirectory`, `ForceCommand`, host key directives.
- **After** the Include (drop-ins **can** override): `LoginGraceTime`, `MaxStartups`, `PrintMotd`, and everything in `Match Group sftp_users` (auth settings, session limits, banner).

Drop-ins are useful for:
- Per-group session tuning: `MaxSessions`, `ClientAliveInterval`, `MaxAuthTries` in a `Match Group <project-name>` block
- Per-user overrides: `Match User <username>` blocks
- Certificate control: `AuthorizedPrincipalsFile`, `AuthorizedPrincipalsCommand`
- Per-group auth overrides: different `AuthorizedKeysFile` path or `TrustedUserCAKeys` for one group

The project group name doubles as the Linux group name, so `Match Group media-team` in a drop-in applies to all users in that project.

**Warning:** do not add a `Match Group sftp_users` block in a drop-in. Since the Include runs first, it would be evaluated before the base block and could override `ChrootDirectory` or `ForceCommand`, breaking the SFTP jail. Use `Match Group <project-name>` instead.

**IPv4/IPv6:** listens on both by default.

```yaml
environment:
  SSHD_ENABLE_IPV4: "yes"  # default
  SSHD_ENABLE_IPV6: "no"   # IPv4-only
```

At least one must be `yes`. `ListenAddress` entries for the disabled family are silently ignored by sshd.

**Metrics bind address:** binds to all interfaces by default.

```yaml
environment:
  SFTP_METRICS_BIND: "127.0.0.1"  # IPv4 loopback; use "::1" for IPv6 loopback
```

See [ARCHITECTURE.md § sshd_config Include Ordering, in Depth](./ARCHITECTURE.md#sshd_config-include-ordering-in-depth) for the reasoning behind the split above.

## Environment Variables

| Variable              | Default   | Description                                                                   |
|-----------------------|-----------|-------------------------------------------------------------------------------|
| `SFTP_AUTH_MODE`      | `pubkey`  | Authentication mode, see [Authentication](#authentication) for all values    |
| `SFTP_ENABLE_METRICS` | `no`      | Expose Prometheus metrics on port 9100                                        |
| `SFTP_LOG_LEVEL`      | `ERROR`   | SFTP subsystem log level                                                      |
| `SFTP_METRICS_BIND`   | `0.0.0.0` | IP address the metrics endpoint binds to                                      |
| `SFTP_PROJECT_MODE`        | `770`  | Permissions for project directories (setgid always added)                     |
| `SFTP_RECONCILE_INTERVAL`  | `15`   | Seconds between config file reconciliation checks (minimum: 5)                |
| `SFTP_RESET_PROJECTS`      | `yes`  | Reset project ownership on start (only the literal value `yes` enables this)  |
| `SFTP_RESET_USERS`         | `yes`  | Recreate users on container start (only the literal value `yes` enables this) |
| `SFTP_USERS_GID`           | `59999`| Group ID for all SFTP users                                                   |
| `SSHD_ENABLE_IPV4`    | `yes`     | Listen on IPv4 (`0.0.0.0`)                                                    |
| `SSHD_ENABLE_IPV6`    | `yes`     | Listen on IPv6 (`::`)                                                         |
| `SSHD_LOG_LEVEL`      | `INFO`    | SSH daemon log level                                                          |

## Operator Responsibilities

This project does minimal validation and trusts you to provide correct configuration.

**Validated:**
- `SFTP_AUTH_MODE`: must be a documented enum value
- `SSHD_LOG_LEVEL`, `SFTP_LOG_LEVEL`: valid OpenSSH enum values
- `SSHD_ENABLE_IPV4`, `SSHD_ENABLE_IPV6`: `yes`/`no`, at least one `yes`
- `SFTP_PROJECT_MODE`: 3-digit octal string
- `SFTP_USERS_GID`: integer, 1000-59999
- Host key (`ssh_host_ed25519_key`): present and non-empty
- CA key (`ssh_user_ca.pub`): present and non-empty when a cert mode is selected
- Username / project name: `[a-z0-9_-]+`, non-empty, no leading `-`
- UID per user, GID per project: integer, 1000-59999
- UID/GID conflicts: container refuses to start if a user or group already exists with a different ID

**Not validated:**
- Duplicate UIDs or GIDs across users/projects: appended directly to `/etc/passwd`/`/etc/group`, so a duplicate silently produces corrupt state rather than an error
- Whether users listed in a project already exist
- Naming conventions, reserved names, profanity

**Your duties:** sanitize user/project lists before they reach config, understand Linux permissions and group membership, test config changes before production, handle UID/GID changes manually.

**Changing UIDs/GIDs** requires manual intervention on existing files:
```bash
# Changed sheridan from UID 1001 to 1002
docker exec sftp find /sftp-jail/projects -uid 1001 -exec chown 1002 {} \;

# Changed project GID from 2001 to 2002
docker exec sftp find /sftp-jail/projects/project-name -gid 2001 -exec chgrp 2002 {} \;
```

## Logging

Logs go to stdout/stderr, plain text, one line per event, from three independent processes multiplexed into the same stream:

```
Reconcile: added user sheridan (UID 1001)
Server listening on 0.0.0.0 port 22.
Accepted publickey for sheridan from 172.18.0.1
Sep 23 10:00:01 internal-sftp[123]: open "/projects/station-ops/report.txt" flags READ mode 0644
```

`sftp-reconciled` (user/project provisioning), `sshd` (auth, connections), and `internal-sftp` (file operations) each log in their own native format. Nothing here parses, classifies, or restructures those lines: this project emits plain text and leaves enrichment, correlation, and shipping to your log pipeline, the same as any other container should. See [examples/03-cloud-native](./examples/03-cloud-native) for a complete, tested example wiring this up to Vector, including the parsing rules that turn these lines into structured records.

One inconsistency worth knowing about before you write a parser: `internal-sftp` lines carry their own timestamp and PID (`internal-sftp[123]:`, courtesy of glibc's `syslog()` call), `sshd` and `sftp-reconciled` lines carry neither. That's not a design choice on this project's part, it's just how each upstream process happens to log; a real timestamp for every line comes from whatever captures stdout (Docker's log driver, Kubernetes, journald), not from the lines themselves.

File operations (upload, download, delete, rename, mkdir) only appear in the `internal-sftp` stream at `SFTP_LOG_LEVEL: INFO` or more verbose. The default, `ERROR`, logs failures only; a normal upload or delete produces no log line at all.

The IP in sshd's log lines is whatever sshd sees as the TCP connection's source. Behind a proxy or load balancer that isn't set up carefully, that may not be the real client. See [Client IP Behind a Proxy or Load Balancer](#client-ip-behind-a-proxy-or-load-balancer) before you deploy behind one.

`internal-sftp` can only log via syslog to a UNIX socket, there's no "log to stdout" option, so a small `socat`/`awk` relay is required just to get that one stream onto stdout as plain lines at all. See [ARCHITECTURE.md § Logging Pipeline Internals](./ARCHITECTURE.md#logging-pipeline-internals) for why, and why it stops there rather than going further.

## Metrics

Set `SFTP_ENABLE_METRICS=yes` and expose port 9100:

```yaml
environment:
  SFTP_ENABLE_METRICS: yes
ports:
  - "9100:9100"
```

Available metrics:
- `sftp_active_connections` - Current SFTP sessions
- `sftp_active_users` - Unique users connected
- `sftp_disk_used_kb` - Disk usage in projects directory
- `sftp_disk_available_kb` - Available disk space
- `sftp_disk_total_kb` - Total disk capacity of the projects volume
- `sftp_project_disk_kb{project="..."}` - Per-project usage

Prometheus can scrape `http://localhost:9100/metrics` directly.

## Security

### Base Image

Built on [cgr.dev/chainguard/wolfi-base](https://github.com/chainguard-images/wolfi-base): glibc-based, rebuilt continuously, with accurate APK package metadata for SBOM generation. The Rust reconciler is compiled in a separate `rust:alpine` builder stage that's discarded after the copy, so nothing from it ships in the final image.

The Dockerfile pins both `WOLFI_SELECTOR` (runtime base) and `RUST_SELECTOR` (build-time only) to digests of free, unlicensed tags by default, so building requires no Chainguard subscription or Docker Hub account. Override either with `--build-arg` depending on what you need:

- **Just want to run SFTP?** Build as-is. The defaults work out of the box.
- **Want current packages, don't care about pinning?** `--build-arg WOLFI_SELECTOR=:latest --build-arg RUST_SELECTOR=:alpine`.
- **Chainguard-licensed and want an audited, version-pinned tag?** `--build-arg WOLFI_SELECTOR=:<version>` (Rust has no licensed variant; it's Docker Hub's standard image either way).
- **Supply-chain conscious?** Resolve and pin your own digest. See the comment block at the top of the `Dockerfile` for the exact commands (`scripts/resolve-base-sha.sh` for Wolfi, `docker inspect` for Rust).

The published `wiesion/zocalo-sftp` image is built from the same free, unlicensed Wolfi tag as the defaults above, CI has no Chainguard subscription to build with either. If you're Chainguard-licensed and want an audited base, build your own (see [Build & Publish](#build--publish)); Wolfi's licensing terms are between you and Chainguard either way, not mediated by this project.

User/group management avoids shadow-utils entirely: accounts are provisioned by writing directly to `/etc/passwd` and `/etc/shadow`, which removes shadow, libaudit, libsemanage, and libbsd from the image and its transitive dependency tree.

Generate an SBOM for your locally built image (no local tooling required, syft runs in Docker):

```bash
./scripts/generate-sbom.sh zocalo-sftp:latest
# writes sbom.spdx.json and sbom.cyclonedx.json
```

`sftp-reconciled` is a statically linked, stripped Rust binary, invisible to image-based cataloging by default. That's why the script enables an extra cataloger and the Dockerfile keeps `Cargo.lock` in the final image; without both, the scan reports zero Rust crates.

### Cryptography

- **Host keys:** ed25519 only
- **Key exchange:** sntrup761x25519-sha512, curve25519-sha256
- **Ciphers:** AES-GCM, ChaCha20-Poly1305 (AEAD only)
- **Public keys:** ed25519 only (including certificate signatures)
- **Authentication:** controlled by `SFTP_AUTH_MODE`; defaults to ed25519 public key only

Always disabled, regardless of configuration: root login, empty passwords, shell access.

Users are chrooted and can only use SFTP.

### Container Hardening

The container should also be locked down at the runtime level. All examples include the following:

**Drop capabilities (Docker Compose / Podman)**

```yaml
cap_drop:
  - ALL
cap_add:
  - CHOWN            # file ownership during user/project setup
  - DAC_OVERRIDE     # read/write /etc/shadow, it ships mode 0000 on Wolfi, even root needs this
  - MKNOD            # device nodes in the chroot jail
  - NET_BIND_SERVICE # bind to port 22 (and 9100 if metrics are enabled)
  - SETGID           # group operations and sshd privilege separation
  - SETUID           # user operations and sshd privilege separation
  - SYS_CHROOT       # sshd ChrootDirectory for the SFTP jail
security_opt:
  - no-new-privileges:true
```

`cap_drop: ALL` removes every capability from the bounding set; `cap_add` grants back exactly what's needed. `no-new-privileges` blocks capability gain via a SUID binary.

**Kubernetes equivalent**

```yaml
securityContext:
  allowPrivilegeEscalation: false   # equivalent to no-new-privileges
  capabilities:
    drop: ["ALL"]
    add:
      - CHOWN
      - DAC_OVERRIDE
      - MKNOD
      - NET_BIND_SERVICE
      - SETGID
      - SETUID
      - SYS_CHROOT
```

See [examples/09-kubernetes](./examples/09-kubernetes) for a complete manifest set (StatefulSet, headless Service, split liveness/readiness probes, NetworkPolicy) built on this.

## Operations

### Graceful Shutdown

[tini](https://github.com/krallin/tini) runs as PID 1 for correct zombie-reaping and signal-forwarding. Without it, SIGTERM from `docker stop` or Kubernetes wouldn't reach sshd.

On SIGTERM: sshd stops accepting new connections but lets active sessions finish. If it hasn't exited within 30 seconds, the entrypoint sends SIGKILL.

```bash
docker compose stop sftp  # sends SIGTERM; waits up to the stop_grace_period
```

### Reload Configuration

SIGHUP reloads SSH configuration and host keys without dropping active sessions:

```bash
docker compose exec sftp kill -HUP 1
```

New connections use the updated configuration; active sessions continue uninterrupted. SIGHUP does not re-run user or project provisioning, so adding or removing users/projects still needs a full restart.

### Host Key Reuse

Mount the same host key secret to all replicas to avoid "host key changed" warnings behind a load balancer.

### Performance Tuning

For large deployments:

```yaml
environment:
  SFTP_RESET_USERS: no      # Skip user cleanup on restart
  SFTP_RESET_PROJECTS: no   # Skip project reset on restart
```

Faster container starts; requires manual cleanup if you remove users from configuration.

### Client IP Behind a Proxy or Load Balancer

sshd logs whatever IP address the TCP connection's source shows it. SFTP runs over SSH, a raw TCP protocol, so there's no equivalent of HTTP's `X-Forwarded-For` header to recover the real client IP once something in front has replaced it.

Plain `docker run -p` or Compose port publishing preserves the real source IP by default (Docker's bridge networking does DNAT without SNAT), so logs are accurate out of the box. Behind a load balancer that performs SNAT, most cloud L4 load balancers in their default mode, and a Kubernetes `LoadBalancer`/`NodePort` Service at the default `externalTrafficPolicy: Cluster`, sshd instead sees the load balancer's or node's IP.

The usual fix for TCP protocols is the PROXY protocol (HAProxy's spec), but `sshd` has no native support for it. Pointing a proxy that sends PROXY protocol headers directly at this container will break the connection outright, not just lose the IP, since sshd tries to parse those header bytes as the start of the SSH handshake.

For Kubernetes, set `externalTrafficPolicy: Local` on your `LoadBalancer`/`NodePort` Service if you need accurate client IPs in logs. It avoids the kube-proxy SNAT that causes this, at the cost of uneven load across nodes and requiring your cloud load balancer to support per-node health checks.

## Examples

The [examples/](./examples/) directory has complete working setups:

- **01-basic-dev** - Local development with volume-mounted secrets
- **02-docker-secrets** - Production deployment with Docker secrets
- **03-cloud-native** - Prometheus metrics, log shipping to Vector, custom SSH config
- **04-multi-project** - Complex access patterns with multiple teams
- **05-certificate-auth** - CA certificate authentication using `SFTP_AUTH_MODE: cert`
- **06-password-auth** - Password authentication using `SFTP_AUTH_MODE: password`
- **07-2fa** - Two-factor authentication using `SFTP_AUTH_MODE: pubkey,password`
- **08-custom-config** - Drop-in sshd_config.d files for per-group and per-user overrides
- **09-kubernetes** - StatefulSet, split liveness/readiness probes, and a tested NetworkPolicy (kind + Calico)

## Requirements

The container needs a specific set of Linux capabilities at startup. See [Container Hardening](#container-hardening) for the full list across Docker Compose, Podman, and Kubernetes. The examples include the recommended capability set.

## Limitations

- New usernames must appear in `sftp_users.conf` / `sftp_projects.conf` to be picked up. Nothing scans `/run/secrets` to discover users, so a synced secret for a name not in those files is unused. Secret *rotation* for existing users does not require a restart; adding a new user only needs a config update and a `.generation` bump. See [Runtime Reconciliation](#runtime-reconciliation)
- No built-in user quotas (use filesystem quotas on the underlying volume)
- Metrics are aggregate only, not per-user connection stats
- Host key rotation requires a container restart or SIGHUP
- No PROXY protocol support (sshd has none), so client IPs in logs can be wrong behind a SNAT-performing load balancer. See [Client IP Behind a Proxy or Load Balancer](#client-ip-behind-a-proxy-or-load-balancer)
- File operations (upload, download, delete, rename, mkdir) aren't logged at the default `SFTP_LOG_LEVEL: ERROR`. Set it to `INFO` or more verbose for per-operation audit logging. See [Logging](#logging)

## AI-Assisted Development

I wrote the original image to this concept some time ago manually, and it was in production use over years as part of a docker swarm deployment. But to publish this on a public repo, I required much more test and docs coverage, as well include k8s primitives.

That is why this implementation was written with heavy use of coding agents ([Claude Code](https://claude.com/) + [Oh-My-Pi](https://omp.sh/) running on my own [self-hosted AI infrastructure](https://github.com/wiesion/llm-scaler-mbmg-sbmg-agent-server)). Disclosed here plainly. The architecture and every consequential design decision are the maintainer's, not the model's. See [ARCHITECTURE.md § Design Decisions](./ARCHITECTURE.md#design-decisions) for the specifics.

## License

MIT

## Contributing

Issues and pull requests welcome at https://github.com/wiesion/zocalo-sftp
