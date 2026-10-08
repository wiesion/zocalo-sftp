use std::collections::{HashMap, HashSet};

/// Parsed entry from sftp_users.conf (`username:uid[:flag[,flag]]`, flags `disabled` and `ro`).
#[derive(Debug, Clone)]
pub struct UserEntry {
    pub name: String,
    pub uid: u32,
    pub disabled: bool,
    pub readonly: bool,
}

/// Parsed entry from sftp_projects.conf (`project:gid:user1,user2,...`).
#[derive(Debug, Clone)]
pub struct ProjectEntry {
    pub name: String,
    pub gid: u32,
    pub members: Vec<String>,
}

/// Name of the managed group that forces read-only SFTP sessions (see sshd.conf).
pub const READONLY_GROUP: &str = "sftp_ro";

fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// Parse the comma-separated flag list of a users line into (disabled, readonly).
fn parse_user_flags(raw: &str) -> Result<(bool, bool), String> {
    let (mut disabled, mut readonly) = (false, false);
    for flag in raw.split(',').map(str::trim).filter(|f| !f.is_empty()) {
        let seen = match flag {
            "disabled" => &mut disabled,
            "ro" => &mut readonly,
            other => {
                return Err(format!(
                    "unknown flag {:?} (expected 'disabled' and/or 'ro')",
                    other
                ))
            }
        };
        if *seen {
            return Err(format!("duplicate flag {:?}", flag));
        }
        *seen = true;
    }
    Ok((disabled, readonly))
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
                "sftp_users.conf:{}: expected name:uid[:flags]",
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
        let (disabled, readonly) = match parse_user_flags(parts.get(2).copied().unwrap_or("")) {
            Ok(f) => f,
            Err(msg) => {
                errors.push(format!("sftp_users.conf:{}: {}", i + 1, msg));
                continue;
            }
        };
        entries.push(UserEntry {
            name: name.to_string(),
            uid,
            disabled,
            readonly,
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
        if let Some(bad) = members.iter().find(|m| !valid_name(m)) {
            errors.push(format!(
                "sftp_projects.conf:{}: invalid member name {:?}",
                i + 1,
                bad
            ));
            continue;
        }
        entries.push(ProjectEntry {
            name: name.to_string(),
            gid,
            members,
        });
    }
    (entries, errors)
}

/// Cross-entry identity checks. Pure: no system state is read or written.
///
/// Project isolation rests on numeric identities, so every collision that
/// could merge two identities is an error. Returns all violations at once;
/// callers must not mutate anything when the result is non-empty.
pub fn validate_identity_graph(
    users: &[UserEntry],
    projects: &[ProjectEntry],
    sftp_users_gid: u32,
    readonly_gid: u32,
) -> Vec<String> {
    let mut errors = Vec::new();

    let mut names: HashSet<&str> = HashSet::new();
    let mut uids: HashMap<u32, &str> = HashMap::new();
    for u in users {
        if !names.insert(&u.name) {
            errors.push(format!("duplicate username {:?}", u.name));
        }
        if let Some(other) = uids.insert(u.uid, &u.name) {
            if other != u.name {
                errors.push(format!(
                    "UID {} assigned to both {:?} and {:?}",
                    u.uid, other, u.name
                ));
            }
        }
    }

    let mut project_names: HashSet<&str> = HashSet::new();
    let mut gids: HashMap<u32, &str> = HashMap::new();
    for p in projects {
        if !project_names.insert(&p.name) {
            errors.push(format!("duplicate project name {:?}", p.name));
        }
        if p.name == "sftp_users" || p.name == READONLY_GROUP {
            errors.push(format!("project name {:?} is reserved", p.name));
        }
        if p.gid == sftp_users_gid {
            errors.push(format!(
                "project {:?}: GID {} equals SFTP_USERS_GID (would grant access to every SFTP user)",
                p.name, p.gid
            ));
        }
        if p.gid == readonly_gid {
            errors.push(format!(
                "project {:?}: GID {} equals SFTP_READONLY_GID (would make the project's members read-only everywhere)",
                p.name, p.gid
            ));
        }
        if let Some(other) = gids.insert(p.gid, &p.name) {
            if other != p.name {
                errors.push(format!(
                    "GID {} assigned to both projects {:?} and {:?}",
                    p.gid, other, p.name
                ));
            }
        }
    }

    errors
}

/// Remove project members that are not declared in sftp_users.conf and return
/// a warning for each. This is deliberately not an error: removing a user
/// while a project still lists them is a normal edit order, and failing the
/// whole reconcile over it would block the revocation the operator is making.
/// An undeclared name is never granted anything.
pub fn drop_undeclared_members(users: &[UserEntry], projects: &mut [ProjectEntry]) -> Vec<String> {
    let declared: HashSet<&str> = users.iter().map(|u| u.name.as_str()).collect();
    let mut warnings = Vec::new();
    for p in projects.iter_mut() {
        p.members.retain(|m| {
            let ok = declared.contains(m.as_str());
            if !ok {
                warnings.push(format!(
                    "project {:?}: member {:?} is not declared in sftp_users.conf, ignored",
                    p.name, m
                ));
            }
            ok
        });
    }
    warnings
}

#[cfg(test)]
mod tests {
    use super::*;

    fn users(s: &str) -> Vec<UserEntry> {
        let (u, e) = parse_users(s);
        assert!(e.is_empty(), "{:?}", e);
        u
    }
    fn projects(s: &str) -> Vec<ProjectEntry> {
        let (p, e) = parse_projects(s);
        assert!(e.is_empty(), "{:?}", e);
        p
    }
    fn check(u: &str, p: &str) -> Vec<String> {
        validate_identity_graph(&users(u), &projects(p), 59999, 59998)
    }

    #[test]
    fn valid_graph_passes() {
        assert!(check(
            "sheridan:1001\ngaribaldi:1002:disabled",
            "a:2001:sheridan\nb:2002:sheridan,garibaldi"
        )
        .is_empty());
    }

    #[test]
    fn duplicate_uid_rejected() {
        let e = check("sheridan:1001\ngaribaldi:1001", "");
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("UID 1001"));
    }

    #[test]
    fn duplicate_username_rejected() {
        assert!(!check("sheridan:1001\nsheridan:1002", "").is_empty());
    }

    #[test]
    fn duplicate_project_name_rejected() {
        assert!(!check("sheridan:1001", "a:2001:sheridan\na:2002:sheridan").is_empty());
    }

    #[test]
    fn duplicate_gid_rejected() {
        let e = check(
            "sheridan:1001\ngaribaldi:1002",
            "a:2001:sheridan\nb:2001:garibaldi",
        );
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("GID 2001"));
    }

    #[test]
    fn project_gid_equal_to_users_gid_rejected() {
        let e = validate_identity_graph(
            &users("sheridan:1001"),
            &projects("a:59999:sheridan"),
            59999,
            59998,
        );
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("SFTP_USERS_GID"));
    }

    #[test]
    fn reserved_group_name_rejected() {
        assert!(!check("sheridan:1001", "sftp_users:2001:sheridan").is_empty());
    }

    #[test]
    fn project_gid_equal_to_readonly_gid_rejected() {
        let e = validate_identity_graph(
            &users("sheridan:1001"),
            &projects("a:59998:sheridan"),
            59999,
            59998,
        );
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("SFTP_READONLY_GID"));
    }

    #[test]
    fn reserved_readonly_group_name_rejected() {
        assert!(!check("sheridan:1001", "sftp_ro:2001:sheridan").is_empty());
    }

    fn flags(line: &str) -> (bool, bool) {
        let u = users(line);
        (u[0].disabled, u[0].readonly)
    }

    #[test]
    fn user_flags_parse() {
        assert_eq!(flags("a:1001"), (false, false));
        assert_eq!(flags("a:1001:"), (false, false));
        assert_eq!(flags("a:1001:disabled"), (true, false));
        assert_eq!(flags("a:1001:ro"), (false, true));
        assert_eq!(flags("a:1001:ro,disabled"), (true, true));
        assert_eq!(flags("a:1001:disabled, ro"), (true, true));
    }

    #[test]
    fn bad_user_flags_rejected() {
        for line in [
            "a:1001:rw",
            "a:1001:ro,ro",
            "a:1001:ro:disabled",
            "a:1001:RO",
        ] {
            let (u, e) = parse_users(line);
            assert!(u.is_empty(), "{line}");
            assert_eq!(e.len(), 1, "{line}");
        }
    }

    #[test]
    fn unknown_member_is_dropped_with_warning_not_error() {
        let u = users("sheridan:1001");
        let mut p = projects("a:2001:sheridan,ghost");
        assert!(validate_identity_graph(&u, &p, 59999, 59998).is_empty());
        let w = drop_undeclared_members(&u, &mut p);
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("ghost"));
        assert_eq!(p[0].members, vec!["sheridan".to_string()]);
    }

    #[test]
    fn member_with_separator_rejected_at_parse() {
        let (_, e) = parse_projects("a:2001:sheridan:0:root");
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("invalid member"));
    }

    #[test]
    fn all_errors_reported_together() {
        let e = check(
            "sheridan:1001\ngaribaldi:1001",
            "a:2001:sheridan\nb:2001:garibaldi",
        );
        assert_eq!(e.len(), 2);
    }
}
