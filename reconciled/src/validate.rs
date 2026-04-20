//! Validates and derives every environment-driven setting, in one place,
//! before anything else runs. Fail fast: all violations reported at once.

use std::env;
use std::fs;
use std::time::Duration;

pub struct RuntimeConfig {
    pub sshd_log_level: String,
    pub sftp_log_level: String,
    pub project_mode: u32,
    pub reconcile_interval: Duration,
    pub sftp_users_gid: u32,
    pub reset_users: bool,
    pub reset_projects: bool,
    pub password_auth_enabled: bool,
    pub address_family_line: String,
    pub enable_pubkey_auth: &'static str,
    pub enable_password_auth: &'static str,
    pub authorized_keys_file: String,
    pub trusted_ca_keys_line: String,
    pub authentication_methods_line: String,
    pub metrics_socat_addr: String,
}

const LOG_LEVELS: [&str; 9] = [
    "QUIET", "FATAL", "ERROR", "INFO", "VERBOSE", "DEBUG", "DEBUG1", "DEBUG2", "DEBUG3",
];

const AUTH_MODES: [&str; 9] = [
    "pubkey",
    "cert",
    "pubkey|cert",
    "password",
    "pubkey|password",
    "cert|password",
    "any",
    "pubkey,password",
    "cert,password",
];

fn env_var(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_string())
}

fn parse_octal_mode(s: &str) -> Option<u32> {
    if s.len() == 3 && s.chars().all(|c| ('0'..='7').contains(&c)) {
        u32::from_str_radix(s, 8).ok()
    } else {
        None
    }
}

fn secret_present(path: &str) -> bool {
    fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false)
}

