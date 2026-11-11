#!/usr/bin/env bash
# validate.sh [check...] - the static checks, without a cluster:
#
#   kubeconform   this repository's manifests, the sandbox's vendored ones and
#                 the Coder chart rendered with each values file are valid
#                 Kubernetes 1.37 objects
#   images        every image is referenced by digest: in the manifests, the
#                 chart values, the templates, the e2e and the workflows
#   vendor        the sandbox's files under vendor/ are the bytes VENDOR.txt
#                 records, and nothing else is there (scripts/check-vendor.py)
#   coder         the chart values keep what the README claims: telemetry, the
#                 update check, STUN and direct connections off, Terraform's
#                 version check off, its providers from the read-only mirror,
#                 no rule to the internet outside manifests/optional/, the image by digest at the chart's
#                 version, a ClusterIP Service, and the provisioner's RBAC in
#                 coder-workspaces only, without Deployments; the GitHub
#                 values file carries every setting of the base one
#   model         the scripted model and the e2e's chat driver compile, and
#                 every step of the model's script that reads a credential is
#                 marked so, so its output is never logged
#   template      the templates: every image they name is one this
#                 repository's policy admits, the tampered fixture pins the
#                 same images, providers and lock file as the real template,
#                 and each of its variants has a row in tests/e2e/variants.tsv
#                 and each row a variant
#
# With no arguments every check runs. tests/static/plants.tsv shows each
# check the violation it exists for (tests/static/plant_violations.py).
# The check_* functions are called by name from the loop at the bottom.
# shellcheck disable=SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

KUBE_VERSION=1.37.0
# yannh/kubernetes-json-schema at a fixed commit, the sandbox's. K8S_SCHEMAS
# may point at a local checkout of the same commit instead.
default_schemas='https://raw.githubusercontent.com/yannh/kubernetes-json-schema/817113f21a2643311cbc3e992bb44ffe1c416c54/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json'
K8S_SCHEMAS="${K8S_SCHEMAS:-$default_schemas}"
SANDBOX=vendor/kubernetes-ai-agent-sandbox

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

chart() {  # the pinned chart archive, fetched once and checked
  local version sum url file
  read -r version sum url < <(awk '$1 == "coder" {print $2, $4, $5}' charts.lock)
  mkdir -p .cache/charts
  file=".cache/charts/coder_helm_$version.tgz"
  [ -f "$file" ] && [ "$(sha256 "$file")" = "$sum" ] || curl -fsSL --retry 3 -o "$file" "$url" || return 1
  [ "$(sha256 "$file")" = "$sum" ] || { echo "the chart archive's sha256 is not the one charts.lock pins"; return 1; }
  echo "$file"
}

check_kubeconform() {
  local archive
  mkdir -p .cache/kubeconform out
  archive="$(chart)" || return 1
  kubectl kustomize manifests >out/manifests.yaml || return 1
  helm template coder "$archive" -n coder -f helm/values.yaml >out/chart.yaml || return 1
  helm template coder "$archive" -n coder -f helm/values.yaml -f helm/values-github.yaml >out/chart-github.yaml || return 1
  helm template coder "$archive" -n coder -f helm/values.yaml -f tests/egress/values-defaults.yaml >out/chart-defaults.yaml || return 1
  kubeconform -strict -summary -output text -kubernetes-version "$KUBE_VERSION" \
    -cache .cache/kubeconform -schema-location "$K8S_SCHEMAS" \
    out/manifests.yaml out/chart.yaml out/chart-github.yaml out/chart-defaults.yaml \
    manifests/optional/coder-server-internet.yaml \
    "$SANDBOX/manifests/runtimeclass.yaml" "$SANDBOX/manifests/admission.yaml" "$SANDBOX/manifests/agent-dns.yaml"
}

