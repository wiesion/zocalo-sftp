# Architecture

This document covers the internals and design rationale behind Zocalo SFTP: why things are built the way they are, not just how to use them. For usage, configuration, and deployment, see [README.md](./README.md).

## Component Overview

Startup sequence, run by [`resources/entrypoint.sh`](./resources/entrypoint.sh) under `tini` (PID 1):

1. **`sftp-reconciled init`**: validates every environment variable up front (fails fast with every problem reported at once, not one restart cycle at a time), renders `/etc/ssh/sshd_config` from [`resources/sshd.conf`](./resources/sshd.conf), then does one strict pass of user/project provisioning. Parse errors, identity collisions (duplicate or clashing UIDs/GIDs, names) or jail-weakening drop-ins abort the container before sshd ever starts, and before anything under `/etc` is touched. The one line it prints to stdout, the derived metrics socat address, is the only contract with `entrypoint.sh`; every diagnostic goes to stderr so it can't leak into that captured value.
2. **Chroot jail setup**: copies `/etc/localtime` into the jail. `internal-sftp` needs no device nodes there, so no `CAP_MKNOD` is required; the only device-like entry is the `dev/log` socket created by the log relay. Then `sshd -t` checks the rendered config before any helper process starts.
3. **SFTP subsystem log relay**: `internal-sftp` runs inside the chroot and writes to `/dev/log` via glibc syslog (a UNIX datagram socket, no newline terminator). A supervised `socat` loop relays the raw bytes to an `awk` process that frames them into plain lines. If the socket disappears, `socat` exits and the loop recreates it after a 1s pause.
4. **Metrics server** (optional): if `SFTP_ENABLE_METRICS=yes`, `socat` listens on the address `sftp-reconciled init` derived from `SFTP_METRICS_BIND`, forking a `SYSTEM:/usr/local/bin/metrics.sh` process per scrape for true concurrency.
5. **sshd**: started in the background, stdout/stderr inherited directly, so the shell can still handle signals while `$!` still captures sshd's own PID.
6. **`sftp-reconciled watch`**: starts in the background (see Reconciliation Internals below). `entrypoint.sh` then blocks on `wait $SSHD_PID`, keeping itself as the main process for `tini` to track.

The Rust binary (`sftp-reconciled`, [`reconciled/src/`](./reconciled/src/)) is a single ~1200-line crate with one binary and two subcommands (`init`, `watch`):

| Module | Responsibility |
|---|---|
| `validate.rs` | Parses and validates every `SFTP_*`/`SSHD_*` env var into a `RuntimeConfig`; the `SFTP_AUTH_MODE` enum and its OR/AND parsing lives here |
| `render.rs` | Renders `/etc/ssh/sshd_config` from the template, substituting the `__PLACEHOLDER__` tokens |
| `config.rs` | Parses `sftp_users.conf` / `sftp_projects.conf` into typed records, collecting all parse errors instead of stopping at the first |
| `reconcile.rs` | Converges `/etc/passwd`, `/etc/shadow`, `/etc/group`, and `/sftp-jail/projects/` toward the parsed config. The only module that touches system state |
| `system.rs` | Low-level primitives `reconcile.rs` builds on (shadow-file editing, SHA-512 crypt, etc.) |

## Reconciliation Internals

`sftp-reconciled init` (strict) and `sftp-reconciled watch` (lenient) share the same `reconcile_users`/`reconcile_projects` logic in `reconcile.rs`, called with different failure modes. `init` aborts the container on any error, since bad config must not reach production. `watch` never takes the server down either: if the config fails parsing or the identity checks (`config::validate_identity_graph`), the whole pass is skipped and the previous state stays in force; a half-applied identity graph is worse than a stale one. Per-entry problems against the live system (a UID already taken by another account) are logged and that entry is skipped. Both paths load config through the same `load_config` function in `main.rs`.

Besides creating, `reconcile_projects` re-asserts each project directory's owner, group, mode and setgid bit through an `O_NOFOLLOW` descriptor (so a planted symlink is refused, not followed) and deletes the groups of undeclared projects, so removing a project revokes its members. `chmod 2770` silently loses the setgid bit when the process lacks `CAP_FSETID`, so the mode is read back and a mismatch is an error.

**Read-only accounts** are implemented as group membership plus one `Match` block, with no per-user sshd state. `reconcile_readonly_group` makes the members of the managed group `sftp_ro` (GID `SFTP_READONLY_GID`) exactly the users flagged `ro`, and `resources/sshd.conf` has `Match Group sftp_ro` with `ForceCommand internal-sftp -R ...`. A `Match` block overrides the global `ForceCommand`, and a drop-in cannot undo it because `ForceCommand` is rejected there. sshd resolves group membership at login, so a flag change applies to the account's next session with no sshd reload. Unlike the per-entry skipping above, a failure here is never silent: the group is a security control, so `init` aborts if it cannot be written, and in `watch` a GID or name collision is logged as an error each pass (the previous membership stays in force, so a newly flagged account stays writable until it is fixed). The group is exempt from `prune_stale_groups` and `reset_users` like `sftp_users`. Read-only is enforced by the SFTP server, not by file modes, so it also holds on filesystems that ignore POSIX permissions (for example Docker Desktop bind mounts).

