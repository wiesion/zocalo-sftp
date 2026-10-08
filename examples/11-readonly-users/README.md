# Read-Only Users

Demonstrates the `ro` user flag. A read-only account can list and download, but the SFTP server refuses every request that modifies anything: upload, overwrite, delete, rename, mkdir, rmdir, symlink, chmod.

Two patterns are shown:

1. **A general read-only account** (`kosh`) for reviewers, backups or downstream consumers. It is a member of several projects and can read all of them.
2. **Read-only access for someone who normally has write access** (`ivanova` / `ivanova_ro`). The person gets a second login with an `_ro` suffix that reuses their existing SSH key, and picks the mode by the username they log in with.

## Config

```
# config/sftp_users.conf        username:uid[:flags]
ivanova:1001
ivanova_ro:1002:ro
garibaldi:1003
kosh:1004:ro
```
```
# config/sftp_projects.conf     project:gid:members
command-staff:2001:ivanova,ivanova_ro,kosh
security:2002:garibaldi,kosh
```

| Login | Mode | Projects |
|-------|------|----------|
| **ivanova** | read-write | command-staff |
| **ivanova_ro** | read-only | command-staff (same SSH key as ivanova) |
| **garibaldi** | read-write | security |
| **kosh** | read-only | command-staff, security |

## Reusing authentication

`ivanova_ro` has no key of its own. `compose.yml` publishes ivanova's public key under both secret names:

```yaml
secrets:
  ivanova.authorized_keys:
    file: ./secrets/ivanova.authorized_keys
  ivanova_ro.authorized_keys:
    file: ./secrets/ivanova.authorized_keys
```

```bash
sftp -P 2222 -i secrets/ivanova_key ivanova@localhost      # read-write
sftp -P 2222 -i secrets/ivanova_key ivanova_ro@localhost   # read-only
```

For password auth, give `ivanova_ro.password` the same content as `ivanova.password`. For certificate auth, sign the certificate with both principals: `ssh-keygen -s ca -n ivanova,ivanova_ro ...`.

## Notes

- Read-only is a property of the **account**. `ivanova_ro` is read-only in every project it belongs to; to be read-write in one project and read-only in another, use one login per mode.
- It is enforced by the SFTP server (`internal-sftp -R`), not by file permissions, so it also holds where POSIX permissions are not enforced.
- Adding or removing `ro` applies to the account's next session within `SFTP_RECONCILE_INTERVAL` seconds. An already open session keeps its mode.
- `ro` does not widen access: `ivanova_ro` still cannot read `security`.

## Run

```bash
./setup.sh   # interactive: builds, starts, prints connection commands
./test.sh    # automated checks
```
