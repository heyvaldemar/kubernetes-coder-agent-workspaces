#!/usr/bin/env bash
# install-gvisor.sh [cluster-name] - put gVisor's runsc into every node of a
# kind cluster and restart containerd, so pods with runtimeClassName: gvisor
# start in gVisor's user-space kernel instead of on the host kernel.
#
# The release and the SHA-512 of its bundle per architecture come from
# gvisor.lock. A bundle whose hash differs is refused: a runtime is the one
# binary every sandboxed process trusts.
#
# kind/cluster.yaml already registers the runsc handler with containerd; this
# supplies the binaries it points at. Needs docker and kind on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${1:-agent-sandbox}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sha512() { if command -v sha512sum >/dev/null; then sha512sum "$1"; else shasum -a 512 "$1"; fi | cut -d' ' -f1; }

nodes="$(kind get nodes --name "$CLUSTER")"
[ -n "$nodes" ] || { echo "no nodes in kind cluster $CLUSTER" >&2; exit 1; }

for node in $nodes; do
  arch="$(docker exec "$node" uname -m)"
  read -r release pinned < <(awk -v a="$arch" '$1 !~ /^#/ && $2 == a {print $1, $3}' "$ROOT/gvisor.lock")
  [ -n "${pinned:-}" ] || { echo "$node: no gVisor pin for $arch in gvisor.lock" >&2; exit 1; }
  bundle="$WORK/gvisor-$arch.tar.bz2"
  if [ ! -f "$bundle" ]; then
    curl -fsSL --retry 3 -o "$bundle" "https://storage.googleapis.com/gvisor/releases/release/$release/$arch/gvisor.tar.bz2"
    got="$(sha512 "$bundle")"
    if [ "$got" != "$pinned" ]; then
      echo "gVisor $release $arch: sha512 $got, pinned $pinned. Not installing." >&2
      exit 1
    fi
    mkdir -p "$WORK/$arch"
    tar -xjf "$bundle" -C "$WORK/$arch" runsc containerd-shim-runsc-v1 gvisor-bin
  fi
  # runsc looks for its helper binaries in gvisor-bin/ next to itself.
  docker cp "$WORK/$arch/runsc" "$node:/usr/local/bin/runsc"
  docker cp "$WORK/$arch/containerd-shim-runsc-v1" "$node:/usr/local/bin/containerd-shim-runsc-v1"
  docker cp "$WORK/$arch/gvisor-bin" "$node:/usr/local/bin/"
  # The kubelet and runc in a kind node use systemd cgroups; runsc is told to
  # use them too, so a sandbox's cgroups are made the same way as every other
  # pod's. (It does not change where gVisor accounts memory: everything a pod
  # runs lives in the sandbox's cgroup, not in its containers'. See
  # docs/threat-model.md on swap.)
  docker exec "$node" sh -c 'printf "[runsc_config]\n  systemd-cgroup = \"true\"\n" > /etc/containerd/runsc.toml'
  docker exec "$node" sh -c 'chmod 755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin/* && systemctl restart containerd'
  echo "$node: $(docker exec "$node" runsc --version | head -1)"
done

# containerd restarts in a second or two; the node reports Ready again once
# the kubelet has reconnected to it.
kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null
