# Zocalo SFTP Examples

This directory contains examples demonstrating different deployment scenarios for Zocalo SFTP.

## Available Examples

| Example               | Description                     | Features                                                  |
|-----------------------|---------------------------------|-----------------------------------------------------------|
| `01-basic-dev`        | Simple development setup        | Volume mounts, basic auth                                 |
| `02-docker-secrets`   | Production-ready secrets        | Docker Compose secrets                                    |
| `03-cloud-native`     | Cloud deployment                | Metrics, log shipping to Vector, health checks             |
| `04-multi-project`    | Complex access patterns         | Multiple users and projects, isolation                    |
| `05-certificate-auth` | SSH certificates                | CA-based authentication                                   |
| `06-password-auth`    | Password authentication         | `SFTP_AUTH_MODE=password`, username.password secrets      |
| `07-2fa`              | Two-factor authentication       | `SFTP_AUTH_MODE=pubkey,password`, key + password required |
| `08-custom-config`    | Drop-in sshd_config.d overrides | Per-group and per-user limits via mounted config files    |
| `09-kubernetes`       | Kubernetes deployment           | StatefulSet, split liveness/readiness probes, NetworkPolicy (kind + Calico) |
| `10-security-boundary`| Adversarial tests               | Hostile config, hostile client, drift repair, lifecycle revocation |

**Note on `09-kubernetes`:** it's the odd one out. Kubernetes (kind + Calico), not Docker Compose, so it doesn't use `lib/test-helpers.sh`'s Docker-specific functions and isn't part of the quick Compose-only loop below. See its own [README](./09-kubernetes/README.md). It also takes noticeably longer to run (a couple of minutes) since `test.sh`/`setup.sh` each stand up and tear down a disposable Kubernetes cluster.

## Automated Testing

Each example includes two automation scripts:

### `test.sh` - Automated Testing

Runs a complete test suite that:
- Builds the Docker image from the parent directory
- Generates all required keys/secrets
- Starts the services
- Runs automated tests (authentication, file operations, permissions)
- Cleans up everything
- Exits with status code (0 = success, 1 = failure)

**Usage:**
```bash
cd examples/01-basic-dev
./test.sh
```

**Example output:**
```
▶ Starting tests for 01-basic-dev

▶ Cleaning up previous runs
✓ Cleanup complete

▶ Preparing environment
✓ Image built: zocalo-sftp:test
✓ Services are running

▶ Running test cases
→ User sheridan can authenticate... PASS
→ User garibaldi can authenticate... PASS
→ User sheridan sees station-ops project... PASS
→ User garibaldi sees station-ops project... PASS
→ User sheridan can upload file to station-ops... PASS
→ User sheridan can download file from station-ops... PASS
→ Downloaded file has correct content... PASS
→ User sheridan can delete file from station-ops... PASS
→ User sheridan uploads shared file... PASS
→ User garibaldi can see file uploaded by sheridan... PASS
→ User garibaldi can download file from sheridan... PASS
→ User garibaldi can delete file from sheridan... PASS

Test Summary:
  Total:  12
  Passed: 12
```

### `setup.sh` - Interactive Exploration

Sets up the environment for manual testing:
- Builds the Docker image
- Generates all required keys/secrets
- Starts the services
- Displays connection instructions
- Keeps services running for manual exploration
- Cleans up when you press Ctrl+C

**Usage:**
```bash
cd examples/01-basic-dev
./setup.sh
```

**Example output:**
```
▶ Setting up 01-basic-dev for interactive exploration

▶ Cleaning up previous runs
✓ Cleanup complete

▶ Generating SSH keys
✓ Generated keys for sheridan
✓ Generated keys for garibaldi

▶ Building Docker image
✓ Image built: zocalo-sftp:test

▶ Starting services with docker compose
✓ Services are running

▶ Connection Information

Use these commands to connect:

  # As sheridan
  sftp -P 2222 -i secrets/sheridan_key sheridan@localhost

  # As garibaldi
  sftp -P 2222 -i secrets/garibaldi_key garibaldi@localhost

Press Ctrl+C when done to clean up

ℹ Services are running. Press Ctrl+C to stop and cleanup.
```

## Running All Tests

To run all example tests in sequence:

```bash
#!/bin/bash
# Run from examples directory
for dir in 01-* 02-* 03-* 04-* 05-* 06-* 07-* 08-*; do
    echo "Testing $dir..."
    (cd "$dir" && ./test.sh) || echo "FAILED: $dir"
done
```

`09-kubernetes` is deliberately excluded from that loop (different tooling, longer runtime, see the note above); run it separately with `(cd 09-kubernetes && ./test.sh)` once `kind` and `kubectl` are installed.

## Test Features

The test scripts validate:

### Authentication
- ✓ Users can authenticate with their credentials
- ✓ Invalid credentials are rejected

### Project Visibility
- ✓ Users see only their assigned projects
- ✓ Project isolation is enforced

### File Operations
- ✓ Upload files to projects
- ✓ Download files from projects
- ✓ Delete files from projects
- ✓ File content integrity

