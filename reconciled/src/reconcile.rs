use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use nix::unistd::{chown, Gid, Uid};
use sha_crypt::{sha512_check, sha512_simple, Sha512Params};

use crate::config::{ProjectEntry, UserEntry};
use crate::system::{
    read_group, read_passwd, read_shadow, write_group, write_passwd, write_shadow, GroupEntry,
    PasswdEntry, ShadowEntry,
};

fn days_since_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        / 86400
}

fn hash_password(pw: &str) -> Option<String> {
    let params = Sha512Params::new(5000).ok()?;
    sha512_simple(pw, &params).ok()
}

// ── Init-only operations ──────────────────────────────────────────────────────

/// Remove all non-system users (1000 ≤ uid < 60000) from passwd and shadow,
/// and all non-system groups (1000 ≤ gid < 60000) except sftp_users_gid.
pub fn reset_users(sftp_users_gid: u32) -> Result<(), Vec<String>> {
    let mut errors = Vec::new();

    match read_passwd() {
        Err(e) => errors.push(format!("failed to read /etc/passwd: {}", e)),
        Ok(mut passwd) => {
            let before = passwd.len();
            passwd.retain(|e| e.uid < 1000 || e.uid >= 60000);
            if passwd.len() != before {
                if let Err(e) = write_passwd(&passwd) {
                    errors.push(format!("failed to write /etc/passwd: {}", e));
                }
            }
            // Drop shadow entries for removed users
            let kept: HashSet<String> = passwd.iter().map(|e| e.name.clone()).collect();
            match read_shadow() {
                Err(e) => errors.push(format!("failed to read /etc/shadow: {}", e)),
                Ok(mut shadow) => {
                    let before_s = shadow.len();
                    shadow.retain(|e| kept.contains(&e.name));
                    if shadow.len() != before_s {
                        if let Err(e) = write_shadow(&shadow) {
                            errors.push(format!("failed to write /etc/shadow: {}", e));
                        }
                    }
                }
            }
        }
    }

    match read_group() {
        Err(e) => errors.push(format!("failed to read /etc/group: {}", e)),
        Ok(mut group) => {
            let before = group.len();
            group.retain(|e| e.gid < 1000 || e.gid >= 60000 || e.gid == sftp_users_gid);
            if group.len() != before {
                if let Err(e) = write_group(&group) {
                    errors.push(format!("failed to write /etc/group: {}", e));
                }
            }
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

/// Ensure the sftp_users group exists with the configured GID.
/// Checked by GID (not name), consistent with shell behaviour.
pub fn ensure_sftp_users_group(sftp_users_gid: u32) -> Result<(), String> {
    let mut group = read_group().map_err(|e| format!("failed to read /etc/group: {}", e))?;
    if !group.iter().any(|g| g.gid == sftp_users_gid) {
        group.push(GroupEntry {
            name: "sftp_users".to_string(),
            gid: sftp_users_gid,
            members: vec![],
        });
        write_group(&group).map_err(|e| format!("failed to write /etc/group: {}", e))?;
    }
    Ok(())
}

/// Create /sftp-jail/projects owned by root:root with mode 755.
pub fn ensure_project_root() {
    let path = Path::new("/sftp-jail/projects");
    if let Err(e) = fs::create_dir_all(path) {
        eprintln!("Error: failed to create /sftp-jail/projects: {}", e);
        return;
    }
    if let Err(e) = chown(path, Some(Uid::from_raw(0)), Some(Gid::from_raw(0))) {
        eprintln!("Error: failed to chown /sftp-jail/projects: {}", e);
    }
    if let Err(e) = fs::set_permissions(path, fs::Permissions::from_mode(0o755)) {
        eprintln!("Error: failed to chmod /sftp-jail/projects: {}", e);
    }
}

/// Reset ownership to root:root 755 on project directories absent from `active_names`.
pub fn reset_orphaned_projects(active_names: &HashSet<&str>) {
    let dir = Path::new("/sftp-jail/projects");
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        let raw_name = entry.file_name();
        let name = raw_name.to_string_lossy();
        if active_names.contains(name.as_ref()) {
            continue;
        }
        let path = entry.path();
        if let Err(e) = chown(&path, Some(Uid::from_raw(0)), Some(Gid::from_raw(0))) {
            eprintln!("Warning: failed to chown {:?}: {}", path, e);
        }
        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
            eprintln!("Warning: failed to chmod {:?}: {}", path, e);
        }
    }
}

// ── Shared reconcile logic (init + watch) ────────────────────────────────────

/// Converge /etc/passwd and /etc/shadow toward `desired`.
///
/// strict=true  (init):  UID conflicts → collected errors returned as Err; nothing written on error.
/// strict=false (watch): UID conflicts → logged warning, entry skipped; other entries still applied.
pub fn reconcile_users(
    desired: &[UserEntry],
    sftp_users_gid: u32,
    password_auth: bool,
    strict: bool,
) -> Result<(), Vec<String>> {
    let mut errors: Vec<String> = Vec::new();

    let mut passwd = match read_passwd() {
        Ok(p) => p,
        Err(e) => return Err(vec![format!("failed to read /etc/passwd: {}", e)]),
    };
    let mut shadow = match read_shadow() {
        Ok(s) => s,
        Err(e) => return Err(vec![format!("failed to read /etc/shadow: {}", e)]),
    };

    let mut passwd_dirty = false;
    let mut shadow_dirty = false;

    for user in desired {
        // Check for UID conflict before any mutation
        let existing_uid = passwd.iter().find(|e| e.name == user.name).map(|e| e.uid);
        match existing_uid {
            Some(uid) if uid != user.uid => {
                let msg = format!(
                    "user {} already exists with UID {}, expected {}",
                    user.name, uid, user.uid
                );
                if strict {
                    errors.push(msg);
                } else {
                    eprintln!("Warning: {}", msg);
                }
                continue;
            }
            None => {
                passwd.push(PasswdEntry {
                    name: user.name.clone(),
                    uid: user.uid,
                    gid: sftp_users_gid,
                    tail: "::/nonexistent:/sbin/nologin".to_string(),
                });
                passwd_dirty = true;

                shadow.push(ShadowEntry {
                    name: user.name.clone(),
                    hash: if user.disabled { "!*" } else { "*" }.to_string(),
                    tail: format!("{}:0:99999:7:::", days_since_epoch()),
                });
                shadow_dirty = true;

                if user.disabled {
                    eprintln!(
                        "Reconcile: added disabled user {} (UID {})",
                        user.name, user.uid
                    );
                } else {
                    eprintln!("Reconcile: added user {} (UID {})", user.name, user.uid);
                }
            }
            Some(_) => {
                // Correct UID, sync lock state only
                if let Some(se) = shadow.iter_mut().find(|e| e.name == user.name) {
                    if user.disabled && !se.is_locked() {
                        se.hash = "!*".to_string();
                        shadow_dirty = true;
                        eprintln!("Reconcile: disabled user {}", user.name);
                    } else if !user.disabled && se.is_locked() {
                        se.hash = "*".to_string();
                        shadow_dirty = true;
                        eprintln!("Reconcile: enabled user {}", user.name);
                    }
                }
            }
        }

        if !user.disabled && password_auth {
            let secret = format!("/run/secrets/{}.password", user.name);
            match fs::read_to_string(&secret) {
                Ok(raw) => {
                    let pw = raw.trim_end_matches(&['\n', '\r'][..]);
                    if !pw.is_empty() {
                        if let Some(se) = shadow.iter_mut().find(|e| e.name == user.name) {
                            // sha512_check avoids rewriting shadow when password is unchanged
                            if sha512_check(pw, &se.hash).is_err() {
                                match hash_password(pw) {
                                    Some(h) => {
                                        se.hash = h;
                                        shadow_dirty = true;
                                    }
                                    None => {
                                        let msg =
                                            format!("failed to hash password for {}", user.name);
                                        if strict {
                                            errors.push(msg);
                                        } else {
                                            eprintln!("Warning: {}", msg);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    let msg = format!("could not read {}: {}", secret, e);
                    if strict {
                        errors.push(msg);
                    } else {
                        eprintln!("Warning: {}", msg);
                    }
                }
            }
        }
    }

    // Watch mode: lock users in passwd that are absent from config entirely
    if !strict {
        let desired_names: HashSet<&str> = desired.iter().map(|u| u.name.as_str()).collect();
        for pe in passwd.iter() {
            if pe.uid >= 1000 && pe.uid < 60000 && !desired_names.contains(pe.name.as_str()) {
                if let Some(se) = shadow.iter_mut().find(|e| e.name == pe.name) {
                    if !se.is_locked() {
                        se.hash = "!*".to_string();
                        shadow_dirty = true;
                        eprintln!("Reconcile: locked removed user {}", pe.name);
                    }
                }
            }
        }
    }

    if strict && !errors.is_empty() {
        return Err(errors);
    }

    if passwd_dirty {
        write_passwd(&passwd).map_err(|e| vec![format!("failed to write /etc/passwd: {}", e)])?;
    }
    if shadow_dirty {
        write_shadow(&shadow).map_err(|e| vec![format!("failed to write /etc/shadow: {}", e)])?;
    }

    Ok(())
}

/// Converge /etc/group and /sftp-jail/projects/ toward `desired`.
///
/// strict=true  (init):  GID conflicts → collected errors returned as Err.
/// strict=false (watch): GID conflicts → logged warning, project skipped.
pub fn reconcile_projects(
    desired: &[ProjectEntry],
    project_mode: u32,
    strict: bool,
) -> Result<(), Vec<String>> {
    let mut errors: Vec<String> = Vec::new();

    let mut group = match read_group() {
        Ok(g) => g,
        Err(e) => return Err(vec![format!("failed to read /etc/group: {}", e)]),
    };
    let mut group_dirty = false;

    for project in desired {
        let existing_gid = group.iter().find(|g| g.name == project.name).map(|g| g.gid);
        match existing_gid {
            Some(gid) if gid != project.gid => {
                let msg = format!(
                    "group {} already exists with GID {}, expected {}",
                    project.name, gid, project.gid
                );
                if strict {
                    errors.push(msg);
                } else {
                    eprintln!("Warning: {}", msg);
                }
                continue;
            }
            None => {
                group.push(GroupEntry {
                    name: project.name.clone(),
                    gid: project.gid,
                    members: vec![],
                });
                group_dirty = true;
                eprintln!(
                    "Reconcile: added group {} (GID {})",
                    project.name, project.gid
                );
            }
            Some(_) => {} // correct GID, fall through to dir/membership sync
        }

        let dir = format!("/sftp-jail/projects/{}", project.name);
        let dir_path = Path::new(&dir);
        if !dir_path.exists() {
            if let Err(e) = fs::create_dir_all(dir_path) {
                let msg = format!("failed to create {}: {}", dir, e);
                if strict {
                    errors.push(msg);
                } else {
                    eprintln!("Error: {}", msg);
                }
                continue;
            }
            // setgid (02000) combined with configured mode
            if let Err(e) =
                fs::set_permissions(dir_path, fs::Permissions::from_mode(0o2000 | project_mode))
            {
                eprintln!("Error: failed to chmod {}: {}", dir, e);
            }
            if let Err(e) = chown(
                dir_path,
                Some(Uid::from_raw(0)),
                Some(Gid::from_raw(project.gid)),
            ) {
                eprintln!("Error: failed to chown {}: {}", dir, e);
            }
            eprintln!("Reconcile: created project directory {}", dir);
        }

        // Full-replace membership so repeated runs are idempotent
        if let Some(ge) = group.iter_mut().find(|g| g.name == project.name) {
            if ge.members != project.members {
                ge.members = project.members.clone();
                group_dirty = true;
            }
        }
    }

    if strict && !errors.is_empty() {
        return Err(errors);
    }

    if group_dirty {
        write_group(&group).map_err(|e| vec![format!("failed to write /etc/group: {}", e)])?;
    }

    Ok(())
}
