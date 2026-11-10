#!/usr/bin/env bash
# dns-log.sh on | names <namespace> <label-selector> - a measurement fixture:
# what a workload looks up is what it is about to dial.
#
#   on     adds CoreDNS's `log` plugin to the cluster's resolver
#          (kube-system/coredns) and waits for it to reload. Every query is
#          then one line in CoreDNS's log with the client's address.
#   names  prints the outside names the pods matching the selector asked for,
#          one per line with a count, sorted: the cluster's own names and the
#          search-path expansions of a name are left out. With FROM and TO
#          (RFC 3339, UTC), only the queries logged between the two.
#
# The e2e turns it on before Coder is installed, so the server's first
# minutes are in the log. It changes nothing a workspace can reach: the
# workspaces ask their own resolver, which has no log and no forward.
set -euo pipefail

case "${1:-}" in
  on)
    corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
    if ! grep -qE '^[[:space:]]+log$' <<<"$corefile"; then
      python3 - "$corefile" <<'PY' | kubectl -n kube-system patch configmap coredns --type merge --patch-file /dev/stdin >/dev/null
import json, sys
corefile = sys.argv[1].replace("    errors\n", "    errors\n    log\n", 1)
print(json.dumps({"data": {"Corefile": corefile}}))
PY
    fi
    # The reload plugin picks the change up within its interval (30s by
    # default); a restart makes it immediate and predictable.
    kubectl -n kube-system rollout restart deployment/coredns >/dev/null
    kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
    echo "CoreDNS logs every query"
    ;;
  names)
    ns="$2" selector="$3"
    ips="$(kubectl -n "$ns" get pods -l "$selector" -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}')"
    # The pods' search path: a name tried with a search domain appended is the
    # resolver library at work, not a destination.
    pod="$(kubectl -n "$ns" get pods -l "$selector" -o jsonpath='{.items[0].metadata.name}')"
    search="$(kubectl -n "$ns" exec "$pod" -- cat /etc/resolv.conf 2>/dev/null | awk '$1 == "search" {$1 = ""; print}')"
    logs=""
    for pod in $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o name); do
      logs+="$(kubectl -n kube-system logs --timestamps "$pod" 2>/dev/null)"$'\n'
    done
    python3 - "$ips" "$logs" "$search" "${FROM:-}" "${TO:-}" <<'PY'
import collections, re, sys
ips = set(sys.argv[1].split())
start, end = sys.argv[4][:19], sys.argv[5][:19]
search = [d.lower().rstrip(".") for d in sys.argv[3].split()] + ["cluster.local"]
# [INFO] 10.244.0.9:41432 - 5207 "A IN telemetry.coder.com. udp 37 false 512" NOERROR ...
line = re.compile(r'\[INFO\] (\S+):\d+ - \d+ "(\S+) IN (\S+?)\.? ')
seen = collections.Counter()
for raw in sys.argv[2].splitlines():
    m = line.search(raw)
    if not m or m.group(1) not in ips:
        continue
    at = raw[:19]  # kubectl's --timestamps prefix, UTC
    if (start and at < start) or (end and at > end):
        continue
    name = m.group(3).lower()
    if any(name == d or name.endswith("." + d) for d in search) or name.endswith((".in-addr.arpa", ".ip6.arpa")):
        continue
    seen[name] += 1
for name, count in sorted(seen.items()):
    print("%s\t%d" % (name, count))
PY
    ;;
  *) echo "usage: $0 on | names <namespace> <label-selector>" >&2; exit 2 ;;
esac
