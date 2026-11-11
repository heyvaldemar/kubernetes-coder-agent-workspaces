#!/usr/bin/env bash
# install-coder.sh - apply the boundary and install Coder on the cluster in the
# current kubeconfig (a kind cluster from the sandbox's kind/cluster.yaml, with
# gVisor installed by the sandbox's install-gvisor.sh), and wait for it.
#
#   1. The sandbox's parts, from the verbatim copies in vendor/: the gVisor
#      RuntimeClass, its admission policy and the agents' resolver.
#   2. This repository's manifests/: namespaces, this repository's policy,
#      Postgres, the corp stand-in, the quota and the network policies.
#   3. What cannot live in a manifest, made here:
#        - the database password, generated on this machine and handed to
#          kubectl on stdin, so it exists only as the Secret coder-db in
#          the namespace coder;
#        - the rules that let the Coder server and the resolver reach the API
#          server, which name the API server's address.
#   4. The Coder chart, from the archive pinned in charts.lock, refused if its
#      sha256 differs, with helm/values.yaml and any files in CODER_VALUES
#      (space-separated) on top.
#
# The Terraform providers come from a mirror (scripts/provider-mirror.sh),
# built on this machine if CODER_PROVIDER_MIRROR does not point at one, and
# copied onto the volume the server mounts read-only. The server then has no
# rule to the internet at all, unless CODER_GITHUB=app or
# CODER_SERVER_INTERNET=open asks for manifests/optional/coder-server-internet.yaml.
#
# CODER_GITHUB=app adds GitHub external authentication (helm/values-github.yaml)
# from the Secret coder/coder-github you created from your own OAuth app
# (docs/first-workspace.md). CODER_GITHUB=placeholder creates that Secret with
# a client ID that names no app and a generated secret, which is what the e2e
# runs: the reader's path, with nothing anyone can sign in through.
set -euo pipefail
cd "$(dirname "$0")/.."
SANDBOX=vendor/kubernetes-ai-agent-sandbox

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

kubectl apply -f "$SANDBOX/manifests/runtimeclass.yaml" -f "$SANDBOX/manifests/admission.yaml" \
  -f "$SANDBOX/manifests/agent-dns.yaml" >/dev/null
echo "applied the sandbox's RuntimeClass, admission policy and resolver (v1.4.0, verbatim)"
kubectl apply -k manifests/ >/dev/null
echo "applied manifests/"
# `create`, not `apply`: apply would keep the whole object, password included,
# in the last-applied-configuration annotation.
if ! kubectl -n coder get secret coder-db >/dev/null 2>&1; then
  python3 - <<'PY' | kubectl create -f - >/dev/null
import json, secrets
password = secrets.token_urlsafe(32)
url = "postgres://coder:%s@postgres.coder.svc.cluster.local:5432/coder?sslmode=disable" % password
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": "coder-db", "namespace": "coder"},
                  "stringData": {"password": password, "url": url}}))
PY
  echo "database password generated, in the Secret coder/coder-db only"
fi

case "${CODER_GITHUB:-}" in
  "") ;;
  placeholder)
    if ! kubectl -n coder get secret coder-github >/dev/null 2>&1; then
      python3 - <<'PY' | kubectl create -f - >/dev/null
import json, secrets
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": "coder-github", "namespace": "coder"},
                  "stringData": {"client-id": "e2e-placeholder-no-such-app",
                                 "client-secret": secrets.token_urlsafe(32)}}))
PY
      echo "GitHub external auth: a placeholder Secret that names no app"
    fi ;;
  app)
    kubectl -n coder get secret coder-github >/dev/null 2>&1 || {
      echo "CODER_GITHUB=app needs the Secret coder/coder-github (docs/first-workspace.md)" >&2; exit 1; } ;;
  *) echo "CODER_GITHUB is app, placeholder or empty, not '$CODER_GITHUB'" >&2; exit 1 ;;
esac

# The API server as a pod sees it: the Service address, and the endpoint it is
# translated to. Network plugins differ in which of the two a policy is
# matched against, so each rule names both and nothing else (the sandbox's
# install-sandbox.sh does the same for its MCP server and resolver).
svc_ip="$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
svc_port="$(kubectl -n default get service kubernetes -o jsonpath='{.spec.ports[0].port}')"
ep_ip="$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].endpoints[0].addresses[0]}')"
ep_port="$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].ports[0].port}')"
python3 - "$svc_ip" "$svc_port" "$ep_ip" "$ep_port" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
svc_ip, svc_port, ep_ip, ep_port = sys.argv[1:]
egress = [{"to": [{"ipBlock": {"cidr": svc_ip + "/32"}}], "ports": [{"protocol": "TCP", "port": int(svc_port)}]},
          {"to": [{"ipBlock": {"cidr": ep_ip + "/32"}}], "ports": [{"protocol": "TCP", "port": int(ep_port)}]}]
