# Two-Factor Authentication (pubkey + password)

This example demonstrates `SFTP_AUTH_MODE: pubkey,password`. Users must supply **both** a valid ed25519 public key **and** the correct password in the same session. Either factor alone is insufficient.

## How It Works

OpenSSH's `AuthenticationMethods publickey,password` requires the client to complete two sequential authentication steps:

1. **Public key**: the client proves possession of the private key matching the server's `authorized_keys` entry.
2. **Password**: the client then provides the correct password.

Both must succeed. If either fails, the connection is rejected.

## Setup

### 1. Generate SSH host key

```bash
mkdir -p secrets
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
```

### 2. Generate user keys and create authorized_keys files

```bash
ssh-keygen -t ed25519 -f secrets/zathras_key -N "" -C "zathras@great-machine"
cat secrets/zathras_key.pub > secrets/zathras.authorized_keys

ssh-keygen -t ed25519 -f secrets/corwin_key -N "" -C "corwin@babylon5"
cat secrets/corwin_key.pub > secrets/corwin.authorized_keys
```

### 3. Create password secrets

```bash
printf 'it-is-the-one' > secrets/zathras.password
printf 'alpha-channel' > secrets/corwin.password
```

### 4. Start the server

```bash
docker compose up -d
```

### 5. Connect

The SSH client handles the two-step sequence automatically. From the terminal:

```bash
sftp -P 2222 -i secrets/zathras_key zathras@localhost
# Key auth succeeds silently, then:
# zathras@localhost's password: it-is-the-one
```

**Note:** Many GUI clients (FileZilla, WinSCP) support keyboard-interactive authentication, which is how the password prompt appears after key auth. Enable "keyboard-interactive" in the client's auth settings if prompted.

## What Is Rejected

| Attempt                             | Result   |
|-------------------------------------|----------|
| Correct key + correct password      | Accepted |
| Correct key + wrong password        | Rejected |
| Correct key, no password attempt    | Rejected |
| No key (password-only attempt)      | Rejected |
| Wrong key + correct password        | Rejected |

## When to Use 2FA

Use `pubkey,password` when you need an extra layer of assurance that a stolen private key alone cannot grant access. Typical scenarios:

- Sensitive data repositories where both the key file and the password must be compromised
- Compliance requirements mandating multi-factor authentication for file transfer systems
- High-value accounts where the operational overhead of a second factor is justified

For most deployments, `pubkey` alone with strong key management is sufficient.

## File Structure

```
07-2fa/
├── compose.yml
├── secrets/
│   ├── ssh_host_ed25519_key       # Server's private host key
│   ├── zathras.authorized_keys    # Zathras's public key
│   ├── zathras.password           # Zathras's password
│   ├── zathras_key                # Zathras's private key (for connecting)
│   ├── corwin.authorized_keys     # Corwin's public key
│   ├── corwin.password            # Corwin's password
│   └── corwin_key                 # Corwin's private key (for connecting)
└── data/
    └── great-machine/
```

## Users and Access

- **zathras** (UID 1001): access to `great-machine`; requires key + password
- **corwin** (UID 1002): access to `great-machine`; requires key + password
