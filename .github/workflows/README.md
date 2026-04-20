# GitHub Actions Workflows

This directory contains CI automation for Zocalo SFTP: a validation workflow
(`ci.yml`) that runs on every push/PR, and a release workflow (`release.yml`)
that publishes to [Docker Hub](https://hub.docker.com/r/wiesion/zocalo-sftp).
You can also build the image yourself; see
[Build & Publish](../../README.md#build--publish) in the main README.

## CI (`ci.yml`)

**Triggers:** Every push to `main` and all pull requests targeting `main`

### `lint`

Runs ShellCheck on every shell script in the repository. Fails on warnings or
above. ShellCheck derives the shell dialect from each script's shebang
(`#!/bin/sh` vs `#!/bin/bash`).

Files checked: `resources/entrypoint.sh`, `resources/metrics.sh`,
`examples/lib/test-helpers.sh`, `examples/09-kubernetes/lib-k8s.sh`, all
`examples/*/test.sh` and `examples/*/setup.sh`.

### `rust-checks`

`cargo fmt --check`, `cargo clippy --all-targets --locked -- -D warnings`, and
`cargo audit` against `reconciled/Cargo.lock`. Static checks for the
`sftp-reconciled` binary (config validation, sshd_config rendering, user/project
reconciliation).

### `build-and-scan`

1. Build Docker image locally (with GHA layer cache), never pushed anywhere
2. Generate SBOM using Syft, SPDX and CycloneDX formats (with the
   `rust-cargo-lock-cataloger` enabled so the Rust dependency tree is included
   alongside the apk packages)
3. Scan for vulnerabilities using Grype against the generated SBOM, fails on
   high/critical CVEs with fixes available
4. Upload SBOM and vulnerability report as workflow artifacts
5. Smoke test: start a minimal container from a mounted config directory, wait
   for the built-in HEALTHCHECK to pass, then tear it down

**Artifacts:**
- `sbom`: SPDX and CycloneDX SBOM files
- `vulnerability-report`: JSON and text vulnerability reports

### `integration-tests` (matrix)

Runs after `build-and-scan` passes. Launches one job per example (01 through
08), each on its own runner, so there are no port conflicts and all run in
parallel. `fail-fast: false` means a failure in one example does not cancel the
others.

Each job restores the image from the GHA layer cache (populated by
`build-and-scan`, close to instant), sets `SFTP_IMAGE=zocalo-sftp:test` so
`docker compose` uses the cached image instead of building or pulling
anything, then runs `./test.sh`.

### `kubernetes-test`

Separate from `integration-tests`: different tooling (`kind`/`kubectl`, not
Docker Compose) and stands up a real disposable Kubernetes cluster with Calico
for actual NetworkPolicy enforcement. See
[examples/09-kubernetes/README.md](../../examples/09-kubernetes/README.md).

---

## Release (`release.yml`)

**Triggers:** a version tag push (`v*.*.*`), a nightly cron (`0 3 * * *`), or a manual `workflow_dispatch`.

Every trigger runs the same gate first: `test` (build, SBOM, Grype scan, smoke test), then `integration-tests` and `kubernetes-test` in parallel. Nothing publishes until all three pass, same philosophy as `ci.yml`, reused here for the publish path instead of just validation.

The `publish` job (needs all three gates) builds `linux/amd64,linux/arm64`, signs the manifest digest with keyless Cosign (GitHub OIDC, no extra secret needed), and generates a fresh SBOM/vulnerability report for the actual published digest. What gets tagged depends on the trigger:

| Trigger | Tags pushed | `latest` moves? | GitHub Release created? |
|---|---|---|---|
| `v1.2.3` tag push | `v1.2.3`, `v1.2`, `v1`, `latest` | Yes | Yes, with SBOM/vuln report attached |
| Nightly cron / manual dispatch | `nightly`, `nightly-YYYYMMDD` | No | No, uploaded as a workflow artifact instead |

`latest` only moves on a human-initiated tag push. A nightly run that happens to hit a CVE in a newly-rebuilt Wolfi layer fails loud in the Actions tab (GitHub emails scheduled-workflow-failure notifications by default) without ever touching what most users actually pull.

**Required repository secrets** (Settings → Secrets and variables → Actions):
- `DOCKERHUB_USERNAME`: your Docker Hub username
- `DOCKERHUB_TOKEN`: a Docker Hub access token scoped to this repository, read/write (delete is never needed for CI)

---

## Image injection (`SFTP_IMAGE`)

Example `compose.yml` files use:

```yaml
image: ${SFTP_IMAGE:-wiesion/zocalo-sftp:latest}
```

| Context | Value | Effect |
|---|---|---|
| CI (`integration-tests` job) | `zocalo-sftp:test` (pre-set) | Uses the locally cached test build |
| Local `./test.sh` | not set → set by `docker_build` | Builds locally, exports `SFTP_IMAGE` |
| Local `./setup.sh` | not set | Builds via compose `build:` context |
| Testing your own build | `myregistry/zocalo-sftp:1.2.3` | `SFTP_IMAGE=myregistry/zocalo-sftp:1.2.3 ./test.sh` |

---

## Local usage

### Run a single example test

```bash
cd examples/01-basic-dev
./test.sh
```

### Run all example tests locally (sequential)

```bash
for dir in examples/0*/; do
    echo "=== $dir ==="
    (cd "$dir" && ./test.sh) || echo "FAILED: $dir"
done
```

### Trigger CI manually

```bash
gh workflow run ci.yml
```

---

## Security scanning

### Syft (SBOM)

Generates a full inventory of all packages in the image: OS packages,
language dependencies, file metadata. Published in SPDX and CycloneDX
formats. For a local build, use `./scripts/generate-sbom.sh` instead of
calling Syft directly, since it already enables the Rust cataloger this project
needs.

### Grype (vulnerability scan)

Scans against CVE, GitHub Security Advisories, and OS-specific feeds.
`--fail-on high --only-fixed` (as used in `ci.yml`) fails the build only on
high/critical CVEs that can actually be resolved by updating packages;
unfixed CVEs are reported but don't block.

---

## Dependabot

`dependabot.yml` keeps GitHub Actions versions, the Docker base image, and
`reconciled`'s Rust dependencies up to date automatically (weekly schedule,
`ci:` / `docker:` / `cargo:` commit prefixes).
