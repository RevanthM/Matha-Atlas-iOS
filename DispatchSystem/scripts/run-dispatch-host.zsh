#!/bin/zsh

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

script_directory="${0:A:h}"
dispatch_root="${script_directory:h}"
relay_root="${dispatch_root}/RelayService"
agent_binary="${dispatch_root}/.build/release/local-gemma-agent"
relay_service="com.matha.atlas.DispatchRelay"
relay_account="local-development"

relay_token="$(/usr/bin/security find-generic-password -s "$relay_service" -a "$relay_account" -w)"
runtime_vars="${relay_root}/.dev.vars"
umask 077
/usr/bin/printf 'PAIRING_SECRET="%s"\n' "$relay_token" > "$runtime_vars"
/bin/chmod 600 "$runtime_vars"

cleanup() {
  if [[ -n "${relay_pid:-}" ]]; then
    kill "$relay_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cd "$relay_root"
"${relay_root}/node_modules/.bin/wrangler" dev \
  --ip 0.0.0.0 \
  --port 8787 &
relay_pid=$!

for attempt in {1..30}; do
  if /usr/bin/curl --silent --fail http://127.0.0.1:8787/health >/dev/null; then
    break
  fi
  /bin/sleep 1
done

if ! /usr/bin/curl --silent --fail http://127.0.0.1:8787/health >/dev/null; then
  print -u2 "Matha Atlas relay failed its health check."
  exit 1
fi

cd "$dispatch_root"
LOCAL_GEMMA_RELAY_TOKEN="$relay_token" "$agent_binary" serve &
agent_pid=$!
unset relay_token
wait "$agent_pid"
