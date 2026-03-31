#!/bin/sh
# Netbird VPN QPKG service script for QNAP NAS
# Handles start/stop/restart/status/remove via QNAP's service management

CONF=/etc/config/qpkg.conf
QPKG_NAME="netbird"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
NETBIRD_BIN="${QPKG_ROOT}/netbird"
NETBIRD_CONF="${QPKG_ROOT}/netbird.conf"
PIDF="/var/run/netbird.pid"
SVCLOG="/var/log/netbird-service.log"
APACHE_CONF="/etc/default_config/apache-netbird.conf"

export QNAP_QPKG=$QPKG_NAME

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SVCLOG"
    echo "$1"
}

load_config() {
    if [ -f "$NETBIRD_CONF" ]; then
        # shellcheck source=/dev/null
        . "$NETBIRD_CONF"
    fi
}

export_nb_env() {
    load_config
    [ -n "$SETUP_KEY" ]      && export NB_SETUP_KEY="$SETUP_KEY"
    [ -n "$MANAGEMENT_URL" ] && export NB_MANAGEMENT_URL="$MANAGEMENT_URL"
    [ -n "$ADMIN_URL" ]      && export NB_ADMIN_URL="$ADMIN_URL"
    [ -n "$HOSTNAME" ]       && export NB_HOSTNAME="$HOSTNAME"
    [ -n "$LOG_LEVEL" ]      && export NB_LOG_LEVEL="$LOG_LEVEL"
    [ -n "$LOG_FILE" ]       && export NB_LOG_FILE="$LOG_FILE"
}

setup_webui() {
    # Drop-in proxy config (WordPress containerized QPKG pattern)
    # /etc/container-proxy.d/ is auto-included by QTS Apache
    _proxy_dir="/etc/container-proxy.d"
    if [ -d "$_proxy_dir" ]; then
        log "Using container-proxy.d drop-in"
    else
        mkdir -p "$_proxy_dir" 2>/dev/null
        log "Created $_proxy_dir"
    fi

    # Alias directive serves files directly from QPKG_ROOT (no symlinks needed)
    cat > "${_proxy_dir}/netbird.conf" <<AEOF
Alias /netbird "${QPKG_ROOT}/web"
<Directory "${QPKG_ROOT}/web">
  Require all granted
</Directory>
ProxyPass /netbird !
AEOF
    log "Created ${_proxy_dir}/netbird.conf"

    # Also write the standalone config as fallback
    cat > "$APACHE_CONF" <<AEOF
Alias /netbird "${QPKG_ROOT}/web"
<Directory "${QPKG_ROOT}/web">
  Require all granted
</Directory>
ProxyPass /netbird !
AEOF

    # Try CrashPlan-style Include into Apache proxy configs
    for _pf in /etc/config/apache/extra/apache-proxy.conf /etc/default_config/apache/extra/apache-proxy.conf; do
        if [ -f "$_pf" ] && ! grep -q "apache-netbird.conf" "$_pf"; then
            echo "Include ${APACHE_CONF}" >> "$_pf"
            log "Added Include to $_pf"
        fi
    done

    # Reload web servers
    if [ -x /etc/init.d/thttpd.sh ]; then
        /etc/init.d/thttpd.sh reload 2>>"$SVCLOG"
        log "Reloaded thttpd"
    fi
    if [ -x /etc/init.d/stunnel.sh ]; then
        /etc/init.d/stunnel.sh reload 2>>"$SVCLOG"
        log "Reloaded stunnel"
    fi

    # CGI symlink (confirmed working on this NAS)
    ln -sf "${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi" /home/httpd/cgi-bin/netbird-api.cgi
    if [ -L /home/httpd/cgi-bin/netbird-api.cgi ]; then
        log "CGI symlink OK"
    else
        log "ERROR: Failed to create CGI symlink"
    fi
}

teardown_webui() {
    # Remove drop-in proxy config
    rm -f /etc/container-proxy.d/netbird.conf 2>/dev/null
    rm -f "$APACHE_CONF"

    # Remove Include lines from Apache proxy configs
    for _pf in /etc/config/apache/extra/apache-proxy.conf /etc/default_config/apache/extra/apache-proxy.conf; do
        [ -f "$_pf" ] && sed -i '/apache-netbird\.conf/d' "$_pf" 2>/dev/null
    done

    # Reload web servers
    [ -x /etc/init.d/thttpd.sh ] && /etc/init.d/thttpd.sh reload 2>/dev/null
    [ -x /etc/init.d/stunnel.sh ] && /etc/init.d/stunnel.sh reload 2>/dev/null

    # Remove CGI symlink and stale web root symlinks
    rm -f /home/httpd/cgi-bin/netbird-api.cgi
    rm -f /home/Qhttpd/Web/netbird 2>/dev/null
}

