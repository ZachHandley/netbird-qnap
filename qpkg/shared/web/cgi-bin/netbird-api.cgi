#!/bin/sh
# Netbird VPN CGI API for QNAP web UI
# Handles: load config, save config, service status, restart

CONF=/etc/config/qpkg.conf
QPKG_NAME="netbird"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
NETBIRD_CONF="${QPKG_ROOT}/netbird.conf"
NETBIRD_BIN="${QPKG_ROOT}/netbird"

# Read POST body
read_body() {
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null
    fi
}

# Output JSON response
json_response() {
    printf 'Content-Type: application/json\r\n\r\n'
    printf '%s' "$1"
}

# Extract a JSON string value (simple parser for flat objects)
json_val() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

# Load config and return as JSON
do_load() {
    SETUP_KEY="" MANAGEMENT_URL="" ADMIN_URL="" HOSTNAME="" LOG_LEVEL="" LOG_FILE="" EXTRA_ARGS=""
    if [ -f "$NETBIRD_CONF" ]; then
        # shellcheck source=/dev/null
        . "$NETBIRD_CONF"
    fi
    json_response "{\"config\":{\"SETUP_KEY\":\"$SETUP_KEY\",\"MANAGEMENT_URL\":\"$MANAGEMENT_URL\",\"ADMIN_URL\":\"$ADMIN_URL\",\"HOSTNAME\":\"$HOSTNAME\",\"LOG_LEVEL\":\"$LOG_LEVEL\",\"LOG_FILE\":\"$LOG_FILE\",\"EXTRA_ARGS\":\"$EXTRA_ARGS\"}}"
}

# Save config from JSON body
do_save() {
    BODY="$1"
    SK=$(json_val "$BODY" "SETUP_KEY")
    MU=$(json_val "$BODY" "MANAGEMENT_URL")
    AU=$(json_val "$BODY" "ADMIN_URL")
    HN=$(json_val "$BODY" "HOSTNAME")
    LL=$(json_val "$BODY" "LOG_LEVEL")
    LF=$(json_val "$BODY" "LOG_FILE")
    EA=$(json_val "$BODY" "EXTRA_ARGS")

    cat > "$NETBIRD_CONF" <<CONF
# Netbird VPN Configuration for QNAP
# Managed by the Netbird web UI. Manual edits are preserved on save.

SETUP_KEY="$SK"
MANAGEMENT_URL="$MU"
ADMIN_URL="$AU"
HOSTNAME="$HN"
LOG_LEVEL="$LL"
LOG_FILE="$LF"
EXTRA_ARGS="$EA"
CONF

    json_response '{"ok":true}'
}

# Get service status
do_status() {
    if [ -x "$NETBIRD_BIN" ] && [ -S /var/run/netbird.sock ]; then
        STATUS=$("$NETBIRD_BIN" status 2>&1)
    else
        STATUS="Service not running"
    fi
    # Escape for JSON
    STATUS=$(printf '%s' "$STATUS" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
    json_response "{\"status\":\"$STATUS\"}"
}

# Restart service
do_restart() {
    if [ -x "${QPKG_ROOT}/netbird.sh" ]; then
        "${QPKG_ROOT}/netbird.sh" restart > /dev/null 2>&1 &
    fi
    json_response '{"ok":true}'
}

# Route request
BODY=$(read_body)
ACTION=$(json_val "$BODY" "action")

case "$ACTION" in
    load)    do_load ;;
    save)    do_save "$BODY" ;;
    status)  do_status ;;
    restart) do_restart ;;
    *)       json_response '{"error":"unknown action"}' ;;
esac
