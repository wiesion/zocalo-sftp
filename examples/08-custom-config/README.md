# Custom sshd_config Drop-ins

This example demonstrates how to extend the base SSH configuration using drop-in files. Drop-ins let you override session limits, tune keepalive intervals, or add per-group and per-user `Match` blocks, all without touching the base image or environment variables.

## The Drop-in Mechanism

Mount a directory of `*.conf` files at `/config/sshd_config.d/`:

```yaml
volumes:
  - ./config/sshd_config.d:/config/sshd_config.d:ro
```

Files are processed in alphanumerical order. The `Include /config/sshd_config.d/*.conf` directive is placed in the base `sshd_config` **before** the `Match Group sftp_users` block. Because OpenSSH uses **first-match-wins** semantics, a directive set in a drop-in takes precedence over the same directive in the fallback `Match Group sftp_users` block that follows.

### What drop-ins can override

Any directive that appears after the `Include` in the base config:

- Global tuning: `MaxStartups`, `StrictModes`, `UseDNS`
- Everything in `Match Group sftp_users`: `MaxAuthTries`, `MaxSessions`, `ClientAliveInterval`, `ClientAliveCountMax`, `Banner`, `AuthorizedKeysFile`, and all authentication directives

### What drop-ins cannot override

Directives placed before the `Include` are immutable by design:

- `AllowGroups`, `PermitRootLogin`, `PermitEmptyPasswords`
- `KexAlgorithms`, `Ciphers`, `MACs`
- `ChrootDirectory`, `ForceCommand`
- Host key and key exchange directives

### Warning: do not add `Match Group sftp_users` in a drop-in

The base `Match Group sftp_users` block sets `ChrootDirectory` and `ForceCommand`. If a drop-in contains a `Match Group sftp_users` block, it is evaluated first (Include is processed first), which can inadvertently override the chroot and break the SFTP jail. Use a different group name in your drop-in `Match` blocks instead. The project group name works well for this (see below).

## This Example's Drop-ins

### `01-global.conf`: global tuning

```sshd
MaxStartups 5:30:50
```

Tightens the unauthenticated connection queue for this deployment. Applied globally before any `Match` block.

### `02-media-team.conf`: per-project group overrides

```sshd
Match Group media-team
    MaxSessions 5
    ClientAliveInterval 600
    ClientAliveCountMax 3
    MaxAuthTries 6
```

`media-team` is a project group defined in `config/sftp_projects.conf`. Its members transfer large files and keep long-running sessions, so they get relaxed limits. This block takes precedence over the base `Match Group sftp_users` defaults because the `Include` is processed first.

**Note:** The group name in `Match Group` must match the Linux group name, which is the project name you define in `sftp_projects.conf`. There is no additional configuration required to make this work.

### `03-strict-user.conf`: per-user overrides

```sshd
Match User morden
    MaxAuthTries 1
```

A single failed authentication attempt closes the connection for `morden`. Per-user `Match User` blocks work the same way: they are evaluated via the drop-in `Include` before the base `Match Group sftp_users` block.

## Per-Group Authentication Overrides

Drop-in `Match` blocks can also override authentication settings for specific groups. For example, to require certificates for a specific project group while the rest of the server uses pubkey auth:

```sshd
# config/sshd_config.d/02-csuite.conf
Match Group csuite
    AuthorizedKeysFile none
    TrustedUserCAKeys /run/secrets/ssh_user_ca.pub
```

Or to point a group at a different authorized_keys path:

```sshd
Match Group ops-team
    AuthorizedKeysFile /run/secrets/%u.authorized_keys /run/secrets/ops-team-shared.pub
```

These overrides are evaluated before the global auth settings from `SFTP_AUTH_MODE`, giving you fine-grained control per project group without changing the container's environment variables.

## Setup

### 1. Generate SSH host key

```bash
mkdir -p secrets
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
```

### 2. Generate user keys

```bash
for user in bester zack morden; do
    ssh-keygen -t ed25519 -f "secrets/${user}_key" -N "" -C "${user}@babylon5"
    cat "secrets/${user}_key.pub" > "secrets/${user}.authorized_keys"
done
```

### 3. Start the server

```bash
docker compose up -d
```

### 4. Connect

```bash
sftp -P 2222 -i secrets/bester_key bester@localhost
sftp -P 2222 -i secrets/zack_key   zack@localhost
sftp -P 2222 -i secrets/morden_key morden@localhost
```

## File Structure

```
08-custom-config/
├── compose.yml
├── config/
│   └── sshd_config.d/
│       ├── 01-global.conf       # Global MaxStartups override
│       ├── 02-media-team.conf   # Per-group session limits
│       └── 03-strict-user.conf  # Per-user MaxAuthTries
├── secrets/
│   ├── ssh_host_ed25519_key
│   ├── bester.authorized_keys
│   ├── zack.authorized_keys
│   └── morden.authorized_keys
└── data/
    ├── media-team/
    └── shadow-council/
```

## Users and Access

- **bester** (UID 1001): access to `media-team`; gets relaxed session limits via `02-media-team.conf`
- **zack** (UID 1002): access to `media-team`; same relaxed limits
- **morden** (UID 1003): access to `shadow-council`; only 1 auth attempt via `03-strict-user.conf`

## Naming Convention

The numeric prefix on drop-in filenames controls evaluation order (alphanumerical sort). A suggested convention:

| Range    | Purpose                                |
|----------|----------------------------------------|
| `01-`    | Global directives (no `Match` block)   |
| `02-09-` | Per-group `Match Group` overrides      |
| `10-19-` | Per-user `Match User` overrides        |
| `20-`    | Per-address `Match Address` rules      |
