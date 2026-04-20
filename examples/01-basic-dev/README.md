# Basic Development Setup

Simple configuration using volume mounts for secrets. Good for local development and testing.

## Setup

1. **Generate SSH host key:**
```bash
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
```

2. **Generate user keys and create authorized_keys files:**
```bash
mkdir -p secrets

# Generate keys for Sheridan
ssh-keygen -t ed25519 -f secrets/sheridan_key -N ""
cat secrets/sheridan_key.pub > secrets/sheridan.authorized_keys

# Generate keys for Garibaldi
ssh-keygen -t ed25519 -f secrets/garibaldi_key -N ""
cat secrets/garibaldi_key.pub > secrets/garibaldi.authorized_keys
```

3. **Start the server:**
```bash
docker compose up -d
```

4. **Connect:**
```bash
# As Sheridan
sftp -P 2222 -i secrets/sheridan_key sheridan@localhost

# As Garibaldi
sftp -P 2222 -i secrets/garibaldi_key garibaldi@localhost
```

## File Structure

```
01-basic-dev/
├── compose.yml
├── secrets/
│   ├── ssh_host_ed25519_key          # Server's private key
│   ├── ssh_host_ed25519_key.pub      # Server's public key
│   ├── sheridan.authorized_keys      # Sheridan's public key
│   ├── garibaldi.authorized_keys     # Garibaldi's public key
│   ├── sheridan_key                  # Sheridan's private key (for connecting)
│   ├── sheridan_key.pub
│   ├── garibaldi_key                 # Garibaldi's private key (for connecting)
│   └── garibaldi_key.pub
└── data/
    └── station-ops/                  # Project directory (created automatically)
```

## Security Note

⚠️ **This example uses simple volume mounts for convenience.** Files are visible on the host filesystem and don't benefit from Docker's secret management. For production, see `02-docker-secrets` example.

## Users and Access

- **sheridan** (UID 1001) - Access to `station-ops`
- **garibaldi** (UID 1002) - Access to `station-ops`

Both users can read/write files in the shared `station-ops` project directory.
