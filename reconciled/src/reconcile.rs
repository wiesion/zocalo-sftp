use std::collections::HashSet;
use std::fs;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use nix::unistd::{chown, fchown, Gid, Uid};
use sha_crypt::{sha512_check, sha512_simple, Sha512Params};

use crate::config::{ProjectEntry, UserEntry, READONLY_GROUP};
use crate::system::{
    read_group, read_passwd, read_shadow, sync_authorized_keys, write_group, write_passwd,
    write_shadow, GroupEntry, PasswdEntry, ShadowEntry,
};

fn days_since_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        / 86400
}

fn hash_password(pw: &str) -> Option<String> {
    let params = Sha512Params::new(100_000).ok()?;
    sha512_simple(pw, &params).ok()
}

// ── Init-only operations ──────────────────────────────────────────────────────

/// Remove all non-system users (1000 ≤ uid < 60000) from passwd and shadow,
/// and all non-system groups (1000 ≤ gid < 60000) except `keep_gids`.
pub fn reset_users(keep_gids: &[u32]) -> Result<(), Vec<String>> {
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
            group.retain(|e| e.gid < 1000 || e.gid >= 60000 || keep_gids.contains(&e.gid));
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

/// Lock project directories absent from `active_names` down to root:root 0700,
/// so a removed project's data is not left readable to the remaining SFTP users.
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
        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o700)) {
            eprintln!("Warning: failed to chmod {:?}: {}", path, e);
        }
    }
}

/// Assert that `path` is a real directory (never a symlink) owned by
/// root:`gid` with mode `02000 | mode`, creating it if absent. Contents are
/// left alone. Returns whether anything had to be changed.
///
/// The directory is opened with O_NOFOLLOW|O_DIRECTORY and fixed through the
/// descriptor, so a symlink planted on the (possibly persistent) data volume
/// cannot redirect the chown/chmod elsewhere.
pub(crate) fn enforce_project_dir(path: &Path, gid: u32, mode: u32) -> Result<bool, String> {
    let mut changed = false;
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir(path).map_err(|e| format!("failed to create {:?}: {}", path, e))?;
            changed = true;
        }
        Err(e) => return Err(format!("failed to stat {:?}: {}", path, e)),
    }

    let dir = fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_DIRECTORY)
        .open(path)
        .map_err(|e| format!("{:?} is not a plain directory: {}", path, e))?;
    let meta = dir
        .metadata()
        .map_err(|e| format!("failed to stat {:?}: {}", path, e))?;

    let want_mode = 0o2000 | mode;
    if meta.uid() != 0 || meta.gid() != gid {
        fchown(
            dir.as_raw_fd(),
            Some(Uid::from_raw(0)),
            Some(Gid::from_raw(gid)),
        )
        .map_err(|e| format!("failed to chown {:?}: {}", path, e))?;
        changed = true;
    }
    // chown can clear setgid, so the mode is checked after it, from a fresh stat.
    let current = dir
        .metadata()
        .map_err(|e| format!("failed to stat {:?}: {}", path, e))?
        .mode()
        & 0o7777;
    if current != want_mode {
        dir.set_permissions(fs::Permissions::from_mode(want_mode))
            .map_err(|e| format!("failed to chmod {:?}: {}", path, e))?;
        changed = true;
        // Without CAP_FSETID the kernel silently drops the setgid bit instead
        // of failing, so confirm the mode actually stuck.
        let after = dir
            .metadata()
            .map_err(|e| format!("failed to stat {:?}: {}", path, e))?
            .mode()
            & 0o7777;
        if after != want_mode {
            return Err(format!(
                "{:?}: mode is {:o} after chmod, expected {:o} (is CAP_FSETID dropped? \
                 it is required to keep the setgid bit on project directories)",
                path, after, want_mode
            ));
        }
    }
    Ok(changed)
}

