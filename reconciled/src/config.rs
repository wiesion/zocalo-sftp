/// Parsed entry from sftp_users.conf (`username:uid` or `username:uid:disabled`).
#[derive(Debug, Clone)]
pub struct UserEntry {
    pub name: String,
    pub uid: u32,
    pub disabled: bool,
}

/// Parsed entry from sftp_projects.conf (`project:gid:user1,user2,...`).
#[derive(Debug, Clone)]
pub struct ProjectEntry {
    pub name: String,
    pub gid: u32,
    pub members: Vec<String>,
}

fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// Parse sftp_users.conf. Returns (valid_entries, error_messages).
/// Callers decide whether errors are fatal (init) or warnings (watch).
pub fn parse_users(content: &str) -> (Vec<UserEntry>, Vec<String>) {
    let mut entries = Vec::new();
    let mut errors = Vec::new();
    for (i, raw) in content.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.splitn(3, ':').collect();
        if parts.len() < 2 {
            errors.push(format!(
                "sftp_users.conf:{}: expected name:uid[:disabled]",
                i + 1
            ));
            continue;
        }
        let name = parts[0];
        if !valid_name(name) {
            errors.push(format!(
                "sftp_users.conf:{}: invalid username {:?}",
                i + 1,
                name
            ));
            continue;
        }
        let uid: u32 = match parts[1].parse() {
            Ok(u) => u,
            Err(_) => {
                errors.push(format!(
                    "sftp_users.conf:{}: invalid UID {:?}",
                    i + 1,
                    parts[1]
                ));
                continue;
            }
        };
        if !(1000..60000).contains(&uid) {
            errors.push(format!(
                "sftp_users.conf:{}: UID {} out of range 1000-59999",
                i + 1,
                uid
            ));
            continue;
        }
        let disabled = match parts.get(2).copied().unwrap_or("") {
            "" => false,
            "disabled" => true,
            other => {
                errors.push(format!(
                    "sftp_users.conf:{}: unknown flag {:?} (expected 'disabled')",
                    i + 1,
                    other
                ));
                continue;
            }
        };
        entries.push(UserEntry {
            name: name.to_string(),
            uid,
            disabled,
        });
    }
    (entries, errors)
}

/// Parse sftp_projects.conf. Returns (valid_entries, error_messages).
pub fn parse_projects(content: &str) -> (Vec<ProjectEntry>, Vec<String>) {
    let mut entries = Vec::new();
    let mut errors = Vec::new();
    for (i, raw) in content.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.splitn(3, ':').collect();
        if parts.len() < 3 {
            errors.push(format!(
                "sftp_projects.conf:{}: expected project:gid:users",
                i + 1
            ));
            continue;
        }
        let name = parts[0];
        if !valid_name(name) {
            errors.push(format!(
                "sftp_projects.conf:{}: invalid project name {:?}",
                i + 1,
                name
            ));
            continue;
        }
        let gid: u32 = match parts[1].parse() {
            Ok(g) => g,
            Err(_) => {
                errors.push(format!(
                    "sftp_projects.conf:{}: invalid GID {:?}",
                    i + 1,
                    parts[1]
                ));
                continue;
            }
        };
        if !(1000..60000).contains(&gid) {
            errors.push(format!(
                "sftp_projects.conf:{}: GID {} out of range 1000-59999",
                i + 1,
                gid
            ));
            continue;
        }
        let members: Vec<String> = parts[2]
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        entries.push(ProjectEntry {
            name: name.to_string(),
            gid,
            members,
        });
    }
    (entries, errors)
}
