use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufWriter, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

#[derive(Debug, Clone)]
pub struct PasswdEntry {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    // gecos:home:shell, preserved verbatim from original file
    pub tail: String,
}

impl PasswdEntry {
    pub fn format(&self) -> String {
        format!("{}:x:{}:{}:{}", self.name, self.uid, self.gid, self.tail)
    }
}

#[derive(Debug, Clone)]
pub struct ShadowEntry {
    pub name: String,
    pub hash: String,
    // last-changed:min:max:warn:inactive:expire:reserved, preserved verbatim
    pub tail: String,
}

impl ShadowEntry {
    pub fn is_locked(&self) -> bool {
        self.hash.starts_with('!')
    }

    pub fn format(&self) -> String {
        format!("{}:{}:{}", self.name, self.hash, self.tail)
    }
}

#[derive(Debug, Clone)]
pub struct GroupEntry {
    pub name: String,
    pub gid: u32,
    pub members: Vec<String>,
}

impl GroupEntry {
    pub fn format(&self) -> String {
        format!("{}:x:{}:{}", self.name, self.gid, self.members.join(","))
    }
}

fn open_read(path: &str) -> io::Result<Option<fs::File>> {
    match fs::File::open(path) {
        Ok(f) => Ok(Some(f)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn read_passwd() -> io::Result<Vec<PasswdEntry>> {
    let Some(f) = open_read("/etc/passwd")? else {
        return Ok(vec![]);
    };
    let mut out = Vec::new();
    for line in io::BufReader::new(f).lines() {
        let line = line?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // name:password:uid:gid:gecos:home:shell  (7 fields)
        let parts: Vec<&str> = line.splitn(7, ':').collect();
        if parts.len() != 7 {
            continue;
        }
        let uid: u32 = parts[2].parse().unwrap_or(0);
        let gid: u32 = parts[3].parse().unwrap_or(0);
        out.push(PasswdEntry {
            name: parts[0].to_string(),
            uid,
            gid,
            tail: format!("{}:{}:{}", parts[4], parts[5], parts[6]),
        });
    }
    Ok(out)
}

pub fn read_shadow() -> io::Result<Vec<ShadowEntry>> {
    let Some(f) = open_read("/etc/shadow")? else {
        return Ok(vec![]);
    };
    let mut out = Vec::new();
    for line in io::BufReader::new(f).lines() {
        let line = line?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // name:hash:last-changed:min:max:warn:inactive:expire:reserved
        let parts: Vec<&str> = line.splitn(3, ':').collect();
        if parts.len() != 3 {
            continue;
        }
        out.push(ShadowEntry {
            name: parts[0].to_string(),
            hash: parts[1].to_string(),
            tail: parts[2].to_string(),
        });
    }
    Ok(out)
}

pub fn read_group() -> io::Result<Vec<GroupEntry>> {
    let Some(f) = open_read("/etc/group")? else {
        return Ok(vec![]);
    };
    let mut out = Vec::new();
    for line in io::BufReader::new(f).lines() {
        let line = line?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // name:password:gid:members
        let parts: Vec<&str> = line.splitn(4, ':').collect();
        if parts.len() != 4 {
            continue;
        }
        let gid: u32 = parts[2].parse().unwrap_or(0);
        let members: Vec<String> = if parts[3].is_empty() {
            vec![]
        } else {
            parts[3].split(',').map(|s| s.to_string()).collect()
        };
        out.push(GroupEntry {
            name: parts[0].to_string(),
            gid,
            members,
        });
    }
    Ok(out)
}

pub(crate) fn write_atomic(
    path: &Path,
    mode: u32,
    lines: impl Iterator<Item = String>,
) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(mode)
            .open(&tmp)?;
        let mut w = BufWriter::new(file);
        for line in lines {
            writeln!(w, "{}", line)?;
        }
        w.flush()?;
        w.into_inner()?.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

pub fn write_passwd(entries: &[PasswdEntry]) -> io::Result<()> {
    write_atomic(
        Path::new("/etc/passwd"),
        0o644,
        entries.iter().map(|e| e.format()),
    )
}

pub fn write_shadow(entries: &[ShadowEntry]) -> io::Result<()> {
    write_atomic(
        Path::new("/etc/shadow"),
        0o640,
        entries.iter().map(|e| e.format()),
    )
}

pub fn write_group(entries: &[GroupEntry]) -> io::Result<()> {
    write_atomic(
        Path::new("/etc/group"),
        0o644,
        entries.iter().map(|e| e.format()),
    )
}

/// Copy a user's authorized_keys secret into a location this process owns
/// (root, created fresh here) so it satisfies sshd's StrictModes regardless
/// of whatever UID owns the original bind-mounted secret on the host.
pub fn sync_authorized_keys(name: &str, content: &str) -> io::Result<()> {
    let dir = Path::new("/etc/ssh/authorized_keys");
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o755))?;
    write_atomic(&dir.join(name), 0o644, std::iter::once(content.to_string()))
}
