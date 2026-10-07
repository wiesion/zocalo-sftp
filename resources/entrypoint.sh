#!/bin/sh
set -eu

#=============================================================================
# FUNCTIONS: Signal handlers
#=============================================================================
handle_shutdown() {
    printf '%s\n' "Received shutdown signal, stopping SSHD gracefully..."
    _exit_code=0
    if [ -n "$SSHD_PID" ] && kill -0 "$SSHD_PID" 2>/dev/null; then
        # Send TERM signal to sshd for graceful shutdown
        # sshd will stop accepting new connections but allow existing transfers to complete
        kill -TERM "$SSHD_PID"
        # Poll up to 30 s then SIGKILL to avoid hanging indefinitely
        _waited=0
        while [ "$_waited" -lt 30 ]; do
            kill -0 "$SSHD_PID" 2>/dev/null || break
            sleep 1
            _waited=$((_waited + 1))
        done
        if kill -0 "$SSHD_PID" 2>/dev/null; then
            printf '%s\n' "sshd did not exit within 30 s, sending SIGKILL"
            kill -KILL "$SSHD_PID" 2>/dev/null || true
        fi
        wait "$SSHD_PID" 2>/dev/null || _exit_code=$?
    fi
    # Allow the log relay to drain the socket buffer before killing it
    sleep 1
    # Clean up background helpers so tini doesn't need to reap them
    if [ -n "$RECONCILE_PID" ]; then kill "$RECONCILE_PID" 2>/dev/null || true; fi
    if [ -n "$SFTP_LOG_PID" ]; then kill "$SFTP_LOG_PID" 2>/dev/null || true; fi
    exit "$_exit_code"
}

reload_config() {
    printf '%s\n' "Received HUP signal, reloading SSHD configuration..."
    if [ -n "$SSHD_PID" ] && kill -0 "$SSHD_PID" 2>/dev/null; then
        # SIGHUP reloads config and host keys without interrupting active sessions
        kill -HUP "$SSHD_PID"
    fi
}

#=============================================================================
# SIGNAL HANDLING: Trap signals (Tini forwards them to this script)
#=============================================================================
# Initialise PID variables before the trap is armed so that handle_shutdown
# and reload_config can safely reference them even if a signal arrives during
# the startup sequence before sshd/helpers have been launched (required by set -u).
SSHD_PID=
SFTP_LOG_PID=
RECONCILE_PID=
trap 'handle_shutdown' TERM INT
trap 'reload_config' HUP

# CONFIGURATION, VALIDATION, PROVISIONING: delegated to sftp-reconciled init.
# validates env vars, renders sshd_config, provisions users/projects, in that
# order. Exits non-zero (taking this script down via set -e) on any violation.
# stdout carries only the derived metrics socat address; init's own
# diagnostics go to stderr so they don't end up in this variable.
#=============================================================================
_metrics_addr=$(sftp-reconciled init)

# Fail fast with sshd's own diagnostics if the rendered config (including any
# operator drop-ins) is invalid, before any helper process is started.
/usr/bin/sshd -t

#=============================================================================
# CHROOT JAIL SETUP: Provide localtime and the syslog socket to the sftp jail
# (internal-sftp needs no device nodes, so no CAP_MKNOD is required)
#=============================================================================
mkdir -p /sftp-jail/dev
mkdir -p /sftp-jail/etc
# Copy localtime into the chroot for correct timestamps; skip if absent.
if [ -f /etc/localtime ]; then
    cp /etc/localtime /sftp-jail/etc/localtime
fi

# Use socat to relay syslog from jail to STDOUT (internal-sftp logs).
# mode=0666 is required so internal-sftp subprocesses (running as non-root
# users inside the chroot) can write to the syslog socket.
# Supervised restart loop: socat exits when the socket disappears; sleep 1
# prevents a spin loop while providing a brief reconnect window.
#
# internal-sftp only knows how to log via syslog; there is no "log to
# stdout" option, so this relay is not optional. Syslog datagrams (glibc
# SOCK_DGRAM) have no newline terminator, so we cannot use RS="\n" in awk.
# Every syslog message begins with a priority marker "<N>", so RS="<"
# splits the byte stream exactly on message boundaries. Records that do
# not start with digits are fragments or the empty record before the very
# first "<" and are discarded. Beyond framing the stream into lines, no
# further parsing happens here on purpose: turning this into structured
# fields (levels, timestamps, session correlation) is a log shipper's job,
# not this container's. See README.md#logging.
start_sftp_log() {
    while true; do
        rm -f /sftp-jail/dev/log
        socat -u UNIX-RECV:/sftp-jail/dev/log,mode=0666 STDOUT 2>/dev/null | \
        awk 'BEGIN { RS = "<" } /^[0-9]+>/ {
            sub(/^[0-9]+>/, ""); sub(/\r?\n$/, ""); if ($0 != "") { print; fflush() }
        }'
        sleep 1
    done
}
start_sftp_log &
SFTP_LOG_PID=$!

#=============================================================================
# METRICS SERVER: Optional; Start metrics HTTP server on port 9100
#=============================================================================
if [ "$SFTP_ENABLE_METRICS" = "yes" ]; then
    printf '%s\n' "Starting metrics HTTP server on ${SFTP_METRICS_BIND}:9100..."
    # fork=each scrape spawns a child (true concurrency).
    # Socat listen address is derived from SFTP_METRICS_BIND by sftp-reconciled
    # init above and captured into $_metrics_addr.
    # NOTE: Do not publish this port to the public internet. The endpoint is
    # unauthenticated and exposes username, project, and disk-usage information.
    # Redirect stderr: forked socat children emit ECONNRESET when Prometheus
    # closes the connection after a scrape, expected, not actionable noise.
    socat "$_metrics_addr" \
        SYSTEM:/usr/local/bin/metrics.sh 2>/dev/null &
fi

#=============================================================================
# SSHD STARTUP: Background SSHD to allow signal handling
#=============================================================================
"$@" 2>&1 &
SSHD_PID=$!

#=============================================================================
# RECONCILE DAEMON: sftp-reconciled watches /config/.generation via inotify
# and converges /etc/passwd, /etc/shadow, /etc/group on every change.
# Falls back to polling every SFTP_RECONCILE_INTERVAL seconds.
#=============================================================================
sftp-reconciled watch &
RECONCILE_PID=$!

# Wait for SSHD to exit (keeps entrypoint.sh as the main process)
wait "$SSHD_PID"