check_images() {
  # The tampered template is excluded on purpose: two of its variants are an
  # image by tag and an image from elsewhere, refused by the cluster in the
  # e2e. vendor/ is the sandbox's, checked there.
  local bad
  bad="$(grep -rnE '(image:|"image":|^[A-Z_]+=|image +=|_image += |workspace +=|other_image += )[[:space:]]*"?[a-z0-9.-]+\.[a-z]+/[^@[:space:]"]+:[^@[:space:]"]+("|$|[[:space:]])' \
    manifests templates tests/e2e/run.sh ci-images.pins .github/workflows 2>/dev/null | grep -v '@sha256:' || true)"
  # The chart splits the image into repo and tag; the digest rides on the tag.
  grep -qE '^    tag: "v[0-9.]+@sha256:[0-9a-f]{64}"$' helm/values.yaml || bad+=$'\n'"helm/values.yaml: coder.image.tag carries no digest"
  bad="$(sed '/^$/d' <<<"$bad")"
  if [ -n "$bad" ]; then echo "images without a digest:"; echo "$bad"; return 1; fi
  echo "every image is referenced by digest"
}

check_vendor() { python3 scripts/check-vendor.py; }

check_coder() {
  python3 - <<'PY'
import re, sys
def env(path):
    text = open(path).read()
    out = {}
    for m in re.finditer(r"- \{name: (\w+), value: \"?([^\"}]+)\"?\}", text):
        out[m.group(1)] = m.group(2)
    for m in re.finditer(r"- name: (\w+)\n\s+value(?:From)?:\s*(.*)", text):
        out.setdefault(m.group(1), m.group(2).strip())
    return text, out
bad = []
text, base = env("helm/values.yaml")
want = {"CODER_TELEMETRY_ENABLE": "false", "CODER_UPDATE_CHECK": "false",
        "CODER_DERP_SERVER_STUN_ADDRESSES": "disable", "CODER_BLOCK_DIRECT": "true",
        "CHECKPOINT_DISABLE": "1", "TF_CLI_CONFIG_FILE": "/mirror/terraform.rc"}
for k, v in want.items():
    if base.get(k) != v:
        bad.append("helm/values.yaml: %s is %s, the README says %s" % (k, base.get(k, "unset"), v))
chart = open("charts.lock").read()
version = re.search(r"^coder\s+(\S+)", chart, re.M).group(1)
tag = re.search(r'^    tag: "v([0-9.]+)@', text, re.M)
if not tag or tag.group(1) != version:
    bad.append("helm/values.yaml: the image tag is not the chart's version %s" % version)
if "type: ClusterIP" not in text:
    bad.append("helm/values.yaml: the Service is not ClusterIP")
sa = text[text.index("  serviceAccount:"):text.index("  securityContext:")]
for line in ("    workspacePerms: false", "    enableDeployments: false",
             "      - name: coder-workspaces\n        workspacePerms: true\n        enableDeployments: false"):
    if not re.search("^" + re.escape(line) + "$", sa, re.M):
        bad.append("helm/values.yaml: the provisioner's RBAC lacks %r" % line.strip())
if sa.count("- name:") != 1 or "extraRules" in sa:
    bad.append("helm/values.yaml: the provisioner's RBAC reaches past coder-workspaces")
policies = open("manifests/network-policies.yaml").read()
if "0.0.0.0/0" in policies or "::/0" in policies:
    bad.append("manifests/network-policies.yaml opens a way to the internet; that rule lives in manifests/optional/ only")
if "name: providers, mountPath: /mirror, readOnly: true" not in text:
    bad.append("helm/values.yaml: the provider mirror is not mounted read-only at /mirror")
_, gh = env("helm/values-github.yaml")
_, e2e = env("tests/e2e/values-e2e-oauth.yaml")
for k, v in gh.items():
    if e2e.get(k) != v:
        bad.append("tests/e2e/values-e2e-oauth.yaml: %s is %s there and %s in helm/values-github.yaml" % (k, e2e.get(k, "unset"), v))
for k, v in base.items():
    if gh.get(k) != v:
        bad.append("helm/values-github.yaml: %s is %s there and %s in helm/values.yaml (Helm replaces the whole list)" % (k, gh.get(k, "unset"), v))
print("\n".join(bad) or "the chart values keep every setting the README claims")
sys.exit(1 if bad else 0)
PY
}

check_model() {
  python3 - <<'PY'
import ast, py_compile, sys
for f in ("manifests/model/model.py", "tests/e2e/agents.py"):
    py_compile.compile(f, doraise=True)
tree = ast.parse(open("manifests/model/model.py").read())
script = next(n.value for n in tree.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "SCRIPT")
bad = []
for step in ast.literal_eval(script):
    name, command, secret = step
    if any(s in command for s in ("CODER_AGENT_TOKEN", "gitsshkey", "external-auth", "printenv")) and not secret:
        bad.append("model.py step %r reads a credential and is not marked secret: its output would be logged" % name)
print("\n".join(bad) or "both compile; every step that reads a credential is marked secret")
sys.exit(1 if bad else 0)
PY
}

check_template() {
  python3 - <<'PY'
import re, sys
bad = []
real = open("templates/agent-workspace/main.tf").read()
fake = open("tests/e2e/tampered/main.tf").read()
policy = open("manifests/admission.yaml").read()
allowed = re.search(r"in\s+\[([^\]]+)\]", policy, re.S).group(1)
allowed = re.findall(r"'([^']+)'", allowed)
images = re.findall(r'"((?:docker\.io|ghcr\.io)/[^"]+@sha256:[0-9a-f]{64})"', real)
if not images:
    bad.append("templates/agent-workspace/main.tf names no image by digest")
for img in images:
    repo = img.split("@")[0].split(":")[0]
    if repo not in allowed:
        bad.append("templates/agent-workspace/main.tf runs %s, which manifests/admission.yaml does not admit" % repo)
for img in images:
    if img not in fake:
        bad.append("tests/e2e/tampered/main.tf does not pin %s like the real template" % img)
prov = lambda t: re.findall(r'source\s+=\s+"([^"]+)"\s+version\s+=\s+"([^"]+)"', t)
if prov(real) != prov(fake):
    bad.append("the tampered template's providers %s differ from the real one's %s" % (prov(fake), prov(real)))
if open("templates/agent-workspace/.terraform.lock.hcl").read() != open("tests/e2e/tampered/.terraform.lock.hcl").read():
    bad.append("the two templates' .terraform.lock.hcl differ")
rows = [l.split("\t")[0] for l in open("tests/e2e/variants.tsv") if l.strip() and not l.startswith("#")]
named = set(re.findall(r'local\.v [!=]= "([a-z-]+)"', fake)) | set(re.findall(r'"([a-z-]+)"', re.search(r"makes_a_pod\s+=.*", fake).group(0)))
for v in sorted(named - set(rows)):
    bad.append("tampered variant %s has no row in tests/e2e/variants.tsv" % v)
for v in sorted(set(rows) - named - {"none"}):
    bad.append("tests/e2e/variants.tsv row %s is no variant of tests/e2e/tampered/main.tf" % v)
print("\n".join(bad) or "%d template images admitted by the policy; the fixture matches the template; %d variants, one row each" % (len(images), len(rows)))
sys.exit(1 if bad else 0)
PY
}

checks=("$@")
[ ${#checks[@]} -eq 0 ] && checks=(kubeconform images vendor coder model template)
failed=0
for c in "${checks[@]}"; do
  if "check_$c"; then echo "-- $c: ok"; else echo "-- $c: FAILED"; failed=1; fi
done
exit "$failed"