pub fn validate_env() -> Result<RuntimeConfig, Vec<String>> {
    let mut errors: Vec<String> = Vec::new();

    let sshd_log_level = env_var("SSHD_LOG_LEVEL", "INFO");
    if !LOG_LEVELS.contains(&sshd_log_level.as_str()) {
        errors.push(format!("invalid SSHD_LOG_LEVEL: {}", sshd_log_level));
    }

    let sftp_log_level = env_var("SFTP_LOG_LEVEL", "ERROR");
    if !LOG_LEVELS.contains(&sftp_log_level.as_str()) {
        errors.push(format!("invalid SFTP_LOG_LEVEL: {}", sftp_log_level));
    }

    let project_mode_raw = env_var("SFTP_PROJECT_MODE", "770");
    let project_mode = parse_octal_mode(&project_mode_raw).unwrap_or_else(|| {
        errors.push(format!(
            "SFTP_PROJECT_MODE must be a 3-digit octal value (e.g. 770), got: {}",
            project_mode_raw
        ));
        0o770
    });

    let reconcile_interval_raw = env_var("SFTP_RECONCILE_INTERVAL", "15");
    let reconcile_interval_secs = match reconcile_interval_raw.parse::<u64>() {
        Ok(n) if n >= 5 => n,
        Ok(_) => {
            errors.push("SFTP_RECONCILE_INTERVAL must be >= 5 seconds".to_string());
            15
        }
        Err(_) => {
            errors.push(format!(
                "SFTP_RECONCILE_INTERVAL must be a positive integer, got: {}",
                reconcile_interval_raw
            ));
            15
        }
    };

    let sftp_users_gid_raw = env_var("SFTP_USERS_GID", "59999");
    let sftp_users_gid = match sftp_users_gid_raw.parse::<u32>() {
        Ok(g) if (1000..60000).contains(&g) => g,
        Ok(g) => {
            errors.push(format!("SFTP_USERS_GID {} must be in range 1000-59999", g));
            59999
        }
        Err(_) => {
            errors.push(format!(
                "SFTP_USERS_GID must be a positive integer, got: {}",
                sftp_users_gid_raw
            ));
            59999
        }
    };

    let ipv4 = env_var("SSHD_ENABLE_IPV4", "yes");
    let ipv6 = env_var("SSHD_ENABLE_IPV6", "yes");
    if ipv4 != "yes" && ipv4 != "no" {
        errors.push(format!(
            "invalid SSHD_ENABLE_IPV4: {} (expected yes or no)",
            ipv4
        ));
    }
    if ipv6 != "yes" && ipv6 != "no" {
        errors.push(format!(
            "invalid SSHD_ENABLE_IPV6: {} (expected yes or no)",
            ipv6
        ));
    }
    if ipv4 != "yes" && ipv6 != "yes" {
        errors.push("SSHD_ENABLE_IPV4 and SSHD_ENABLE_IPV6 cannot both be no".to_string());
    }
    let address_family_line = match (ipv4.as_str(), ipv6.as_str()) {
        ("yes", "yes") => "AddressFamily any",
        ("yes", _) => "AddressFamily inet",
        _ => "AddressFamily inet6",
    }
    .to_string();

    let auth_mode = env_var("SFTP_AUTH_MODE", "pubkey");
    if !AUTH_MODES.contains(&auth_mode.as_str()) {
        errors.push(format!(
            "invalid SFTP_AUTH_MODE: {} (valid: pubkey, cert, pubkey|cert, password, \
             pubkey|password, cert|password, any, pubkey,password, cert,password)",
            auth_mode
        ));
    }
    let (needs_pubkey_auth, needs_password_auth, needs_ca, needs_authkeys, needs_2fa) =
        if auth_mode == "any" {
            (true, true, false, true, false)
        } else {
            let authkeys = auth_mode.contains("pubkey");
            let ca = auth_mode.contains("cert");
            (
                authkeys || ca,
                auth_mode.contains("password"),
                ca,
                authkeys,
                auth_mode.contains(','),
            )
        };

    let enable_pubkey_auth = if needs_pubkey_auth { "yes" } else { "no" };
    let enable_password_auth = if needs_password_auth { "yes" } else { "no" };
    let authorized_keys_file = if needs_authkeys {
        "/run/secrets/%u.authorized_keys".to_string()
    } else {
        "none".to_string()
    };
    let trusted_ca_keys_line = if needs_ca {
        "TrustedUserCAKeys /run/secrets/ssh_user_ca.pub".to_string()
    } else {
        String::new()
    };
    let authentication_methods_line = if needs_2fa {
        "AuthenticationMethods publickey,password".to_string()
    } else {
        String::new()
    };

    let metrics_bind = env_var("SFTP_METRICS_BIND", "0.0.0.0");
    if metrics_bind.is_empty() || metrics_bind.contains(' ') {
        errors.push(format!("invalid SFTP_METRICS_BIND: {}", metrics_bind));
    }
    let metrics_socat_addr = if metrics_bind.contains(':') {
        format!("TCP6-LISTEN:9100,reuseaddr,fork,bind={}", metrics_bind)
    } else if metrics_bind == "0.0.0.0" {
        "TCP6-LISTEN:9100,reuseaddr,fork,ipv6only=0".to_string()
    } else {
        format!("TCP4-LISTEN:9100,reuseaddr,fork,bind={}", metrics_bind)
    };

    if !secret_present("/run/secrets/ssh_host_ed25519_key") {
        errors.push(
            "/run/secrets/ssh_host_ed25519_key is missing or empty. Mount the host key as a \
             Docker secret named ssh_host_ed25519_key."
                .to_string(),
        );
    }
    if needs_ca && !secret_present("/run/secrets/ssh_user_ca.pub") {
        errors.push(format!(
            "SFTP_AUTH_MODE={} requires a CA public key. Mount it as a Docker secret named \
             ssh_user_ca.pub.",
            auth_mode
        ));
    }

    // Intentionally unvalidated: any value other than "no" means reset=on.
    let reset_users = env_var("SFTP_RESET_USERS", "yes") != "no";
    let reset_projects = env_var("SFTP_RESET_PROJECTS", "yes") != "no";

    if !errors.is_empty() {
        return Err(errors);
    }

    Ok(RuntimeConfig {
        sshd_log_level,
        sftp_log_level,
        project_mode,
        reconcile_interval: Duration::from_secs(reconcile_interval_secs),
        sftp_users_gid,
        reset_users,
        reset_projects,
        password_auth_enabled: needs_password_auth,
        address_family_line,
        enable_pubkey_auth,
        enable_password_auth,
        authorized_keys_file,
        trusted_ca_keys_line,
        authentication_methods_line,
        metrics_socat_addr,
    })
}
