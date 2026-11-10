#!/usr/bin/env bash
# tests/e2e/run.sh - prove what the README says, against the kind cluster in
# the current kubeconfig: the sandbox's cluster and gVisor, `dns-log.sh on`,
# then `install-coder.sh` with CODER_GITHUB=placeholder (what .github/
# workflows/e2e.yml does, and `make up GITHUB=placeholder` locally).
#
# Every refusal is paired with a control that must succeed, so a check cannot
# pass because the environment refuses everything:
#
#   0. the node has no swap (a gVisor pod's memory limit depends on it)
#   1. what is installed: the pinned chart, the server and Postgres images by
#      digest, no bitnami image, no container runtime socket in any pod
#   2. control: a template pushed with the CLI, a workspace created from it,
#      its agent connected, a command run inside
#   3. the workspace runs on gVisor's kernel, not the node's
#   4. from inside the workspace (tests/e2e/inside.sh, over `coder ssh`): the
#      Coder server answers; the internet by name and by address, the
#      Kubernetes API, the metadata service, another namespace's service,
#      Coder's Postgres and DNS as a way out do not
#   5. the one credential: no Kubernetes API token in the workspace; the
#      Coder agent's token, measured at the Coder API from inside and at the
#      Kubernetes API from outside, and who can read it
#   6. the provisioner: what its ServiceAccount may and may not do, asked of
#      the API server; then one build per variant of a tampered template
#      (tests/e2e/variants.tsv), each refused for the reason it names
#   7. from a pod outside the boundary, the same targets answer
#   9. what the Coder server looked up while it ran, from the cluster
#      resolver's log: nothing on its own, only Terraform's providers during
#      template builds
#   (8 is the static checks: scripts/validate.sh in the Verify workflow.)
#
# Needs kubectl, helm, coder, docker, kind, jq and python3. Writes a summary to
# $GITHUB_STEP_SUMMARY and the results to $E2E_RESULTS when those are set.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLUSTER="${CLUSTER:-coder-workspaces}"
BUSYBOX=docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
CURL=docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
PROVISIONER=system:serviceaccount:coder:coder
WS=coder-workspaces
# The names a template build is allowed to look up: Terraform's registry and
# where it sends the provider downloads (registry.terraform.io answers with
# releases.hashicorp.com for HashiCorp's providers and a GitHub release for
# Coder's). Anything else the server asks for fails step 9.
BUILD_NAMES="registry.terraform.io releases.hashicorp.com github.com release-assets.githubusercontent.com objects.githubusercontent.com"
# What Coder's defaults dial, measured with tests/egress/values-defaults.yaml
# (README, "What the control plane dials"). None may appear here.
DEFAULT_DIALS="telemetry.coder.com api.github.com stun.l.google.com stun1.l.google.com stun2.l.google.com stun3.l.google.com stun4.l.google.com checkpoint-api.hashicorp.com"
results=()
measured=()
failed=0
work="$(mktemp -d)"

