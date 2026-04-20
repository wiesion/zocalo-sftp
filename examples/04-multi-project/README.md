# Multi-Project Collaboration

Demonstrates complex access patterns with multiple users and projects. Perfect for organizations with different teams needing secure, isolated workspaces with selective sharing.

## Setup

1. **Generate SSH host key:**
```bash
mkdir -p secrets
ssh-keygen -t ed25519 -f secrets/ssh_host_ed25519_key -N ""
```

2. **Generate user keys:**
```bash
# Command staff
for user in sheridan ivanova sinclair; do
  ssh-keygen -t ed25519 -f secrets/${user}_key -N ""
  cat secrets/${user}_key.pub > secrets/${user}.authorized_keys
done

# Department heads
for user in franklin garibaldi lyta; do
  ssh-keygen -t ed25519 -f secrets/${user}_key -N ""
  cat secrets/${user}_key.pub > secrets/${user}.authorized_keys
done
```

3. **Start the server:**
```bash
docker compose up -d
```

## Access Matrix

| User | Role | Projects |
|------|------|----------|
| **sheridan** | Captain | command-staff, security, shared-intel |
| **ivanova** | Commander | command-staff, shared-intel |
| **sinclair** | Ambassador | command-staff, shared-intel |
| **garibaldi** | Security Chief | security, shared-intel |
| **franklin** | CMO | medlab |
| **lyta** | Telepath | telepath-ops |

## Project Descriptions

### command-staff (GID 2001)
High-level strategic planning and station operations.
- **Access:** sheridan, ivanova, sinclair
- **Use case:** Executive decisions, strategic documents

### security (GID 2002)
Security operations and threat assessments.
- **Access:** garibaldi, sheridan
- **Use case:** Security reports, surveillance data

### medlab (GID 2003)
Medical records and research data.
- **Access:** franklin (only)
- **Use case:** Patient records, medical research (HIPAA-like isolation)

### telepath-ops (GID 2004)
Psi Corps and telepathic operations.
- **Access:** lyta (only)
- **Use case:** Sensitive telepathic data, isolated from regular staff

### shared-intel (GID 2005)
Cross-departmental intelligence sharing.
- **Access:** sheridan, ivanova, garibaldi, sinclair
- **Use case:** Shared reports, inter-departmental collaboration

## Usage Examples

```bash
# Captain Sheridan reviewing security reports
sftp -P 2222 -i secrets/sheridan_key sheridan@localhost
sftp> cd security
sftp> get threat-assessment.pdf

# Dr. Franklin updating medical records (isolated access)
sftp -P 2222 -i secrets/franklin_key franklin@localhost
sftp> cd medlab
sftp> put patient-records.enc

# Garibaldi and Sinclair collaborating on shared intel
sftp -P 2222 -i secrets/garibaldi_key garibaldi@localhost
sftp> cd shared-intel
sftp> put security-briefing.txt

sftp -P 2222 -i secrets/sinclair_key sinclair@localhost
sftp> cd shared-intel
sftp> get security-briefing.txt
```

## Permission Model

All projects use mode **2775** (setgid + rwxrwxr-x):
- ✅ Users in project group can read/write/execute
- ✅ New files inherit project group ownership (setgid bit)
- ✅ Users cannot delete project directories
- ❌ Non-project users cannot access

## Testing Access Control

Verify isolation:
```bash
# Franklin should ONLY see medlab
sftp -P 2222 -i secrets/franklin_key franklin@localhost
sftp> ls
# Output: medlab

# Sheridan should see multiple projects
sftp -P 2222 -i secrets/sheridan_key sheridan@localhost
sftp> ls
# Output: command-staff  security  shared-intel
```

## Use Cases

This pattern works well for:

1. **Departmental isolation** - Medical, legal, HR data separation
2. **Project-based access** - Software teams with different client projects
3. **Security clearance levels** - Classified, confidential, public
4. **Client data segregation** - Each client gets their own project
5. **Multi-tenant SaaS** - Different customers with isolated storage

## Scaling Considerations

For deployments with 50+ users or 20+ projects:

1. **Disable resets:**
```yaml
environment:
  SFTP_RESET_USERS: no
  SFTP_RESET_PROJECTS: no
```

2. **Use config files instead of env vars:**
```yaml
volumes:
  - ./config/sftp_users.conf:/config/sftp_users.conf:ro
  - ./config/sftp_projects.conf:/config/sftp_projects.conf:ro
```

3. **Enable metrics:**
```yaml
environment:
  SFTP_ENABLE_METRICS: yes
ports:
  - "9100:9100"
```

## File Structure

```
04-multi-project/
├── compose.yml
├── secrets/
│   ├── ssh_host_ed25519_key
│   ├── sheridan.authorized_keys
│   ├── ivanova.authorized_keys
│   ├── franklin.authorized_keys
│   ├── sinclair.authorized_keys
│   ├── garibaldi.authorized_keys
│   └── lyta.authorized_keys
└── data/
    ├── command-staff/      # sheridan, ivanova, sinclair
    ├── security/           # garibaldi, sheridan
    ├── medlab/             # franklin only
    ├── telepath-ops/       # lyta only
    └── shared-intel/       # sheridan, ivanova, garibaldi, sinclair
```
