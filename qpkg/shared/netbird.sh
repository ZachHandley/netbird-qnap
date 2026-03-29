#!/bin/sh
# Netbird VPN QPKG service script for QNAP NAS
# Handles start/stop/restart/status/remove via QNAP's service management

CONF=/etc/config/qpkg.conf
QPKG_NAME="netbird"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
NETBIRD_BIN="${QPKG_ROOT}/netbird"
NETBIRD_CONF="${QPKG_ROOT}/netbird.conf"
PIDF="/var/run/netbird.pid"

export QNAP_QPKG=$QPKG_NAME

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
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        exit 1
    fi

    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        echo "$QPKG_NAME is already running."
        return 0
    fi

    if [ ! -x "$NETBIRD_BIN" ]; then
        echo "Error: netbird binary not found at $NETBIRD_BIN"
        exit 1
    fi

    export_nb_env

    _log_file="${NB_LOG_FILE:-/var/log/netbird.log}"
    _log_level="${NB_LOG_LEVEL:-info}"

    mkdir -p /etc/netbird 2>/dev/null
    ln -sf "$NETBIRD_BIN" /usr/local/bin/netbird 2>/dev/null

    # Start web UI server (busybox httpd serves static files + CGI)
    pkill -f "busybox httpd -p 58090" 2>/dev/null
    busybox httpd -p 58090 -h "${QPKG_ROOT}/web"

    echo "Starting $QPKG_NAME..."

    # Start the netbird daemon (creates gRPC socket for netbird up/down/status)
    "$NETBIRD_BIN" service run \
        --log-file "$_log_file" \
        --log-level "$_log_level" \
        > /dev/null 2>&1 &

    echo $! > "$PIDF"

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
        echo "Warning: netbird daemon socket not ready after 15 seconds"
        echo "Check $_log_file for errors"
        return 1
    fi

    # Bring tunnel up if setup key is configured
    if [ -n "$NB_SETUP_KEY" ]; then
        # shellcheck disable=SC2086
        "$NETBIRD_BIN" up $EXTRA_ARGS 2>&1
    else
        echo "No SETUP_KEY configured. Daemon started but tunnel not activated."
        echo "Edit $NETBIRD_CONF and set SETUP_KEY, then restart the service."
    fi

    /sbin/log_tool -t2 -uSystem -p127.0.0.1 -mlocalhost -a "Netbird VPN service started"
    echo "$QPKG_NAME started."
}

stop_service() {
    echo "Stopping $QPKG_NAME..."

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

    # Stop web UI server
    pkill -f "busybox httpd -p 58090" 2>/dev/null

    killall netbird 2>/dev/null
    rm -f /usr/local/bin/netbird 2>/dev/null

    /sbin/log_tool -t2 -uSystem -p127.0.0.1 -mlocalhost -a "Netbird VPN service stopped"
    echo "$QPKG_NAME stopped."
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