pass() { results+=("PASS  $1"); printf '  ok    %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }
measure() { measured+=("$1"); printf '  ..    %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then pass "$1: $3"; else fail "$1: expected $2, got ${3:-nothing}"; fi; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  [ -n "${CODER_PORT_FORWARD_PID:-}" ] && kill "$CODER_PORT_FORWARD_PID" 2>/dev/null
  kubectl delete namespace e2e-control e2e-metadata --ignore-not-found --wait=false >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

# The CLI reaches the server through a port-forward, which dies when the
# server's pod is replaced or a connection breaks; every batch of CLI calls
# starts by making sure it is up.
session() {
  if [ -n "${CODER_PORT_FORWARD_PID:-}" ] && ! kill -0 "$CODER_PORT_FORWARD_PID" 2>/dev/null; then unset CODER_PORT_FORWARD_PID; fi
  if ! curl -fsS --max-time 3 "${CODER_URL:-http://127.0.0.1:0}/healthz" >/dev/null 2>&1; then
    [ -n "${CODER_PORT_FORWARD_PID:-}" ] && kill "$CODER_PORT_FORWARD_PID" 2>/dev/null
    unset CODER_PORT_FORWARD_PID
    eval "$("$ROOT/scripts/coder-session.sh")" || return 1
  fi
}
# A workspace's agent is reachable once `coder ssh` runs a command in it.
ssh_ready() {
  for _ in $(seq 1 30); do
    coder ssh "$1" -- true >/dev/null 2>&1 && return 0
    session; sleep 5
  done
  return 1
}
# A pod in e2e-control, outside the boundary; prints its output.
outside() {  # name image command...
  local name="$1" image="$2"; shift 2
  kubectl -n e2e-control run "$name" --image="$image" --restart=Never --command -- "$@" >/dev/null
  for _ in $(seq 1 40); do
    case "$(kubectl -n e2e-control get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" in Succeeded|Failed) break ;; esac
    sleep 3
  done
  kubectl -n e2e-control logs "$name" 2>/dev/null
}
# shellcheck disable=SC2016  # expanded by the pod's shell
probe_script='for u in "$@"; do printf "%s %s\n" "$u" "$(curl -sk -o /dev/null -w "%{http_code}" --max-time 6 "$u")"; done'

# --- 0 -----------------------------------------------------------------------
step "0. the node has no swap"
swap=""
for node in $(kind get nodes --name "$CLUSTER" 2>/dev/null); do
  swap+="$(docker exec "$node" awk 'NR > 1' /proc/swaps)"
done
if [ -z "$swap" ]; then pass "no swap on the node; a workspace's memory limit holds (the sandbox's threat model)"; else
  fail "the node has swap; under gVisor a pod's memory limit is then RAM plus unlimited swap. Run swapoff -a first."; fi

# --- 1 -----------------------------------------------------------------------
step "1. what is installed"
read -r chart_version _ < <(awk '$1 == "coder" {print $2, $4}' "$ROOT/charts.lock")
installed="$(helm -n coder list -o json | jq -r '.[] | select(.name == "coder") | .chart')"
check "the Coder chart installed is the one charts.lock pins" "coder-$chart_version" "$installed"
pinned_server="$(awk -F'"' '/^    tag:/ {print $2}' "$ROOT/helm/values.yaml")"
server_image="$(kubectl -n coder get deployment coder -o jsonpath='{.spec.template.spec.containers[0].image}')"
check "the Coder server runs its image by digest" "ghcr.io/coder/coder:$pinned_server" "$server_image"
pg_image="$(kubectl -n coder get statefulset postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ "$pg_image" == docker.io/library/postgres:*@sha256:* ]]; then pass "Postgres is the official image by digest: ${pg_image%@*}"; else fail "Postgres image: $pg_image"; fi
all_images="$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}')"
if grep -qi bitnami <<<"$all_images"; then fail "a bitnami image runs in the cluster: $(grep -i bitnami <<<"$all_images" | head -1)"; else pass "no bitnami image anywhere in the cluster"; fi
sockets="$(kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace + "/" + .metadata.name + " " + (.spec.volumes // [] | map(.hostPath.path // empty) | join(","))' |
  grep -E 'docker\.sock|containerd\.sock|crio\.sock|podman\.sock|,/var/run(,|$)| /var/run(,|$)|,/run(,|$)| /run(,|$)' || true)"
if [ -z "$sockets" ]; then pass "no pod in the cluster mounts a container runtime's socket"; else fail "a runtime socket is mounted: $sockets"; fi

# --- the stand-ins and the outside namespace ---------------------------------
# kind has no metadata service, so one is stood up where a cloud's would be:
# 169.254.169.254:80 on the node, translated to a pod outside the boundary.
# A workspace must not reach it; the pod outside must (step 7).
kubectl create namespace e2e-metadata --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace e2e-control --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n e2e-metadata run metadata --image="$BUSYBOX" --restart=Never --command -- \
  sh -c 'mkdir -p /tmp/www/latest/meta-data && echo stand-in > /tmp/www/latest/meta-data/index.html && exec httpd -f -p 8080 -h /tmp/www' >/dev/null
kubectl -n e2e-metadata wait --for=condition=Ready pod/metadata --timeout=120s >/dev/null 2>&1
metadata_ip="$(kubectl -n e2e-metadata get pod metadata -o jsonpath='{.status.podIP}')"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" iptables -t nat -I PREROUTING -d 169.254.169.254/32 -p tcp --dport 80 -j DNAT --to-destination "$metadata_ip:8080"
done

# --- 2 -----------------------------------------------------------------------
step "2. control: a template, a workspace, a command inside"
session || fail "no session with the Coder server"
server_started="$(kubectl -n coder get pods -l app.kubernetes.io/name=coder -o jsonpath='{.items[0].status.startTime}')"
first_build="$(now)"
# The resolver's log is read to the second, and both windows include their
# boundary second: two seconds apart, a lookup of the first push cannot land
# in the window before it (run 42918598702 counted terraform init's lookups,
# made in the same second, as the server's own).
sleep 2
if coder templates push agent-workspace -d "$ROOT/templates/agent-workspace" --variable github_external_auth=true --yes >"$work/push.log" 2>&1; then
  pass "the template is pushed with the CLI"
