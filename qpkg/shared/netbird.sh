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

    # --- Web UI setup (symlink pattern, matching QNAP official examples) ---
    # Clean stale Web_Port from previous installs that used busybox httpd
    _old_port=$(/sbin/getcfg $QPKG_NAME Web_Port -f $CONF 2>/dev/null)
    if [ -n "$_old_port" ]; then
        log "Clearing stale Web_Port=$_old_port from qpkg.conf"
        /sbin/setcfg $QPKG_NAME Web_Port "" -f $CONF 2>/dev/null
    fi

    # Kill any leftover busybox httpd from previous versions
    pkill -f "busybox httpd -p 58090" 2>/dev/null
    pkill -f "busybox httpd -p 8090" 2>/dev/null

    # Create symlinks (same approach as QNAP's breakout, helloWorld, ZeroTier QPKGs)
    ln -sf "${QPKG_ROOT}/web" /home/Qhttpd/Web/netbird
    if [ -L /home/Qhttpd/Web/netbird ]; then
        log "Web symlink OK: /home/Qhttpd/Web/netbird -> $(readlink /home/Qhttpd/Web/netbird)"
    else
        log "ERROR: Failed to create web symlink at /home/Qhttpd/Web/netbird"
    fi

    ln -sf "${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi" /home/httpd/cgi-bin/netbird-api.cgi
    if [ -L /home/httpd/cgi-bin/netbird-api.cgi ]; then
        log "CGI symlink OK: /home/httpd/cgi-bin/netbird-api.cgi -> $(readlink /home/httpd/cgi-bin/netbird-api.cgi)"
    else
        log "ERROR: Failed to create CGI symlink at /home/httpd/cgi-bin/netbird-api.cgi"
    fi

    # Verify web files exist
    if [ -f "${QPKG_ROOT}/web/index.html" ]; then
        log "Web files OK: ${QPKG_ROOT}/web/index.html exists"
    else
        log "ERROR: ${QPKG_ROOT}/web/index.html NOT FOUND"
    fi
    if [ -f "${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi" ]; then
        log "CGI script OK: ${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi exists"
    else
        log "ERROR: ${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi NOT FOUND"
    fi

    # Log qpkg.conf state for debugging
    log "qpkg.conf entries:"
    log "  Enable=$(/sbin/getcfg $QPKG_NAME Enable -f $CONF 2>/dev/null)"
    log "  Web_Port=$(/sbin/getcfg $QPKG_NAME Web_Port -f $CONF 2>/dev/null)"
    log "  WebUI=$(/sbin/getcfg $QPKG_NAME WebUI -f $CONF 2>/dev/null)"
    log "  Proxy_Path=$(/sbin/getcfg $QPKG_NAME Proxy_Path -f $CONF 2>/dev/null)"
    log "  Use_Proxy=$(/sbin/getcfg $QPKG_NAME Use_Proxy -f $CONF 2>/dev/null)"

    # --- Start netbird daemon ---
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

    # Remove web UI symlinks
    rm -f /home/Qhttpd/Web/netbird
    rm -f /home/httpd/cgi-bin/netbird-api.cgi

    # Kill any leftover busybox httpd from previous versions
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
