#!/bin/sh
set -eu
# Prometheus metrics exporter for SFTP server
#
# When invoked by socat (stdout connected to a socket, not a terminal),
# emits HTTP/1.1 headers before the metrics body so the response is a
# valid HTTP reply.  When run interactively the headers are suppressed.
if [ ! -t 1 ]; then
    printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nConnection: close\r\n\r\n'
fi

# Single ps pass: derive both connection count and unique-user count from
# the same snapshot so the two metrics are consistent.
# 'args' is the POSIX column name for the full command line.
_sftp_procs=$(ps -o user,args 2>/dev/null | grep "[i]nternal-sftp" || true)
ACTIVE_CONNS=0
ACTIVE_USERS=0
if [ -n "$_sftp_procs" ]; then
    ACTIVE_CONNS=$(printf '%s\n' "$_sftp_procs" | wc -l | tr -d ' ')
    ACTIVE_USERS=$(printf '%s\n' "$_sftp_procs" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
fi

# Disk usage for projects directory: single df call to keep values consistent
DISK_USED_KB=0
DISK_AVAIL_KB=0
DISK_TOTAL_KB=0
if [ -d /sftp-jail/projects ]; then
    _df=$(df -k /sftp-jail/projects 2>/dev/null | awk 'NR==2{printf "%s %s %s",$2,$3,$4}')
    if [ -n "$_df" ]; then
        DISK_TOTAL_KB=${_df%% *}
        _df=${_df#* }
        DISK_USED_KB=${_df%% *}
        DISK_AVAIL_KB=${_df##* }
    fi
fi

# Per-project disk usage with a 5-minute cache to avoid hammering I/O on
# every scrape.  The trailing slash on the glob ensures the pattern expands
# to directories only and does not match files; the [ -d ] guard handles the
# case where the projects directory is empty and the shell returns the literal
# glob pattern unexpanded.
_CACHE=/tmp/sftp_du_cache
PROJECT_DISK_USAGE=""
if [ -s "$_CACHE" ] && [ -n "$(find "$_CACHE" -mmin -5 2>/dev/null)" ]; then
    PROJECT_DISK_USAGE=$(cat "$_CACHE")
else
    for project in /sftp-jail/projects/*/; do
        [ -d "$project" ] || continue
        size=$(du -sk "$project" 2>/dev/null | cut -f1 || echo 0)
        name=$(basename "$project")
        PROJECT_DISK_USAGE="${PROJECT_DISK_USAGE}sftp_project_disk_kb{project=\"$name\"} $size
"
    done
    printf '%s' "$PROJECT_DISK_USAGE" > "$_CACHE"
fi

# Output Prometheus format
cat <<EOF
# HELP sftp_active_connections Number of active SFTP connections
# TYPE sftp_active_connections gauge
sftp_active_connections $ACTIVE_CONNS

# HELP sftp_active_users Number of unique users currently connected
# TYPE sftp_active_users gauge
sftp_active_users $ACTIVE_USERS

# HELP sftp_disk_used_kb Disk space used in projects directory (KB)
# TYPE sftp_disk_used_kb gauge
sftp_disk_used_kb $DISK_USED_KB

# HELP sftp_disk_available_kb Disk space available in projects directory (KB)
# TYPE sftp_disk_available_kb gauge
sftp_disk_available_kb $DISK_AVAIL_KB

# HELP sftp_disk_total_kb Total disk space in projects directory (KB)
# TYPE sftp_disk_total_kb gauge
sftp_disk_total_kb $DISK_TOTAL_KB

# HELP sftp_project_disk_kb Disk usage per project (KB)
# TYPE sftp_project_disk_kb gauge
$PROJECT_DISK_USAGE
EOF