else fail "template push: $(tail -5 "$work/push.log")"; fi
coder templates push tampered -d "$HERE/tampered" --yes >"$work/push-tampered.log" 2>&1 || fail "tampered template push: $(tail -5 "$work/push-tampered.log")"
if coder create e2e --template agent-workspace --yes >"$work/create.log" 2>&1; then
  pass "a workspace is created from it"
else fail "workspace create: $(grep -m3 -E 'Error|error' "$work/create.log")"; fi
if ssh_ready e2e; then pass "its agent connected"; else fail "the agent never connected"; fi
# shellcheck disable=SC2016  # expanded inside the workspace
hello="$(coder ssh e2e -- 'echo "hello from $(whoami) in $(hostname)"' 2>/dev/null)"
if [[ "$hello" == "hello from coder in "* ]]; then pass "a command runs inside: $hello"; else fail "a command inside answered '${hello:-nothing}'"; fi

# --- 3, 4, 5 (inside) --------------------------------------------------------
step "3-5. from inside the workspace"
coder ssh e2e -- bash -s <"$HERE/inside.sh" >"$work/inside.jsonl" 2>"$work/inside.err"
lines="$(jq -r 'select(.check) | [if .ok then "ok" else "bad" end, .check, .expected, .got, (.detail // "")] | @tsv' "$work/inside.jsonl" 2>/dev/null)"
[ -n "$lines" ] || fail "inside.sh wrote no report: $(head -c 300 "$work/inside.err")"
while IFS=$'\t' read -r ok what expected got detail; do
  [ -z "$ok" ] && continue
  [ "$ok" = ok ] && pass "inside: $what: $got${detail:+ ($detail)}" || fail "inside: $what: expected $expected, got $got${detail:+ ($detail)}"
done <<<"$lines"
pod_kernel="$(jq -r 'select(.check == "kernel is gVisor'"'"'s, not the node'"'"'s") | .detail' "$work/inside.jsonl")"
node_kernel="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')"
if [[ "$pod_kernel" == *gvisor* ]] && [[ "$node_kernel" != *gvisor* ]]; then
  pass "the workspace sees kernel $pod_kernel; the node runs $node_kernel"
else fail "the workspace sees kernel '${pod_kernel:-none}', the node '$node_kernel'"; fi

# --- 5 (outside) -------------------------------------------------------------
step "5. the agent's token, from outside"
ws_pod="$(kubectl -n "$WS" get pods -l com.coder.workspace.name=e2e -o jsonpath='{.items[0].metadata.name}')"
# Where the token lives: in the pod spec, as Coder's templates hand it over.
can_read="$(kubectl auth can-i get pods -n "$WS" --as="$PROVISIONER" 2>/dev/null)"
measure "the token is a plain value in the workspace pod's spec: whoever may read pods in $WS reads it; the provisioner may ($can_read), and so may cluster administrators"
token="$(kubectl -n "$WS" get pod "$ws_pod" -o jsonpath='{.spec.containers[0].env[?(@.name=="CODER_AGENT_TOKEN")].value}')"
api_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sk -o /dev/null -w '%{http_code}' --config - "$api_server/api")"
check "the Kubernetes API refuses the agent's token" 401 "$code"
agent_api() {  # token path -> HTTP code, the token on stdin
  printf 'header = "Coder-Session-Token: %s"\n' "$1" | curl -s -o "$work/agent_api.json" -w '%{http_code}' --max-time 10 --config - "$CODER_URL$2"
}
session
code="$(agent_api "$token" /api/v2/workspaceagents/me/gitsshkey)"
check "control: the token works from outside the workspace too, at the agent's own endpoints" 200 "$code"
inside_hash="$(jq -r 'select(.check == "the agent'"'"'s token fetches the owner'"'"'s Git SSH private key") | .detail' "$work/inside.jsonl" | sed -n 's/.*public half //p')"
session_token="$(cat "$CODER_CONFIG_DIR/session" 2>/dev/null)"
owner_hash="$(printf 'header = "Coder-Session-Token: %s"\n' "$session_token" | curl -s --max-time 10 --config - "$CODER_URL/api/v2/users/me/gitsshkey" | jq -r .public_key | sha256sum | cut -c1-16)"
unset session_token
check "the key the agent's token fetched is the owner's own (hash of the public half)" "$owner_hash" "$inside_hash"
# A token taken out of a workspace, after the workspace is rebuilt.
coder restart e2e --yes >"$work/restart.log" 2>&1 || fail "workspace restart: $(tail -3 "$work/restart.log")"
session
code="$(agent_api "$token" /api/v2/workspaceagents/me/gitsshkey)"
measure "the token taken out before a rebuild, asked for the key after it: HTTP $code"
unset token
ssh_ready e2e || fail "the agent did not come back after the rebuild"

