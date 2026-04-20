# Cloud-Native Setup

Advanced configuration demonstrating cloud-native features: Prometheus metrics, log shipping to a real aggregator (Vector), custom SSH config overrides, and performance tuning.

## Features Demonstrated

- ✅ **Prometheus metrics** - Monitor connections, users, disk usage
- ✅ **Log shipping** - Vector reads the container's plain-text logs and structures them, not the container itself; see [Log Shipping](#log-shipping) below for why
- ✅ **Custom SSH config** - Override defaults without forking the entire config
- ✅ **Performance tuning** - Disable resets for faster restarts
- ✅ **Strict isolation** - Default 770 permissions (only project members can access)

## Setup

1. **Generate secrets:**
```bash
mkdir -p secrets

ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""

ssh-keygen -t ed25519 -f secrets/londo_key -N ""
cat secrets/londo_key.pub > secrets/londo.authorized_keys

ssh-keygen -t ed25519 -f secrets/vir_key -N ""
cat secrets/vir_key.pub > secrets/vir.authorized_keys
```

2. **Start services:**
```bash
docker compose up -d
```

3. **Access metrics:**
```bash
# Direct from SFTP container
curl http://localhost:9100/metrics

# Via Prometheus UI
open http://localhost:9090
```

4. **View logs, raw and structured:**
```bash
# Raw, plain text, straight from the container
docker compose logs sftp | tail -5

# Structured, after Vector has parsed it (see vector.toml)
tail -5 vector-output/sftp-structured.log
```

Raw output looks like this (see [README.md § Logging](../../README.md#logging) for the full format):
```
Accepted publickey for londo from 172.18.0.1 port 54321 ssh2: ED25519 SHA256:...
Sep 23 10:00:01 internal-sftp[42]: session opened for local user londo from [172.18.0.1]
```

Vector's structured output for the same two lines:
```json
{"timestamp":"2026-09-23T10:00:00.123Z","source":"sshd","level":"info","message":"Accepted publickey for londo from 172.18.0.1 port 54321 ssh2: ED25519 SHA256:..."}
{"timestamp":"2026-09-23T10:00:01.456Z","source":"sftp","level":"info","pid":42,"message":"session opened for local user londo from [172.18.0.1]"}
```

## Metrics Available

Access at `http://localhost:9100/metrics`:

```prometheus
# Active connections
sftp_active_connections 2

# Unique users online
sftp_active_users 2

# Disk usage
sftp_disk_used_kb 524288
sftp_disk_available_kb 10485760
sftp_disk_total_kb 20971520

# Per-project usage
sftp_project_disk_kb{project="centauri-republic"} 524288
```

## Prometheus Queries

In Prometheus UI (`http://localhost:9090`), try:

```promql
# Active connections over time
sftp_active_connections

# Disk usage percentage
(sftp_disk_used_kb / sftp_disk_total_kb) * 100

# Project disk usage
sftp_project_disk_kb
```

## Custom SSH Configuration

Edit `config/sshd_config.d/custom.conf` to override defaults:

```sshd
# Adjust connection limits
MaxStartups 50:80:100

# Support legacy clients (if needed)
PubkeyAcceptedKeyTypes ssh-ed25519,rsa-sha2-512
```

Changes take effect after reload:
```bash
docker compose exec sftp kill -HUP 1
```

## Performance Tuning

With `SFTP_RESET_USERS=no` and `SFTP_RESET_PROJECTS=no`:
- Container restarts are faster (no user/group cleanup)
- Suitable for large deployments with many users
- **Trade-off:** Manual cleanup needed if you remove users

## Log Shipping

This project deliberately does not structure or ship logs itself, it emits plain text and lets a real log pipeline handle the rest (see [ARCHITECTURE.md § Logging Pipeline Internals](../../ARCHITECTURE.md#logging-pipeline-internals) for the reasoning). `vector.toml` in this directory is a complete, tested example of what that looks like in practice:

- **Source**: `docker_logs`, reading the `sftp` container's stdout via the Docker Engine API. Needs read access to the Docker socket (`/var/run/docker.sock`, mounted read-only in `compose.yml`), the standard pattern for any log shipper reading container output this way. Scope it further with a socket proxy if you're not comfortable granting that directly in production.
- **Transform**: a `remap` (VRL) step that classifies each line by source (`sshd`, `sftp`, or `reconciled`, by text pattern), extracts the session `pid` from `internal-sftp`'s syslog header, and derives a coarse `level` from known prefixes (`fatal:`/`error:`/`debug*:` for OpenSSH, `Error:`/`Warning:` for `sftp-reconciled`).
- **Sinks**: a `file` sink (`vector-output/sftp-structured.log`, what `test.sh` asserts against) and a `console` sink for `docker compose logs vector`.

This isn't the only way to do it, Fluent Bit or a cloud provider's native log agent would work the same way, reading the same plain-text output. The point isn't Vector specifically, it's that structuring logs is the log pipeline's job, done once, centrally, with real parsing tools, not duplicated inside every container that happens to emit text.

## Production Considerations

For production deployments:

1. **External secrets** - Use Vault, AWS Secrets Manager, or K8s secrets
2. **Persistent volumes** - Use cloud block storage (EBS, GCE PD)
3. **Monitoring** - Configure Prometheus alerts for disk usage, connection limits
4. **Backup** - Implement automated backups of `/sftp-jail/projects`
5. **Rate limiting** - Use cloud firewall rules or fail2ban (external)
6. **Log shipper socket access** - Scope Docker socket access for your log shipper (a proxy like `docker-socket-proxy`, or your platform's native log agent instead of `docker_logs`) rather than mounting it directly, as this example does for simplicity
