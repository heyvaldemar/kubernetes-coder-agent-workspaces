#!/usr/bin/env bash
# coder-session.sh - reach the Coder server from this machine and sign in as
# its first user, creating that user if the deployment has none yet.
#
# Prints three lines for `eval`: CODER_URL, CODER_CONFIG_DIR and the
# port-forward's PID. Nothing else it writes goes to stdout.
#
#   eval "$(scripts/coder-session.sh)"
#
# The server is reached through `kubectl port-forward` on 127.0.0.1:${CODER_LOCAL_PORT:-7080}.
# The first user's password is generated here, written to a file only this
# user can read ($CODER_CONFIG_DIR/first-user-password, for the dashboard)
# and handed to `coder login` in its environment, never on a command line.
# The session token stays in $CODER_CONFIG_DIR, as `coder login` keeps it.
set -euo pipefail
cd "$(dirname "$0")/.."
port="${CODER_LOCAL_PORT:-7080}"
config="${CODER_CONFIG_DIR:-$PWD/.cache/coder-cli}"
mkdir -p "$config"
chmod 700 "$config"
url="http://127.0.0.1:$port"

if ! curl -fsS --max-time 2 "$url/healthz" >/dev/null 2>&1; then
  kubectl -n coder port-forward --address 127.0.0.1 svc/coder "$port:80" >"$config/port-forward.log" 2>&1 &
  pf=$!
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "$url/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS --max-time 2 "$url/healthz" >/dev/null 2>&1 || { echo "the Coder server did not answer on $url" >&2; cat "$config/port-forward.log" >&2; exit 1; }
else
  pf=""
fi

export CODER_URL="$url" CODER_CONFIG_DIR="$config"
if ! coder whoami >/dev/null 2>&1; then
  if [ ! -s "$config/first-user-password" ]; then
    (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(24))' >"$config/first-user-password")
  fi
  CODER_FIRST_USER_EMAIL=admin@example.com \
  CODER_FIRST_USER_USERNAME=admin \
  CODER_FIRST_USER_FULL_NAME=Admin \
  CODER_FIRST_USER_PASSWORD="$(cat "$config/first-user-password")" \
  CODER_FIRST_USER_TRIAL=false \
    coder login "$url" >"$config/login.log" 2>&1 || { echo "coder login failed:" >&2; cat "$config/login.log" >&2; exit 1; }
fi
printf 'export CODER_URL=%q\nexport CODER_CONFIG_DIR=%q\nexport CODER_PORT_FORWARD_PID=%q\n' "$url" "$config" "$pf"
