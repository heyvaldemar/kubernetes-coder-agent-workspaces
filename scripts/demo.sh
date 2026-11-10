#!/usr/bin/env bash
# demo.sh - a first workspace on the cluster `make up` made: sign in as the
# first user, push the template, start a workspace named demo and run a few
# commands inside it, then say how to open the dashboard.
#
# docs/first-workspace.md walks the same steps by hand. The port-forward this
# starts keeps running for the dashboard; `make down` ends it with the
# cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
eval "$(scripts/coder-session.sh)"

github=false
kubectl -n coder get secret coder-github >/dev/null 2>&1 && github=true
coder templates push agent-workspace -d templates/agent-workspace --variable "github_external_auth=$github" --yes >/dev/null
echo "pushed the template agent-workspace (GitHub external auth declared: $github)"

if ! coder list -o json | jq -e '.[] | select(.name == "demo")' >/dev/null; then
  coder create demo --template agent-workspace --yes >/dev/null
  echo "created the workspace demo"
fi
for _ in $(seq 1 30); do coder ssh demo -- true >/dev/null 2>&1 && break; sleep 5; done

echo
echo "== inside the workspace"
# shellcheck disable=SC2016  # expanded inside the workspace
coder ssh demo -- 'echo "kernel: $(uname -r)"; echo "user: $(id -un)"; c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://example.com/); echo "the internet: $([ "$c" = 000 ] && echo "no way out" || echo "HTTP $c")"; echo -n "the Coder server: "; curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://coder.coder.svc.cluster.local/healthz'

echo
echo "The dashboard: $CODER_URL (user admin@example.com; the password is in $CODER_CONFIG_DIR/first-user-password)"
echo "A shell in the workspace: CODER_URL=$CODER_URL CODER_CONFIG_DIR=$CODER_CONFIG_DIR coder ssh demo"
