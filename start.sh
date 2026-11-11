#!/bin/sh
# New API on Railway: create the admin account from ADMIN_USERNAME / ADMIN_PASSWORD
# on a private port before the public port opens, close public sign-up, then run on $PORT.
set -eu
export ERROR_LOG_ENABLED="${ERROR_LOG_ENABLED:-true}"
export BATCH_UPDATE_ENABLED="${BATCH_UPDATE_ENABLED:-true}"
export TZ="${TZ:-UTC}"
export NODE_NAME="${NODE_NAME:-new-api-railway}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
LOG_DIR=/data/logs
mkdir -p "$LOG_DIR"
B=http://127.0.0.1:3999
# The database may still be starting, so retry the private start for up to ~3 minutes.
PORT=3999 /new-api --log-dir "$LOG_DIR" &
PID=$!
i=0
until wget -qO- "$B/api/status" >/dev/null 2>&1; do
  i=$((i+1))
  [ "$i" -gt 180 ] && { echo "[setup] New API did not start"; exit 1; }
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "[setup] waiting for the database..."; sleep 4
    PORT=3999 /new-api --log-dir "$LOG_DIR" &
    PID=$!
  fi
  sleep 1
done
if wget -qO- "$B/api/setup" | grep -q '"status":false'; then
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set for the first start}"
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  U=$(esc "$ADMIN_USERNAME"); P=$(esc "$ADMIN_PASSWORD")
  echo "[setup] first start: creating admin account '$ADMIN_USERNAME'"
  wget -qO- --header='Content-Type: application/json' \
    --post-data="{\"username\":\"$U\",\"password\":\"$P\",\"confirmPassword\":\"$P\",\"SelfUseModeEnabled\":${NEW_API_SELF_USE_MODE:-true},\"DemoSiteEnabled\":false}" \
    "$B/api/setup" | grep -q '"success":true' || { echo "[setup] admin creation failed"; exit 1; }
  wget -qO /tmp/login.json --header='Content-Type: application/json' \
    --post-data="{\"username\":\"$U\",\"password\":\"$P\"}" "$B/api/user/login"
  TOKEN=$(sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' /tmp/login.json)
  USER_ID=$(sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' /tmp/login.json)
  rm -f /tmp/login.json
  wget -qO- --header="Authorization: Bearer $TOKEN" --header="New-Api-User: $USER_ID" --header='Content-Type: application/json' \
    --method=PUT --body-data='{"key":"RegisterEnabled","value":"false"}' "$B/api/option/" | grep -q '"success":true' \
    && echo "[setup] public sign-up disabled" || { echo "[setup] could not disable sign-up"; exit 1; }
fi
kill "$PID"; wait "$PID" 2>/dev/null || true
echo "[setup] starting New API on port ${PORT:-3000}"
exec /new-api --log-dir "$LOG_DIR"