start_service() {
    log "=== START ==="
    log "QPKG_ROOT=$QPKG_ROOT"

    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        log "ABORT: $QPKG_NAME is disabled (Enable=$ENABLED)"
        exit 1
    fi

    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        log "$QPKG_NAME is already running (PID: $(cat "$PIDF"))"
        return 0
    fi

    if [ ! -x "$NETBIRD_BIN" ]; then
        log "ABORT: netbird binary not found at $NETBIRD_BIN"
        exit 1
    fi

    export_nb_env

    _log_file="${NB_LOG_FILE:-/var/log/netbird.log}"
    _log_level="${NB_LOG_LEVEL:-info}"

    mkdir -p /etc/netbird 2>/dev/null
    ln -sf "$NETBIRD_BIN" /usr/local/bin/netbird 2>/dev/null

    # Clean stale config from previous versions
    pkill -f "busybox httpd -p 58090" 2>/dev/null
    pkill -f "busybox httpd -p 8090" 2>/dev/null

    # Set up web UI
    setup_webui

    # Log qpkg.conf state for debugging
    log "qpkg.conf: WebUI=$(/sbin/getcfg $QPKG_NAME WebUI -f $CONF 2>/dev/null) Web_Port=$(/sbin/getcfg $QPKG_NAME Web_Port -f $CONF 2>/dev/null)"

    # Start netbird daemon
    log "Starting netbird daemon..."

    "$NETBIRD_BIN" service run \
        --log-file "$_log_file" \
        --log-level "$_log_level" \
        > /dev/null 2>&1 &

    echo $! > "$PIDF"
    log "Daemon PID: $(cat "$PIDF")"

    # Wait for daemon socket
    _retries=0
    while [ $_retries -lt 15 ]; do
        if [ -S /var/run/netbird.sock ]; then
            break
        fi
        sleep 1
        _retries=$((_retries + 1))
    done

    if [ ! -S /var/run/netbird.sock ]; then
        log "WARNING: daemon socket not ready after 15 seconds (check $_log_file)"
        return 1
    fi
    log "Daemon socket ready"

    # Bring tunnel up only if setup key is configured
    if [ -n "$NB_SETUP_KEY" ]; then
        log "Setup key found, running 'netbird up'"
        # shellcheck disable=SC2086
        "$NETBIRD_BIN" up $EXTRA_ARGS >> "$SVCLOG" 2>&1
    else
        log "No SETUP_KEY configured. Daemon running but tunnel not activated."
        log "Configure via web UI at /netbird/ or edit $NETBIRD_CONF"
    fi

    /sbin/log_tool -t1 -uSystem -p127.0.0.1 -mlocalhost -a "Netbird VPN service started"
    log "=== START COMPLETE ==="
}

stop_service() {
    log "=== STOP ==="

    if [ -S /var/run/netbird.sock ]; then
        "$NETBIRD_BIN" down 2>/dev/null
    fi

    if [ -f "$PIDF" ]; then
        _pid=$(cat "$PIDF")
        if kill -0 "$_pid" 2>/dev/null; then
            kill "$_pid" 2>/dev/null
            _retries=0
            while [ $_retries -lt 10 ] && kill -0 "$_pid" 2>/dev/null; do
                sleep 1
                _retries=$((_retries + 1))
            done
            if kill -0 "$_pid" 2>/dev/null; then
                kill -9 "$_pid" 2>/dev/null
            fi
        fi
        rm -f "$PIDF"
    fi

    teardown_webui

    pkill -f "busybox httpd -p 58090" 2>/dev/null
    pkill -f "busybox httpd -p 8090" 2>/dev/null

    killall netbird 2>/dev/null
    rm -f /usr/local/bin/netbird 2>/dev/null

    /sbin/log_tool -t1 -uSystem -p127.0.0.1 -mlocalhost -a "Netbird VPN service stopped"
    log "=== STOP COMPLETE ==="
}

case "$1" in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        sleep 2
        start_service
        ;;
    status)
        if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
            echo "$QPKG_NAME is running (PID: $(cat "$PIDF"))"
            "$NETBIRD_BIN" status 2>/dev/null
        else
            echo "$QPKG_NAME is not running."
            exit 1
        fi
        ;;
    remove)
        stop_service
        rm -f /usr/local/bin/netbird 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|remove}"
        exit 1
        ;;
esac

exit 0
