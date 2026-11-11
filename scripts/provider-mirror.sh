#!/usr/bin/env bash
# provider-mirror.sh [dir] - the Terraform providers the templates pin, downloaded
# on this machine into a filesystem mirror, so a template build in the cluster
# needs no internet.
#
# The pinned Terraform image (ci-images.pins, the version the Coder image
# bundles) runs `terraform providers mirror` against templates/agent-workspace:
# it takes the versions in .terraform.lock.hcl and checks each package's
# signature from the registry as it downloads. Inside the cluster, terraform
# init checks every package against the same lock file's hashes again.
#
# Both templates pin the same providers (scripts/validate.sh template), so one
# mirror serves both. Writes to .cache/provider-mirror unless told otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-.cache/provider-mirror}"
image="$(awk -F= '$1 == "TERRAFORM_IMAGE" {print $2}' ci-images.pins)"
[ -n "$image" ] || { echo "no TERRAFORM_IMAGE in ci-images.pins" >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out"
docker run --rm -e CHECKPOINT_DISABLE=1 \
  -v "$PWD/templates/agent-workspace:/template:ro" -v "$(cd "$out" && pwd):/mirror" -w /template \
  "$image" providers mirror -platform=linux_amd64 -platform=linux_arm64 /mirror >&2
find "$out" -name '*.zip' | sed "s|^$out/||" | sort