# --- 6 -----------------------------------------------------------------------
step "6. the provisioner, and templates edited to step outside"
for q in "yes create pods -n $WS" "yes create persistentvolumeclaims -n $WS" \
         "no create pods -n coder" "no create pods -n default" "no create pods --subresource=exec -n $WS" \
         "no create deployments.apps -n $WS" "no create services -n $WS" \
         "no create networkpolicies.networking.k8s.io -n $WS" "no create namespaces" \
         "no create rolebindings.rbac.authorization.k8s.io -n $WS" "no create clusterrolebindings.rbac.authorization.k8s.io" \
         "no get secrets -n coder" "no patch validatingadmissionpolicies.admissionregistration.k8s.io" \
         "no patch namespaces"; do
  want="${q%% *}" ask="${q#* }"
  # shellcheck disable=SC2086  # the question is words
  got="$(kubectl auth can-i $ask --as="$PROVISIONER" 2>/dev/null)"
  check "the provisioner's ServiceAccount: can-i $ask" "$want" "$got"
done

session
claim="$(kubectl -n "$WS" get pvc -l com.coder.workspace.name=e2e -o jsonpath='{.items[0].metadata.name}')"
variants="$(awk -F'\t' '!/^#/ && NF {print $1}' "$HERE/variants.tsv")"
export CLAIM="$claim" WORK="$work"
# Three at a time: the server runs three provisioners.
# shellcheck disable=SC2016
xargs -P 3 -I{} bash -c 'coder create "t-$1" --template tampered --parameter variant="$1" --parameter claim="$CLAIM" --yes >"$WORK/variant-$1.log" 2>&1; echo $? >"$WORK/variant-$1.rc"' _ {} <<<"$variants"
while IFS=$'\t' read -r variant expect who; do
  case "$variant" in ''|'#'*) continue ;; esac
  rc="$(cat "$work/variant-$variant.rc" 2>/dev/null)"
  refusal="$(grep -m1 'Error: ' "$work/variant-$variant.log" | sed 's/^.*Error: //' | cut -c1-200)"
  case "$expect" in
    admitted) [ "$rc" = 0 ] && pass "tampered: $variant: admitted ($who)" || fail "tampered: $variant was refused: $refusal" ;;
    measured) measure "tampered: $variant: build exit $rc" ;;
    *) if [ "$rc" != 0 ] && grep -qF "$expect" "$work/variant-$variant.log"; then pass "tampered: $variant: refused by $who ($expect)"
       else fail "tampered: $variant: expected a refusal saying '$expect', got (rc=$rc): ${refusal:-$(tail -2 "$work/variant-$variant.log")}"; fi ;;
  esac
done <"$HERE/variants.tsv"
# The finding: one workspace's template can mount another's home.
marker="written-by-e2e-$RANDOM$RANDOM"
printf '%s\n' "$marker" | coder ssh e2e -- 'cat > /home/coder/written-by-e2e' 2>/dev/null
seen=""
ssh_ready t-other-home && seen="$(coder ssh t-other-home -- 'cat /home/coder/written-by-e2e' 2>/dev/null)"
if [ "$seen" = "$marker" ]; then
  measure "tampered: other-home: a template that names another workspace's claim is admitted, and its workspace reads the file the other wrote; the boundary is the namespace, not the workspace (threat model)"
else
  measure "tampered: other-home: did not read the other workspace's file (got '${seen:-nothing}')"
fi

# --- 7 -----------------------------------------------------------------------
step "7. the same targets, from outside the boundary"
control="$(outside e2e-control "$CURL" sh -c "$probe_script" sh https://example.com/ http://1.1.1.1/ \
  https://kubernetes.default.svc.cluster.local/version http://169.254.169.254/latest/meta-data/ \
  http://internal.corp.svc.cluster.local:8080/ http://coder.coder.svc.cluster.local/healthz)"
for target in https://example.com/ http://1.1.1.1/ https://kubernetes.default.svc.cluster.local/version \
              http://169.254.169.254/latest/meta-data/ http://internal.corp.svc.cluster.local:8080/; do
  code="$(awk -v u="$target" '$1 == u {print $2}' <<<"$control")"
  if [ -n "$code" ] && [ "$code" != 000 ]; then pass "outside the boundary, $target answers: HTTP $code"
  else fail "outside the boundary, $target did not answer: ${control:-no output}"; fi
