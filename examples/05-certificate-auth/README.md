# Certificate-Based Authentication

This example demonstrates SSH certificate authentication using `SFTP_AUTH_MODE: cert`. Instead of managing per-user authorized_keys files, you create a Certificate Authority (CA) and sign user certificates with it. The server trusts the CA, so any certificate signed by it is accepted and no per-user secrets are needed.

## How It Works

1. You generate a CA keypair once. The private key stays offline and secure.
2. You sign each user's public key with the CA private key to produce a certificate.
3. The CA public key (`ssh_user_ca.pub`) is mounted to the container as a Docker secret.
4. When a user connects, they present their certificate alongside their private key. OpenSSH validates the certificate signature against the CA, confirms the certificate principal matches the login username, and checks it hasn't expired.

No per-user authorized_keys are needed. All access control flows through the CA.

## Benefits over authorized_keys

- **No per-user secrets on the server**: one CA public key covers all users
- **Time-limited access**: certificates carry a built-in expiry (`-V +52w`)
- **Instant revocation**: rotate the CA and all old certificates become invalid
- **Principal enforcement**: a certificate is only valid for the username it was signed for
- **Scales with identity providers**: fits naturally into centralized PKI workflows

## Setup

### 1. Generate SSH host key

```bash
mkdir -p secrets
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
```

### 2. Create a Certificate Authority

```bash
# Generate the CA keypair. Keep the private key SECURE and OFFLINE.
ssh-keygen -t ed25519 -f secrets/ssh_user_ca -N "" -C "Zocalo SFTP User CA"

# The public key is mounted to the container; the private key is used only for signing.
```

### 3. Generate and sign user certificates

```bash
# Sheridan's keypair
ssh-keygen -t ed25519 -f secrets/sheridan_key -N "" -C "sheridan@babylon5"

# Sign Sheridan's public key with the CA.
#   -s  CA private key
#   -I  certificate identity (any label)
#   -n  principal, must match the Unix login username exactly
#   -V  validity period
ssh-keygen -s secrets/ssh_user_ca \
  -I "sheridan-2026" \
  -n "sheridan" \
  -V +52w \
  secrets/sheridan_key.pub
# Produces secrets/sheridan_key-cert.pub

# Ivanova's keypair and certificate
ssh-keygen -t ed25519 -f secrets/ivanova_key -N "" -C "ivanova@babylon5"
ssh-keygen -s secrets/ssh_user_ca \
  -I "ivanova-2026" \
  -n "ivanova" \
  -V +52w \
  secrets/ivanova_key.pub
```

### 4. Start the server

```bash
docker compose up -d
```

### 5. Connect

Users connect with their private key. SSH finds the matching certificate automatically (looks for `<key>-cert.pub` alongside the private key):

```bash
sftp -P 2222 -i secrets/sheridan_key sheridan@localhost
sftp> cd station-ops
sftp> put report.txt

sftp -P 2222 -i secrets/ivanova_key ivanova@localhost
```

## Certificate Inspection

```bash
ssh-keygen -L -f secrets/sheridan_key-cert.pub
```

```
secrets/sheridan_key-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com user certificate
        Public key: ED25519-CERT SHA256:...
        Signing CA: ED25519 SHA256:... (using ssh-ed25519)
        Key ID: "sheridan-2026"
        Serial: 0
        Valid: from 2026-03-04T00:00:00 to 2027-03-04T00:00:00
        Principals:
                sheridan
        Critical Options: (none)
        Extensions:
                permit-pty
                permit-user-rc
```

## Fine-Grained Principal Control (Drop-in)

The `SFTP_AUTH_MODE: cert` setting enables certificate auth globally. If you need per-user principal constraints beyond the default (principal must match login username), mount a drop-in configuration:

```yaml
volumes:
  - ./config/sshd_config.d:/config/sshd_config.d:ro
```

Then add a file like `config/sshd_config.d/01-principals.conf`:

```sshd
# Accept certificates whose principal matches entries in a per-user file
AuthorizedPrincipalsFile /run/secrets/%u.principals

# Or use a command to dynamically resolve valid principals
# AuthorizedPrincipalsCommand /usr/local/bin/check-principals %u %k
```

This is the intended extension point for PKI integrations. See `config/sshd_config.d/certificates.conf` in this example directory for the reference snippet.

## Revoking Access

To revoke all certificates:
1. Generate a new CA keypair
2. Re-sign certificates only for users who should retain access
3. Update the `ssh_user_ca.pub` secret and restart (or SIGHUP) the container

Certificates signed by the old CA become invalid immediately. For per-certificate revocation without rotating the CA, use `RevokedKeys` with a KRL file via a drop-in.

## Security Considerations

**Protect the CA private key:**
- Store offline in a secure location
- Use a strong passphrase
- Never mount the CA private key to the container. Only `ssh_user_ca.pub` goes to the server

**Certificate validity:**
- Use short validity periods (`-V +52w` = 52 weeks; shorter is safer)
- Set a calendar expiry rather than a relative period if you want predictable revocation dates (`-V 20260101:20270101`)

**Principals:**
- Always set `-n username` to match the Unix username exactly
- Without a matching principal, the certificate is rejected
- One certificate, one username: prevents lateral movement

## File Structure

```
05-certificate-auth/
├── compose.yml
├── config/
│   └── sshd_config.d/
│       └── certificates.conf        # Reference drop-in (AuthorizedPrincipalsFile)
├── secrets/
│   ├── ssh_host_ed25519_key         # Server's private host key
│   ├── ssh_user_ca                  # CA private key (KEEP OFFLINE, not mounted)
│   ├── ssh_user_ca.pub              # CA public key (mounted as Docker secret)
│   ├── sheridan_key                 # Sheridan's private key (for connecting)
│   ├── sheridan_key.pub
│   ├── sheridan_key-cert.pub        # Sheridan's signed certificate
│   ├── ivanova_key
│   ├── ivanova_key.pub
│   └── ivanova_key-cert.pub
└── data/
    └── station-ops/
```

## Comparison with authorized_keys

| Aspect           | `pubkey` mode                | `cert` mode                        |
|------------------|------------------------------|------------------------------------|
| Server secrets   | One per user (`username.authorized_keys`) | One for all users (`ssh_user_ca.pub`) |
| Key distribution | Add key to server config     | Sign with CA (no server change)    |
| Revocation       | Remove key from authorized_keys | Rotate CA or use KRL              |
| Expiry           | Manual rotation              | Automatic (built into certificate) |
| Principal check  | N/A                          | Certificate principal = username   |
| Best for         | Small teams, simple setups   | Organizations, time-limited access |