def rule(name, ns, selector):
    return {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"podSelector": selector, "policyTypes": ["Egress"], "egress": egress}}
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": [
    # The provisioner runs inside the Coder server and creates workspaces.
    rule("coder-server-to-api-server", "coder", {"matchLabels": {"app.kubernetes.io/name": "coder"}}),
    # The workspaces' resolver watches Services and EndpointSlices.
    rule("agent-dns-to-api-server", "agent-dns", {})]}))
PY
echo "the Coder server and the resolver may reach the API server at $svc_ip:$svc_port and $ep_ip:$ep_port"

if [ "${CODER_SERVER_INTERNET:-}" = open ] || [ "${CODER_GITHUB:-}" = app ]; then
  kubectl apply -f manifests/optional/coder-server-internet.yaml >/dev/null
  echo "the Coder server may reach the internet on 443 (manifests/optional/coder-server-internet.yaml)"
else
  kubectl -n coder delete networkpolicy coder-server-internet --ignore-not-found >/dev/null
  echo "the Coder server has no way to the internet"
fi

# The provider mirror, onto its volume through a loader pod that exists for
# the copy only. The archive goes over stdin; nothing is fetched in the cluster.
mirror="${CODER_PROVIDER_MIRROR:-.cache/provider-mirror}"
[ -d "$mirror/registry.terraform.io" ] || ./scripts/provider-mirror.sh "$mirror" >/dev/null
want="$(find "$mirror" -name '*.zip' | wc -l | tr -d ' ')"
python3 - <<'PY' | kubectl apply -f - >/dev/null
import json
busybox = "docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
print(json.dumps({"apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": "provider-mirror-loader", "namespace": "coder", "labels": {"app.kubernetes.io/name": "provider-mirror-loader"}},
  "spec": {"automountServiceAccountToken": False, "restartPolicy": "Never",
    "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "loader", "image": busybox, "command": ["sleep", "600"],
      "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "200m", "memory": "64Mi"}},
      "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
      "volumeMounts": [{"name": "providers", "mountPath": "/mirror"}]}],
    "volumes": [{"name": "providers", "persistentVolumeClaim": {"claimName": "terraform-providers"}}]}}))
PY
kubectl -n coder wait --for=condition=Ready pod/provider-mirror-loader --timeout=180s >/dev/null
kubectl -n coder exec provider-mirror-loader -- sh -c 'rm -rf /mirror/providers /mirror/terraform.rc && mkdir -p /mirror/providers'
COPYFILE_DISABLE=1 tar -C "$mirror" -cf - . | kubectl -n coder exec -i provider-mirror-loader -- tar -C /mirror/providers -xf -
printf 'provider_installation {\n  filesystem_mirror {\n    path = "/mirror/providers"\n  }\n}\n' |
  kubectl -n coder exec -i provider-mirror-loader -- sh -c 'cat > /mirror/terraform.rc'
got="$(kubectl -n coder exec provider-mirror-loader -- find /mirror/providers -name '*.zip' | wc -l | tr -d ' ')"
kubectl -n coder delete pod provider-mirror-loader --wait=true >/dev/null
[ "$got" = "$want" ] || { echo "the provider mirror holds $got packages, $want were built" >&2; exit 1; }
echo "the Terraform provider mirror is on its volume: $got packages, no direct installation"

kubectl -n coder rollout status statefulset/postgres --timeout=180s >/dev/null
echo "ready: coder/postgres"

read -r version sum url < <(awk '$1 == "coder" {print $2, $4, $5}' charts.lock)
mkdir -p .cache/charts
chart=".cache/charts/coder_helm_$version.tgz"
if [ ! -f "$chart" ] || [ "$(sha256 "$chart")" != "$sum" ]; then
  curl -fsSL --retry 3 -o "$chart" "$url"
fi
got="$(sha256 "$chart")"
if [ "$got" != "$sum" ]; then
  echo "coder chart $version: sha256 $got, pinned $sum. Not installing." >&2
  exit 1
fi
values=(-f helm/values.yaml)
[ -n "${CODER_GITHUB:-}" ] && values+=(-f helm/values-github.yaml)
for extra in ${CODER_VALUES:-}; do values+=(-f "$extra"); done
helm upgrade --install coder "$chart" --namespace coder "${values[@]}" --wait --timeout 6m >/dev/null
echo "installed: the Coder chart $version (sha256 checked), values ${values[*]}"

for d in agent-dns/agent-dns corp/internal coder/coder; do
  kubectl -n "${d%/*}" rollout status "deployment/${d#*/}" --timeout=180s >/dev/null
  echo "ready: $d"
done
