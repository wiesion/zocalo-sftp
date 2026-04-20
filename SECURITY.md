# Security Policy

## Reporting a Vulnerability

Use GitHub's **Private Vulnerability Reporting** rather than opening a public issue: go to the **Security** tab on this repo → **Report a vulnerability**. This creates a private draft security advisory visible only to you and the maintainers, and nothing is public until a fix is coordinated and released.

Include:

- A description of the issue and its potential impact
- Steps to reproduce (config files, compose setup, or commands used)
- The image digest or commit SHA you tested against

Expect an acknowledgment within 5 business days. We'll work with you on a fix and coordinate disclosure timing before anything is made public.

If the Security tab doesn't show a "Report a vulnerability" option, private reporting hasn't been enabled yet for this repo. Open a regular issue asking the maintainers to enable it (without vulnerability details) and we'll turn it on.

## Supported Versions

Only the latest tagged release (`wiesion/zocalo-sftp:latest`) receives security fixes; older tags are not patched retroactively, re-pull the latest instead. `wiesion/zocalo-sftp:nightly` tracks Wolfi's continuously-rebuilt base directly and has no separate support window, if it's currently green in [the release workflow](./.github/workflows/release.yml), it's current by construction.

## Scope

In scope: the container image (`Dockerfile`, `resources/`), the `sftp-reconciled` Rust binary (`reconciled/`), the example deployment manifests (`examples/`), and the published `wiesion/zocalo-sftp` image itself.

Out of scope: vulnerabilities in the upstream `wolfi-base` image or `openssh-server` package itself. Report those to [Chainguard](https://github.com/chainguard-images/wolfi-base) or the [OpenSSH project](https://www.openssh.com/security.html) directly. Run `./scripts/generate-sbom.sh` against your build to check exactly what's in your image.

## What This Project Does Not Cover

As noted in the README's [Security](./README.md#security) section, this project has no built-in intrusion detection, IP banning, or rate limiting. Brute-force protection, anomaly detection, and firewall rules are the operator's responsibility. See [What This Is (and Isn't)](./README.md#what-this-is-and-isnt).
