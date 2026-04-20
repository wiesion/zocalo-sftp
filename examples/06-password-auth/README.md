# Password Authentication

This example demonstrates `SFTP_AUTH_MODE: password`. Users authenticate with a plaintext password stored as a Docker secret. No SSH keys are required or accepted.

## When to Use Password Auth

Password auth is the simplest setup for clients that do not support SSH key management: legacy tools, certain FTP-to-SFTP migration paths, or environments where distributing keys to end users is impractical. For all other cases, `pubkey` mode is preferred.

## How It Works

At container start, the entrypoint reads each user's password from `/run/secrets/<username>.password` and applies it via `chpasswd`. The password is stored in `/etc/shadow` inside the container for the lifetime of that container.

**Important:** Changing a password secret does not take effect until the container is restarted. SIGHUP reloads the SSH configuration but does not re-run `chpasswd`.

## Setup

### 1. Generate SSH host key

```bash
mkdir -p secrets
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
```

### 2. Create password secrets

```bash
printf 'minbari-temporal' > secrets/delenn.password
printf 'nightwatch-2258'  > secrets/marcus.password
```

Passwords are plaintext files. Avoid trailing newlines, use `printf` rather than `echo`.

### 3. Start the server

```bash
docker compose up -d
```

### 4. Connect

```bash
sftp -P 2222 delenn@localhost
# Enter password when prompted: minbari-temporal

sftp -P 2222 marcus@localhost
# Enter password when prompted: nightwatch-2258
```

Most SFTP clients (FileZilla, WinSCP, Cyberduck) support password authentication natively. For scripted access, consider using `sshpass` or `expect`.

## Security Considerations

Password authentication is inherently weaker than public key authentication:

- Passwords can be brute-forced. Keep `MaxAuthTries` low (default is 3).
- This container does not include IP banning. Run fail2ban as a sidecar or enforce firewall rules from outside.
- Password secrets are stored in plaintext on the host. Protect the secrets directory with filesystem permissions.
- Use strong, unique passwords. A minimum of 16 random characters is recommended.
- Consider `pubkey,password` (2FA) instead of `password` alone for sensitive deployments. See `07-2fa`.

## File Structure

```
06-password-auth/
├── compose.yml
├── secrets/
│   ├── ssh_host_ed25519_key    # Server's private host key
│   ├── delenn.password         # Delenn's plaintext password
│   └── marcus.password         # Marcus's plaintext password
└── data/
    └── minbari-ops/
```

## Users and Access

- **delenn** (UID 1001): access to `minbari-ops`
- **marcus** (UID 1002): access to `minbari-ops`