/// Remove managed groups (1000 ≤ gid < 60000, other than `reserved_gids`)
/// that are no longer declared, so deleting a project revokes its members'
/// access. Returns the names removed.
pub(crate) fn prune_stale_groups(
    groups: &mut Vec<GroupEntry>,
    desired: &HashSet<&str>,
    reserved_gids: &[u32],
) -> Vec<String> {
    let mut removed = Vec::new();
    groups.retain(|g| {
        let managed = (1000..60000).contains(&g.gid) && !reserved_gids.contains(&g.gid);
        if managed && !desired.contains(g.name.as_str()) {
            removed.push(g.name.clone());
            false
        } else {
            true
        }
    });
    removed
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
    authorized_keys_sync: bool,
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
        // Another account already holding this UID would merge identities.
        if let Some(other) = passwd
            .iter()
            .find(|e| e.uid == user.uid && e.name != user.name)
        {
            let msg = format!(
                "UID {} for {} is already used by existing account {}",
                user.uid, user.name, other.name
            );
            if strict {
                errors.push(msg);
            } else {
                eprintln!("Warning: {}", msg);
            }
            continue;
        }

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

        if !user.disabled && authorized_keys_sync {
            let secret = format!("/run/secrets/{}.authorized_keys", user.name);
            match fs::read_to_string(&secret) {
                Ok(content) => {
                    if let Err(e) = sync_authorized_keys(&user.name, &content) {
                        let msg =
                            format!("failed to sync authorized_keys for {}: {}", user.name, e);
                        if strict {
                            errors.push(msg);
                        } else {
                            eprintln!("Warning: {}", msg);
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

/// Converge the `sftp_ro` group (see sshd.conf: `Match Group sftp_ro` forces
/// `internal-sftp -R`) so its members are exactly the users flagged `ro`.
///
/// Always strict: the group is a security control, and a flagged user left
/// out of it would be writable. sshd resolves group membership at login, so
/// a change applies to the next session of an affected user, without a reload.
pub fn reconcile_readonly_group(users: &[UserEntry], readonly_gid: u32) -> Result<(), Vec<String>> {
    let mut group = read_group().map_err(|e| vec![format!("failed to read /etc/group: {}", e)])?;
    let members = readonly_members(users);
    if !sync_readonly_group(&mut group, &members, readonly_gid)? {
        return Ok(());
    }
    write_group(&group).map_err(|e| vec![format!("failed to write /etc/group: {}", e)])?;
    eprintln!(
        "Reconcile: read-only accounts: {}",
        if members.is_empty() {
            "none".to_string()
        } else {
            members.join(", ")
        }
    );
    Ok(())
}

fn readonly_members(users: &[UserEntry]) -> Vec<String> {
    let mut members: Vec<String> = users
        .iter()
        .filter(|u| u.readonly)
        .map(|u| u.name.clone())
        .collect();
    members.sort();
    members
}

/// Create or update the read-only group in `group`. Returns whether it changed.
pub(crate) fn sync_readonly_group(
    group: &mut Vec<GroupEntry>,
    members: &[String],
    readonly_gid: u32,
) -> Result<bool, Vec<String>> {
    if let Some(other) = group
        .iter()
        .find(|g| g.gid == readonly_gid && g.name != READONLY_GROUP)
    {
        return Err(vec![format!(
            "GID {} for {} is already used by existing group {}",
            readonly_gid, READONLY_GROUP, other.name
        )]);
    }
    match group.iter_mut().find(|g| g.name == READONLY_GROUP) {
        Some(g) if g.gid != readonly_gid => Err(vec![format!(
            "group {} already exists with GID {}, expected {}",
            READONLY_GROUP, g.gid, readonly_gid
        )]),
        Some(g) if g.members == members => Ok(false),
        Some(g) => {
            g.members = members.to_vec();
            Ok(true)
        }
        None => {
            group.push(GroupEntry {
                name: READONLY_GROUP.to_string(),
                gid: readonly_gid,
                members: members.to_vec(),
            });
            Ok(true)
        }
    }
}

/// Converge /etc/group and /sftp-jail/projects/ toward `desired`.
///
/// Besides creating and repairing declared projects, this removes groups of
/// projects that are no longer declared (see `prune_stale_groups`).
///
/// strict=true  (init):  GID conflicts → collected errors returned as Err.
/// strict=false (watch): GID conflicts → logged warning, project skipped.
pub fn reconcile_projects(
    desired: &[ProjectEntry],
    project_mode: u32,
    reserved_gids: &[u32],
    strict: bool,
) -> Result<(), Vec<String>> {
    let mut errors: Vec<String> = Vec::new();

    let mut group = match read_group() {
        Ok(g) => g,
        Err(e) => return Err(vec![format!("failed to read /etc/group: {}", e)]),
    };
    let mut group_dirty = false;

    let desired_names: HashSet<&str> = desired.iter().map(|p| p.name.as_str()).collect();
    for name in prune_stale_groups(&mut group, &desired_names, reserved_gids) {
        eprintln!("Reconcile: removed group of undeclared project {}", name);
        group_dirty = true;
    }

    for project in desired {
        // Another group already holding this GID would merge two projects.
        if let Some(other) = group
            .iter()
            .find(|g| g.gid == project.gid && g.name != project.name)
        {
            let msg = format!(
                "GID {} for project {} is already used by existing group {}",
                project.gid, project.name, other.name
            );
            if strict {
                errors.push(msg);
            } else {
                eprintln!("Warning: {}", msg);
            }
            continue;
        }

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
        match enforce_project_dir(Path::new(&dir), project.gid, project_mode) {
            Ok(true) => eprintln!("Reconcile: asserted project directory {}", dir),
            Ok(false) => {}
            Err(msg) => {
                if strict {
                    errors.push(msg);
                } else {
                    eprintln!("Error: {}", msg);
                }
                continue;
            }
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

#[cfg(test)]
mod tests {
    use super::*;
    use nix::unistd::geteuid;

    fn group(name: &str, gid: u32) -> GroupEntry {
        GroupEntry {
            name: name.to_string(),
            gid,
            members: vec!["sheridan".to_string()],
        }
    }

    fn user(name: &str, ro: bool) -> UserEntry {
        UserEntry {
            name: name.to_string(),
            uid: 1001,
            disabled: false,
            readonly: ro,
        }
    }

    #[test]
    fn readonly_group_members_are_exactly_the_flagged_users() {
        let users = [
            user("ivanova", false),
            user("ivanova_ro", true),
            user("kosh", true),
        ];
        assert_eq!(readonly_members(&users), ["ivanova_ro", "kosh"]);
    }

    #[test]
    fn readonly_group_created_updated_and_idempotent() {
        let mut groups = vec![group("root", 0)];
        let m = vec!["ivanova_ro".to_string()];
        assert!(sync_readonly_group(&mut groups, &m, 59998).unwrap());
        assert_eq!(groups[1].name, "sftp_ro");
        assert_eq!(groups[1].members, m);
        assert!(!sync_readonly_group(&mut groups, &m, 59998).unwrap());
        // Dropping the flag empties the group on the next pass.
        assert!(sync_readonly_group(&mut groups, &[], 59998).unwrap());
        assert!(groups[1].members.is_empty());
    }

    #[test]
    fn readonly_group_gid_conflicts_are_errors() {
        let mut taken = vec![group("other", 59998)];
        assert!(sync_readonly_group(&mut taken, &[], 59998).is_err());
        let mut moved = vec![group("sftp_ro", 2001)];
        assert!(sync_readonly_group(&mut moved, &[], 59998).is_err());
    }

    #[test]
    fn prune_removes_only_undeclared_managed_groups() {
        let mut groups = vec![
            group("root", 0),
            group("sftp_users", 59999),
            group("sftp_ro", 59998),
            group("kept", 2001),
            group("gone", 2002),
        ];
        let desired: HashSet<&str> = ["kept"].into_iter().collect();
        let removed = prune_stale_groups(&mut groups, &desired, &[59999, 59998]);
        assert_eq!(removed, vec!["gone".to_string()]);
        let names: Vec<&str> = groups.iter().map(|g| g.name.as_str()).collect();
        assert_eq!(names, ["root", "sftp_users", "sftp_ro", "kept"]);
    }

    fn scratch(tag: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("zocalo-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn enforce_creates_and_then_is_idempotent() {
        if !geteuid().is_root() {
            return; // chown to arbitrary GIDs needs root (CI/Docker runs as root)
        }
        let root = scratch("create");
        let dir = root.join("p");
        assert!(enforce_project_dir(&dir, 2001, 0o770).unwrap());
        let m = fs::metadata(&dir).unwrap();
        assert_eq!((m.uid(), m.gid(), m.mode() & 0o7777), (0, 2001, 0o2770));
        assert!(!enforce_project_dir(&dir, 2001, 0o770).unwrap());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn enforce_repairs_drifted_owner_group_and_mode() {
        if !geteuid().is_root() {
            return;
        }
        let root = scratch("repair");
        let dir = root.join("p");
        fs::create_dir(&dir).unwrap();
        chown(&dir, Some(Uid::from_raw(9999)), Some(Gid::from_raw(9999))).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(enforce_project_dir(&dir, 2001, 0o770).unwrap());
        let m = fs::metadata(&dir).unwrap();
        assert_eq!((m.uid(), m.gid(), m.mode() & 0o7777), (0, 2001, 0o2770));
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn enforce_follows_gid_change() {
        if !geteuid().is_root() {
            return;
        }
        let root = scratch("regid");
        let dir = root.join("p");
        enforce_project_dir(&dir, 2001, 0o770).unwrap();
        enforce_project_dir(&dir, 2002, 0o770).unwrap();
        assert_eq!(fs::metadata(&dir).unwrap().gid(), 2002);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn enforce_refuses_symlink_and_leaves_target_alone() {
        let root = scratch("symlink");
        let target = root.join("target");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
        let link = root.join("p");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(enforce_project_dir(&link, 2001, 0o770).is_err());
        assert_eq!(fs::metadata(&target).unwrap().mode() & 0o7777, 0o755);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn enforce_refuses_regular_file() {
        let root = scratch("file");
        let f = root.join("p");
        fs::write(&f, b"x").unwrap();
        assert!(enforce_project_dir(&f, 2001, 0o770).is_err());
        fs::remove_dir_all(&root).unwrap();
    }
}
