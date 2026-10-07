use std::collections::{HashMap, HashSet};

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
        if p.name == "sftp_users" {
            errors.push("project name \"sftp_users\" is reserved".to_string());
        }
        if p.gid == sftp_users_gid {
            errors.push(format!(
                "project {:?}: GID {} equals SFTP_USERS_GID (would grant access to every SFTP user)",
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
        validate_identity_graph(&users(u), &projects(p), 59999)
    }

    #[test]
    fn valid_graph_passes() {
        assert!(check(
            "alice:1001\nbob:1002:disabled",
            "a:2001:alice\nb:2002:alice,bob"
        )
        .is_empty());
    }

    #[test]
    fn duplicate_uid_rejected() {
        let e = check("alice:1001\nbob:1001", "");
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("UID 1001"));
    }

    #[test]
    fn duplicate_username_rejected() {
        assert!(!check("alice:1001\nalice:1002", "").is_empty());
    }

    #[test]
    fn duplicate_project_name_rejected() {
        assert!(!check("alice:1001", "a:2001:alice\na:2002:alice").is_empty());
    }

    #[test]
    fn duplicate_gid_rejected() {
        let e = check("alice:1001\nbob:1002", "a:2001:alice\nb:2001:bob");
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("GID 2001"));
    }

    #[test]
    fn project_gid_equal_to_users_gid_rejected() {
        let e = validate_identity_graph(&users("alice:1001"), &projects("a:59999:alice"), 59999);
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("SFTP_USERS_GID"));
    }

    #[test]
    fn reserved_group_name_rejected() {
        assert!(!check("alice:1001", "sftp_users:2001:alice").is_empty());
    }

    #[test]
    fn unknown_member_is_dropped_with_warning_not_error() {
        let u = users("alice:1001");
        let mut p = projects("a:2001:alice,ghost");
        assert!(validate_identity_graph(&u, &p, 59999).is_empty());
        let w = drop_undeclared_members(&u, &mut p);
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("ghost"));
        assert_eq!(p[0].members, vec!["alice".to_string()]);
    }

    #[test]
    fn member_with_separator_rejected_at_parse() {
        let (_, e) = parse_projects("a:2001:alice:0:root");
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("invalid member"));
    }

    #[test]
    fn all_errors_reported_together() {
        let e = check("alice:1001\nbob:1001", "a:2001:alice\nb:2001:bob");
        assert_eq!(e.len(), 2);
    }
}
