mod config;
mod reconcile;
mod render;
mod system;
mod validate;

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::Instant;

use notify::event::{AccessKind, AccessMode};
use notify::{Config as WatchConfig, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use signal_hook::consts::SIGTERM;
use signal_hook::flag;

use validate::RuntimeConfig;

/// A missing file is an empty config; any other read failure is an error, so
/// a transient read problem can never be mistaken for "everything removed".
fn read_config_file(path: &str) -> Result<String, String> {
    match std::fs::read_to_string(path) {
        Ok(s) => Ok(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("cannot read {}: {}", path, e)),
    }
}

/// Read, parse and cross-validate both config files. Returns every problem at
/// once; nothing may be mutated unless this returns Ok.
fn load_config(
    sftp_users_gid: u32,
    readonly_gid: u32,
) -> Result<(Vec<config::UserEntry>, Vec<config::ProjectEntry>), Vec<String>> {
    let mut errors = Vec::new();
    let users_raw = read_config_file("/config/sftp_users.conf")
        .map_err(|e| errors.push(e))
        .unwrap_or_default();
    let projects_raw = read_config_file("/config/sftp_projects.conf")
        .map_err(|e| errors.push(e))
        .unwrap_or_default();
    if !errors.is_empty() {
        return Err(errors);
    }

    let (users, user_errors) = config::parse_users(&users_raw);
    let (projects, project_errors) = config::parse_projects(&projects_raw);
    errors.extend(user_errors);
    errors.extend(project_errors);
    // Only meaningful on fully parsed input: dropped lines would otherwise
    // surface as spurious "undeclared member" errors.
    if errors.is_empty() {
        errors.extend(config::validate_identity_graph(
            &users,
            &projects,
            sftp_users_gid,
            readonly_gid,
        ));
    }
    if errors.is_empty() {
        let mut projects = projects;
        for w in config::drop_undeclared_members(&users, &mut projects) {
            eprintln!("Warning: {}", w);
        }
        Ok((users, projects))
    } else {
        Err(errors)
    }
}

fn has_config() -> bool {
    Path::new("/config/sftp_users.conf").exists()
        || Path::new("/config/sftp_projects.conf").exists()
}

// ── init subcommand ───────────────────────────────────────────────────────────
// Order: render sshd_config → parse user/project config → provision. Any
// error aborts before the next step runs.

fn run_init(cfg: &RuntimeConfig) {
    let dropin_errors = validate::check_dropins(Path::new("/config/sshd_config.d"));
    if !dropin_errors.is_empty() {
        for e in &dropin_errors {
            eprintln!("Error: {}", e);
        }
        std::process::exit(1);
    }

    if let Err(e) = render::render_sshd_config(cfg) {
        eprintln!("Error: failed to render sshd_config: {}", e);
        std::process::exit(1);
    }

    // Fail immediately on any problem: bad config must not reach production,
    // and nothing below this point has touched /etc yet.
    let (users, projects) = match load_config(cfg.sftp_users_gid, cfg.readonly_gid) {
        Ok(c) => c,
        Err(errs) => {
            for e in &errs {
                eprintln!("Error: {}", e);
            }
            std::process::exit(1);
        }
    };

    if cfg.reset_users {
        if let Err(errs) = reconcile::reset_users(&[cfg.sftp_users_gid, cfg.readonly_gid]) {
            for e in &errs {
                eprintln!("Error: {}", e);
            }
            std::process::exit(1);
        }
    }

    if let Err(e) = reconcile::ensure_sftp_users_group(cfg.sftp_users_gid) {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }

    if let Err(errs) = reconcile::reconcile_users(
        &users,
        cfg.sftp_users_gid,
        cfg.password_auth_enabled,
        cfg.authorized_keys_sync,
        true,
    ) {
        for e in &errs {
            eprintln!("Error: {}", e);
        }
        std::process::exit(1);
    }

    // Fail closed: a read-only account that could not be placed in the
    // read-only group would silently be writable, so this aborts startup.
    if let Err(errs) = reconcile::reconcile_readonly_group(&users, cfg.readonly_gid) {
        for e in &errs {
            eprintln!("Error: {}", e);
        }
        std::process::exit(1);
    }

    reconcile::ensure_project_root();

    if cfg.reset_projects {
        let active: HashSet<&str> = projects.iter().map(|p| p.name.as_str()).collect();
        reconcile::reset_orphaned_projects(&active);
    }

    if let Err(errs) = reconcile::reconcile_projects(
        &projects,
        cfg.project_mode,
        &[cfg.sftp_users_gid, cfg.readonly_gid],
        true,
    ) {
        for e in &errs {
            eprintln!("Error: {}", e);
        }
        std::process::exit(1);
    }

    // The one machine-readable line entrypoint.sh captures via command
    // substitution (`_metrics_addr=$(sftp-reconciled init)`). Every other
    // message above goes to stderr; stdout is reserved for this contract.
    println!("{}", cfg.metrics_socat_addr);
}

// ── watch subcommand ──────────────────────────────────────────────────────────

/// Watch-mode reconcile. If the config does not validate as a whole, nothing
/// is applied and the last converged state stays in force: a half-applied
/// identity graph is worse than a stale one.
fn reconcile_lenient(cfg: &RuntimeConfig) {
    let (users, projects) = match load_config(cfg.sftp_users_gid, cfg.readonly_gid) {
        Ok(c) => c,
        Err(errs) => {
            for e in &errs {
                eprintln!("Error: {}", e);
            }
            eprintln!(
                "sftp-reconciled: config invalid, reconcile skipped (previous state retained)"
            );
            return;
        }
    };

    if let Err(errs) = reconcile::reconcile_users(
        &users,
        cfg.sftp_users_gid,
        cfg.password_auth_enabled,
        cfg.authorized_keys_sync,
        false,
    ) {
        for e in &errs {
            eprintln!("Error: {}", e);
        }
    }
    if let Err(errs) = reconcile::reconcile_readonly_group(&users, cfg.readonly_gid) {
        for e in &errs {
            eprintln!("Error: {}", e);
        }
    }
    if let Err(errs) = reconcile::reconcile_projects(
        &projects,
        cfg.project_mode,
        &[cfg.sftp_users_gid, cfg.readonly_gid],
        false,
    ) {
        for e in &errs {
            eprintln!("Error: {}", e);
        }
    }
    if cfg.reset_projects {
        let active: HashSet<&str> = projects.iter().map(|p| p.name.as_str()).collect();
        reconcile::reset_orphaned_projects(&active);
    }
}

fn is_generation_event(event: &notify::Event) -> bool {
    let relevant = matches!(
        event.kind,
        EventKind::Access(AccessKind::Close(AccessMode::Write))
            | EventKind::Create(_)
            | EventKind::Modify(_)
    );
    relevant
        && event
            .paths
            .iter()
            .any(|p| p.file_name().map(|n| n == ".generation").unwrap_or(false))
}

fn run_watch(cfg: &RuntimeConfig) {
    if !has_config() {
        eprintln!("sftp-reconciled: no config files found, watching for changes");
    }

    let should_exit = Arc::new(AtomicBool::new(false));
    if let Err(e) = flag::register(SIGTERM, Arc::clone(&should_exit)) {
        eprintln!("Warning: failed to register SIGTERM handler: {}", e);
    }

    let (tx, rx) = mpsc::channel();
    let mut watcher = match RecommendedWatcher::new(
        move |res| {
            let _ = tx.send(res);
        },
        WatchConfig::default(),
    ) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("Error: failed to create file watcher: {}", e);
            return;
        }
    };

    if let Err(e) = watcher.watch(Path::new("/config"), RecursiveMode::NonRecursive) {
        eprintln!("Warning: failed to watch /config: {}", e);
    }

    if has_config() {
        reconcile_lenient(cfg);
    }

    let mut last = Instant::now();

    loop {
        if should_exit.load(Ordering::Relaxed) {
            break;
        }

        match rx.recv_timeout(std::time::Duration::from_secs(1)) {
            Ok(Ok(event)) => {
                if is_generation_event(&event) {
                    eprintln!("sftp-reconciled: .generation changed, reconciling");
                    reconcile_lenient(cfg);
                    last = Instant::now();
                }
            }
            Ok(Err(e)) => eprintln!("sftp-reconciled: watch error: {}", e),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if last.elapsed() >= cfg.reconcile_interval {
                    if has_config() {
                        reconcile_lenient(cfg);
                    }
                    last = Instant::now();
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
}

// ── entry point ───────────────────────────────────────────────────────────────

fn main() {
    // Validate everything up front, for both subcommands: fail fast with every
    // problem reported at once rather than one restart cycle at a time.
    let cfg = match validate::validate_env() {
        Ok(c) => c,
        Err(errs) => {
            for e in &errs {
                eprintln!("Error: {}", e);
            }
            std::process::exit(1);
        }
    };

    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()).unwrap_or("watch") {
        "init" => run_init(&cfg),
        "watch" => run_watch(&cfg),
        other => {
            eprintln!(
                "sftp-reconciled: unknown subcommand {:?} (expected init or watch)",
                other
            );
            std::process::exit(1);
        }
    }
}