### Collaboration
- ✓ Users can share files in common projects
- ✓ Cross-user file access in shared projects

### Example-Specific Tests

**03-cloud-native:**
- ✓ Metrics endpoint responds on :9100
- ✓ Metrics contain expected data
- ✓ Vector ships and structures container logs (source, level, sftp session pid)
- ✓ Health check status

**04-multi-project:**
- ✓ Complex access matrix validation
- ✓ Multi-project isolation
- ✓ Exclusive project access

**05-certificate-auth:**
- ✓ Certificate authentication
- ✓ Certificate validity and principals
- ✓ CA-signed credentials work

**06-password-auth:**
- ✓ Password authentication with correct credentials
- ✓ Wrong password is rejected
- ✓ Public key auth is rejected in password-only mode

**07-2fa:**
- ✓ Both key and password required to authenticate
- ✓ Key alone is rejected
- ✓ Password alone is rejected
- ✓ Wrong password with correct key is rejected

**08-custom-config:**
- ✓ Global MaxStartups override from drop-in
- ✓ Per-group limits (MaxSessions, ClientAliveInterval) for media-team
- ✓ Per-user MaxAuthTries override for specific user
- ✓ File sharing within media-team group

**09-kubernetes:**
- ✓ StatefulSet pod reaches Ready under the full hardened securityContext
- ✓ SFTP login and file upload/download round-trip via kubectl port-forward
- ✓ Metrics port blocked from an unlabeled pod anywhere in the cluster
- ✓ Metrics port reachable from a role=monitoring pod (allow rule is scoped correctly, not blanket-open)
- ✓ SFTP port confirmed still open, the metrics deny didn't sweep up port 22 too
- ✓ Liveness and readiness probes are distinct checks, not one combined probe wired to both

## Shared Test Library

All scripts use `lib/test-helpers.sh`, which provides:

### Logging Functions
- `log_info` - Informational messages
- `log_success` - Success messages
- `log_error` - Error messages
- `log_warning` - Warning messages
- `log_step` - Major step headers
- `log_debug` - Debug output (enable with `DEBUG=1`)

### Test Functions
- `test_start` - Begin a test case
- `test_pass` - Mark test as passed
- `test_fail` - Mark test as failed
- `test_summary` - Show final results

### Key Generation
- `generate_host_key` - Generate SSH host key
- `generate_user_key` - Generate user SSH key + authorized_keys
- `generate_ca_key` - Generate Certificate Authority key
- `generate_user_certificate` - Generate and sign user certificate

### Docker Operations
- `docker_build` - Build image from Dockerfile
- `docker_compose_up` - Start services and wait for ready
- `docker_compose_down` - Stop and cleanup services

### SFTP Operations
- `sftp_connect_test` - Test authentication
- `sftp_list_projects` - List available projects
- `sftp_put_file` - Upload file
- `sftp_get_file` - Download file
- `sftp_delete_file` - Delete file
- `sftp_check_file_exists` - Check if file exists

## Customization

### Disable Colors
```bash
NO_COLOR=1 ./test.sh
```

### Enable Debug Output
```bash
DEBUG=1 ./test.sh
```

### Keep Environment After Tests
Edit the test script and comment out the cleanup calls:
```bash
# (cd "$SCRIPT_DIR" && docker_compose_down)
# cleanup_all "$SCRIPT_DIR"
```

## CI/CD Integration

Example GitHub Actions workflow:

```yaml
name: Test Examples
on: [push, pull_request]

jobs:
  test-examples:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        example:
          - 01-basic-dev
          - 02-docker-secrets
          - 03-cloud-native
          - 04-multi-project
          - 05-certificate-auth
          - 06-password-auth
          - 07-2fa
          - 08-custom-config

    steps:
      - uses: actions/checkout@v3
      - name: Test ${{ matrix.example }}
        run: |
          cd examples/${{ matrix.example }}
          ./test.sh

  test-kubernetes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: helm/kind-action@v1  # or install kind + kubectl directly
        with:
          install_only: true
      - name: Test 09-kubernetes
        run: |
          cd examples/09-kubernetes
          ./test.sh
```

## Troubleshooting

### Docker not running
```
Error: Cannot connect to Docker daemon
```
**Solution:** Start Docker Desktop or Docker daemon

### Permission denied
```
Error: Permission denied
```
**Solution:** Make scripts executable
```bash
chmod +x test.sh setup.sh
```

### Port already in use
```
Error: Port 2222 is already allocated
```
**Solution:** Stop other containers or change port in compose.yml

### Tests failing
1. Check Docker logs: `docker compose logs`
2. Run with debug: `DEBUG=1 ./test.sh`
3. Keep environment: Comment out cleanup, inspect manually
4. Verify compose.yml matches test expectations

## Contributing

When adding new examples:

1. Create example directory: `examples/06-new-feature/`
2. Add `compose.yml` and `README.md`
3. Copy and adapt `test.sh` from similar example
4. Copy and adapt `setup.sh` from similar example
5. Test both scripts thoroughly
6. Update this README with the new example

## Support

For issues with the automation scripts, please report at:
https://github.com/wiesion/zocalo-sftp/issues