done
names="$(outside e2e-control-names "$BUSYBOX" nslookup -timeout=3 example.com)"
if sed -n '/^Name:/,$p' <<<"$names" | grep -qE '^Address:? [0-9]'; then pass "outside the boundary, example.com resolves"; else fail "outside the boundary, example.com did not resolve: $names"; fi
pg="$(outside e2e-control-pg "$BUSYBOX" sh -c 'nc -w 5 postgres.coder.svc.cluster.local 5432 </dev/null && echo reached || echo blocked')"
check "Postgres refuses a pod outside the boundary too: its own wall, the Coder server only" blocked "$(tail -1 <<<"$pg")"

# --- 9 -----------------------------------------------------------------------
step "9. what the Coder server looked up"
last="$(now)"
# A measurement that fails, or that saw no query at all, fails the step: an
# empty list from a blind log would read as a pass (run 42917631988 did).
read_names() {  # from to out
  if ! FROM="$1" TO="$2" "$ROOT/scripts/dns-log.sh" names coder app.kubernetes.io/name=coder >"$3.raw"; then
    fail "the resolver's log could not be read for $1 to $2"; : >"$3.raw"
  fi
  grep -v '^#' "$3.raw" >"$3" || true
  awk -F'\t' '$1 == "#total" {print $2}' "$3.raw"
}
total_alone="$(read_names "$server_started" "$first_build" "$work/names-alone.tsv")"
total_builds="$(read_names "$first_build" "$last" "$work/names-builds.tsv")"
alone="$(cut -f1 "$work/names-alone.tsv" | paste -sd' ' -)"
builds="$(cut -f1 "$work/names-builds.tsv" | paste -sd' ' -)"
if [ "${total_alone:-0}" -gt 0 ] && [ "${total_builds:-0}" -gt 0 ]; then
  pass "control: the resolver logged the server's lookups, $total_alone before the first push and $total_builds after it, cluster names included"
else
  fail "control: the resolver logged ${total_alone:-no} lookups by the server before the first push and ${total_builds:-no} after it; the measurement is blind"
fi
if [ "${total_alone:-0}" -gt 0 ] && [ -z "$alone" ]; then pass "from its start to the first template push, the Coder server looked up no outside name"
elif [ -n "$alone" ]; then fail "on its own, the Coder server looked up: $alone"; fi
stray=""
for n in $builds; do [[ " $BUILD_NAMES " == *" $n "* ]] || stray+="$n "; done
# Builds: the e2e workspace's first, the restart's stop and start, one per variant.
if [ -n "$builds" ] && [ -z "$stray" ]; then pass "during two pushes and $(($(grep -c . <<<"$variants") + 3)) builds, it looked up Terraform's providers only: $builds"
elif [ -z "$builds" ]; then fail "no outside name was logged during the builds, though Terraform downloads its providers then"
else fail "during template builds the Coder server also looked up: $stray"; fi
for n in $DEFAULT_DIALS; do
  if grep -qx "$n" <(cut -f1 "$work/names-alone.tsv" "$work/names-builds.tsv"); then fail "a default this repository turns off was dialled: $n"; fi
done
measure "names looked up during builds, with counts: $(tr '\t\n' '=,' <"$work/names-builds.tsv" | sed 's/,$//')"

# --- results -----------------------------------------------------------------
if [ -n "${E2E_RESULTS:-}" ]; then
  { printf 'R\t%s\n' "${results[@]}"; [ "${#measured[@]}" -gt 0 ] && printf 'M\t%s\n' "${measured[@]}"; } | python3 -c '
import json, sys
checks, measured = [], []
for line in sys.stdin:
    kind, _, text = line.rstrip("\n").partition("\t")
    if kind == "R" and text:
        state, _, name = text.partition("  ")
        checks.append({"state": state.strip(), "name": name.strip()})
    elif kind == "M" and text:
        measured.append(text)
json.dump({"checks": checks, "measured": measured}, sys.stdout)
' >"$E2E_RESULTS"
fi

printf '\n'
printf '%s\n' "${results[@]}"
[ "${#measured[@]}" -gt 0 ] && printf 'MEASURED  %s\n' "${measured[@]}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Coder agent workspaces e2e"; echo; echo '```'; printf '%s\n' "${results[@]}"
    [ "${#measured[@]}" -gt 0 ] && printf 'MEASURED  %s\n' "${measured[@]}"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
