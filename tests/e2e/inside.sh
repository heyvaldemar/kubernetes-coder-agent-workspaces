#!/usr/bin/env bash
# tests/e2e/inside.sh - what a fooled agent can reach from inside a Coder
# workspace, asked from inside one. tests/e2e/run.sh pipes it into
# `coder ssh <workspace> -- bash -s`, so it runs as a process the Coder agent
# started, the way an AI agent's shell would be.
#
# One JSON line per attempt, in the sandbox's agents' format:
#   {"check": ..., "expected": ..., "got": ..., "ok": true|false, "detail": ...}
# Each refusal has a control that must answer: the Coder server, and the
# resolver for a cluster name. A token's value is never printed: a credential
# is reported by its length, a key by the hash of its public half.
#
# Needs bash, curl, jq and coreutils, which Coder's minimal image has.
set -u
SERVER=http://coder.coder.svc.cluster.local
RESOLVER=10.96.0.53
CLUSTER_DNS=10.96.0.10

json() {  # check expected got [detail]
  jq -cn --arg c "$1" --arg e "$2" --arg g "$3" --arg d "${4:-}" \
    '{check: $c, expected: $e, got: $g, ok: ($e == $g)} + (if $d == "" then {} else {detail: $d} end)'
}
# reached or blocked: an HTTP status of any kind means the other end answered.
http() {  # url -> "reached <code>" | "blocked <curl exit>"
  local code rc=0
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" || rc=$?
  if [ "$code" != "000" ]; then echo "reached $code"; else echo "blocked $rc"; fi
}
why() {  # curl exit -> words
  case "$1" in 6) echo "the name did not resolve" ;; 7) echo "connection refused" ;; 28) echo "timed out" ;; *) echo "curl exit $1" ;; esac
}
tcp() {  # host port -> reached | blocked
  if timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then echo reached; else echo blocked; fi
}
# One DNS question over UDP, built by hand: no resolver library in between, so
# the answer is the server's. Prints "answered <rcode> <answers>" or "silent".
dns() {  # server name
  local q="" label reply
  local IFS=.
  for label in $2; do q+="$(printf '\\x%02x' "${#label}")$label"; done
  unset IFS
  exec 3<>"/dev/udp/$1/53" || { echo silent; return; }
  printf '%b' "\\x4a\\x51\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00${q}\\x00\\x00\\x01\\x00\\x01" >&3
  reply="$(timeout 3 dd bs=512 count=1 status=none <&3 | od -An -v -tx1 | tr -d ' \n')"
  exec 3<&- 3>&-
  if [ ${#reply} -lt 24 ]; then echo silent; return; fi
  echo "answered $((16#${reply:7:1})) $((16#${reply:12:4}))"
}
coder_api() {  # path -> "<http code> <body file>", the agent's token in a header read from stdin
  local out
  out="$(mktemp)"
  printf 'header = "Coder-Session-Token: %s"\n' "$CODER_AGENT_TOKEN" |
    curl -s -o "$out" -w '%{http_code}' --max-time 5 --config - "$SERVER$1"
  echo " $out"
}

# --- the kernel, and what the workspace holds ---------------------------------
kernel="$(uname -r)"
json "kernel is gVisor's, not the node's" gvisor "$([[ $kernel == *gvisor* ]] && echo gvisor || echo host)" "$kernel"
json "no Kubernetes API token on disk" absent \
  "$([ -e /var/run/secrets/kubernetes.io/serviceaccount/token ] && echo present || echo absent)"
json "the Coder agent hands its token to every process it starts" present \
  "$([ -n "${CODER_AGENT_TOKEN:-}" ] && echo present || echo absent)" "${#CODER_AGENT_TOKEN} characters, in this shell's environment"
pid1="$(tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -c '^CODER_AGENT_TOKEN=')"
json "the token is also in PID 1's environment, readable as the workspace user" present \
  "$([ "$pid1" -gt 0 ] && echo present || echo absent)" "$(tr '\0' ' ' </proc/1/cmdline 2>/dev/null | cut -c1-60)"
json "the image is read-only" refused "$( (: >/usr/local/bin/planted) 2>/dev/null && echo written || echo refused)"
json "sudo gets no root" refused "$(sudo -n true 2>/dev/null && echo root || echo refused)"

# --- the one door -------------------------------------------------------------
read -r state code <<<"$(http "$SERVER/healthz")"
json "control: the Coder server answers" reached "$state" "HTTP $code"

# --- everything else ----------------------------------------------------------
for target in "the internet by name|https://example.com/" \
              "the internet by IP address, past DNS|http://1.1.1.1/" \
              "the Kubernetes API by name|https://kubernetes.default.svc.cluster.local/version" \
              "the Kubernetes API by its Service address|https://10.96.0.1/version" \
              "the instance metadata service|http://169.254.169.254/latest/meta-data/" \
              "another namespace's service|http://internal.corp.svc.cluster.local:8080/"; do
  read -r state rc <<<"$(http "${target#*|}")"
  json "${target%%|*}" blocked "$state" "$([ "$state" = blocked ] && why "$rc" || echo "HTTP $rc")"
done
json "Coder's own Postgres" blocked "$(tcp postgres.coder.svc.cluster.local 5432)"

# --- DNS as a way out ---------------------------------------------------------
read -r state rcode answers <<<"$(dns "$RESOLVER" coder.coder.svc.cluster.local)"
json "control: the resolver answers a cluster name" answered "$state" "rcode ${rcode:-?}, ${answers:-0} answers"
read -r state rcode answers <<<"$(dns "$RESOLVER" "e2e-$RANDOM-$RANDOM.example.com")"
json "the resolver relays no outside name" "no answer" \
  "$([ "$state" = answered ] && [ "${answers:-0}" -gt 0 ] && echo answered || echo "no answer")" "${state}${rcode:+, rcode $rcode}"
read -r state rcode answers <<<"$(dns "$CLUSTER_DNS" example.com)"
json "the cluster's CoreDNS, which forwards, is out of reach" silent "$state"
json "an outside name through the system resolver" "no answer" \
  "$(getent hosts example.com >/dev/null 2>&1 && echo answered || echo "no answer")"

# --- the one credential, at the Coder API -------------------------------------
# (The external-auth call takes no "listen" parameter: its presence, whatever
# its value, makes the server hold the request until the owner signs in.)
read -r code body <<<"$(coder_api /api/v2/buildinfo)"
json "control: the Coder API answers" 200 "$code"
for path in /api/v2/users/me /api/v2/workspaces /api/v2/templates /api/v2/users; do
  read -r code body <<<"$(coder_api "$path")"
  json "the agent's token as a user's session at $path" 401 "$code"
  rm -f "$body"
done
read -r code body <<<"$(coder_api /api/v2/workspaceagents/me/gitsshkey)"
key_len="$(jq -r '.private_key // "" | length' "$body" 2>/dev/null)"
pub_hash="$(jq -r '.public_key // ""' "$body" 2>/dev/null | sha256sum | cut -c1-16)"
json "the agent's token fetches the owner's Git SSH private key" "returned" \
  "$([ "$code" = 200 ] && [ "${key_len:-0}" -gt 0 ] && echo returned || echo "HTTP $code")" \
  "HTTP $code, a private key of $key_len characters; sha256 of its public half $pub_hash"
rm -f "$body"
read -r code body <<<"$(coder_api '/api/v2/workspaceagents/me/external-auth?id=github')"
json "the agent's token asks for the owner's GitHub token" "answered" \
  "$([ "$code" = 200 ] && echo answered || echo "HTTP $code")" \
  "HTTP $code: $(jq -c '{type, url: (.url // "" | sub("^https?://[^/]+"; "")), access_token: ((.access_token // "") | if . == "" then "empty" else "\(length) characters" end)}' "$body" 2>/dev/null || head -c 120 "$body")"
rm -f "$body"
