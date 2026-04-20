//! Renders `/etc/ssh/sshd_config` from the template, using values
//! `validate::validate_env()` already derived. Atomic write (tmp + rename).

use std::fs;
use std::io;
use std::path::Path;

use crate::system::write_atomic;
use crate::validate::RuntimeConfig;

const TEMPLATE_PATH: &str = "/etc/ssh/sshd_config.template";
const OUTPUT_PATH: &str = "/etc/ssh/sshd_config";

pub fn render_sshd_config(cfg: &RuntimeConfig) -> io::Result<()> {
    let template = fs::read_to_string(TEMPLATE_PATH)?;

    let rendered = template
        .replace("__ADDRESS_FAMILY__", &cfg.address_family_line)
        .replace("__SSHD_LOG_LEVEL__", &cfg.sshd_log_level)
        .replace("__SFTP_LOG_LEVEL__", &cfg.sftp_log_level)
        .replace("__ENABLE_PASSWORD_AUTH__", cfg.enable_password_auth)
        .replace("__ENABLE_PUBKEY_AUTH__", cfg.enable_pubkey_auth)
        .replace(
            "__AUTHENTICATION_METHODS_LINE__",
            &cfg.authentication_methods_line,
        )
        .replace("__TRUSTED_CA_KEYS_LINE__", &cfg.trusted_ca_keys_line)
        .replace("__AUTHORIZED_KEYS_FILE__", &cfg.authorized_keys_file);

    write_atomic(
        Path::new(OUTPUT_PATH),
        0o644,
        rendered.lines().map(|l| l.to_string()),
    )
}
