# Docker Secrets (Production-Ready)

Uses Docker Compose secrets for proper secret management. Recommended for production deployments.

## Setup

1. **Generate SSH host key:**
```bash
mkdir -p secrets
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
```

2. **Generate user keys:**
```bash
# Kosh (Vorlon Ambassador)
ssh-keygen -t ed25519 -f secrets/kosh_key -N ""
cat secrets/kosh_key.pub > secrets/kosh.authorized_keys

# Lennier (Minbari Attaché)
ssh-keygen -t ed25519 -f secrets/lennier_key -N ""
cat secrets/lennier_key.pub > secrets/lennier.authorized_keys

# Talia (Telepath)
ssh-keygen -t ed25519 -f secrets/talia_key -N ""
cat secrets/talia_key.pub > secrets/talia.authorized_keys
```

3. **Start the server:**
```bash
docker compose up -d
```

4. **Connect:**
```bash
# As Kosh
sftp -P 2222 -i secrets/kosh_key kosh@localhost

# As Lennier
sftp -P 2222 -i secrets/lennier_key lennier@localhost

# As Talia
sftp -P 2222 -i secrets/talia_key talia@localhost
```

## Project Access

### vorlon-archives (GID 2001)
- **kosh** - Full access
- **lennier** - Full access

### psi-corps (GID 2002)
- **talia** - Full access

## Advantages of Docker Secrets

* ✅ **Better isolation** - Secrets mounted via tmpfs, not visible on host
* ✅ **Permission management** - Docker handles proper file permissions
* ✅ **Rotation support** - Compatible with Docker Swarm secret rotation
* ✅ **Audit trail** - Secret access tracked by Docker daemon
* ✅ **Production-ready** - Industry best practice

## File Structure

```
02-docker-secrets/
├── compose.yml
├── secrets/
│   ├── ssh_host_ed25519_key
│   ├── kosh.authorized_keys
│   ├── lennier.authorized_keys
│   ├── talia.authorized_keys
│   ├── kosh_key                      # Client keys (for testing)
│   ├── lennier_key
│   └── talia_key
└── data/
    ├── vorlon-archives/              # Shared by kosh & lennier
    └── psi-corps/                    # Only talia
```

## Migration to Production

For Kubernetes or Docker Swarm, replace `file:` with external secrets:

```yaml
secrets:
  ssh_host_ed25519_key:
    external: true
  kosh.authorized_keys:
    external: true
```
