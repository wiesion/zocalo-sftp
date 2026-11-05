# Zocalo SFTP

Hardened SFTP server for container environments, built on [Wolfi](https://github.com/wolfi-dev). Access control uses native Linux groups and file permissions instead of a database or virtual-user layer. Users and projects are declared in mounted config files, and the container reconciles itself to match.

**Full usage, configuration and examples: https://github.com/wiesion/zocalo-sftp#readme**

## Tags

- `latest`, `nightly`: rebuilt every night from `main` on the latest Wolfi base, gated by the full test suite and a vulnerability scan. Code on `main` rarely changes; the nightly rebuild is what keeps base-image fixes flowing. Recommended for most users.
- `nightly-YYYYMMDD`: a specific night's build; pin one of these (or an image digest) if you need reproducibility without going stale
- `X.Y.Z`, `X.Y`, `X`: snapshots from tagged releases. They are not rebuilt, so they stop receiving base-image updates

Platforms: `linux/amd64`, `linux/arm64`. Also published as `ghcr.io/wiesion/zocalo-sftp`.

## Before you run it

- The container needs a specific set of Linux capabilities and a host key secret; it will not start correctly with defaults alone. Use the compose file in the [Quick Start](https://github.com/wiesion/zocalo-sftp#quick-start) as your starting point.
- Users and projects come from mounted config files (`/config`), not environment variables.
- Mount a volume at `/sftp-jail/projects` for persistent data.
- Ports: `22` (SFTP), `9100` (Prometheus metrics, opt-in).

## Verifying images

Images are signed with keyless Cosign, and each [GitHub release](https://github.com/wiesion/zocalo-sftp/releases) ships an SBOM and vulnerability report:

```bash
cosign verify wiesion/zocalo-sftp:latest \
  --certificate-identity-regexp="https://github.com/wiesion/zocalo-sftp/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

## Links

- [Documentation](https://github.com/wiesion/zocalo-sftp#readme)
- [Examples](https://github.com/wiesion/zocalo-sftp/tree/main/examples)
- [Security policy](https://github.com/wiesion/zocalo-sftp/blob/main/SECURITY.md)
- [Issues and pull requests](https://github.com/wiesion/zocalo-sftp)

License: MIT