`watch` registers a non-recursive `notify` (inotify) watcher on `/config` and reacts to any create/modify/close-write event whose path is `.generation` specifically, not every write to `/config`. That's why touching `.generation` is the documented way to force an immediate reconcile. Independent of that, it re-applies the current config file contents on every `SFTP_RECONCILE_INTERVAL` tick regardless of whether they changed. That's a deliberate simplification: reconciliation is idempotent, so periodic blind re-application is simpler and no less correct than diffing against the last-seen state, at the cost of a bit of redundant work every tick.

## sshd_config Include Ordering, in Depth

The README's [Configuration → SSH Configuration](./README.md#ssh-configuration) section covers the practical before/after split and the one thing you must not do in a drop-in. Here's the reasoning behind exactly where `Include /config/sshd_config.d/*.conf` sits in [`resources/sshd.conf`](./resources/sshd.conf).

OpenSSH applies directives first-match-wins within global scope, and `Match` blocks are evaluated in file order. So anything positioned *before* the Include in the base template is fixed regardless of what a drop-in says, and anything *after* it (including the base `Match Group sftp_users` block) can be overridden by a drop-in that comes earlier in the merged config. The security-critical directives (`ChrootDirectory`, `ForceCommand`, `AllowGroups`, `PermitRootLogin`, `PermitEmptyPasswords`, the cipher/KEX/MAC lists, host key directives) sit before the Include specifically so no drop-in, however well-intentioned, can weaken the jail. Everything else (`MaxStartups`, `StrictModes`, `UseDNS`, and the entire auth/session/banner `Match Group sftp_users` block) sits after, so operators can tune session limits, add `Match User`/`Match Group <project>` blocks, or swap `AuthorizedKeysFile` per group without patching the template.

This is also why a drop-in must never declare its own `Match Group sftp_users` block. Since the Include is evaluated before the base block reappears further down the merged file, a drop-in's block would take effect first and could override `ChrootDirectory`/`ForceCommand`, breaking the jail entirely. sshd doesn't warn about this, it just applies the first match it sees.

## Logging Pipeline Internals

`sshd` and `sftp-reconciled` need no special handling: they log to their own stdout/stderr, which `entrypoint.sh` inherits directly, and that's the end of it.

`internal-sftp` is the one exception, and the only reason any custom logging code exists in this project at all. It runs inside the chroot and can only log via glibc `syslog()` to `/dev/log`, a UNIX datagram socket, not a byte stream, with no newline terminator between messages and no "log to stdout" option. A supervised `socat -u UNIX-RECV:...` loop relays the raw datagrams out of the jail to an `awk` process, which frames them into plain lines: since there's no newline to split on, it sets `RS="<"` instead, because every syslog datagram begins with a `<priority>` marker, so splitting on `<` reconstructs message boundaries from the byte stream. Fragments that don't start with a digit (the priority number) are discarded, and the priority marker itself is stripped since it's meaningless outside the syslog transport (see below).

That's the full extent of it. The `<priority>` marker (`facility*8 + severity` per RFC 5424) is deliberately not decoded into a level, and the message text is not parsed for structure, timestamps, or session identifiers. Deriving that kind of structure is a log shipper's job: it belongs in an isolated, independently-failing component that can be reconfigured without a rebuild, not duplicated inside `entrypoint.sh`'s own process-supervision logic, where a parsing bug has outsized blast radius. See [examples/03-cloud-native](./examples/03-cloud-native) for a complete, tested example of that structuring done properly with Vector, and [README.md § Logging](./README.md#logging) for the plain-text format this pipeline produces.

## Design Decisions

The implementation (shell scripts, the Rust reconciler, Kubernetes manifests, tests, documentation) was written with heavy use of a coding LLM (Claude Code). Disclosed here plainly. The architecture and every decision below are the maintainer's, not the model's. The model wrote code against these decisions and helped find real bugs, but didn't choose the architecture:

- Native Unix permissions and groups as the entire access-control model, instead of a bespoke authorization layer
- No dynamic user management, on purpose. Config-file-driven and reconciled, not a runtime API
- Minimal attack surface: Wolfi base image, exactly three explicitly installed packages (`openssh-server`, `socat`, `tini`, not the full `openssh` meta-package, since the client and external `sftp-server` binaries are unused), shadow-utils avoided entirely
- `tini` as PID 1 for correct signal forwarding and zombie reaping
- Graceful shutdown (bounded SIGTERM drain) and SIGHUP reload without dropping active sessions
- Reconciliation implemented as a small Rust binary rather than shell text-munging of `/etc/passwd` and `/etc/shadow`
- The `sshd_config` `Include` ordering: precisely which directives drop-ins can and can't override, and why
- `SFTP_AUTH_MODE` as a single enum spanning nine pubkey/cert/password combinations, with OR and AND (2FA) semantics
- Plain-text logging with only the minimum custom plumbing `internal-sftp`'s syslog-only output leaves unavoidable, structure and shipping are a log pipeline's job, not this container's (see [examples/03-cloud-native](./examples/03-cloud-native) for the reasoning and a worked example)
