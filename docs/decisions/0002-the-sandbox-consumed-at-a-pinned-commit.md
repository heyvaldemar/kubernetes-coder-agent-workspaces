# 2. The sandbox's boundary, consumed verbatim at a pinned commit

- Status: accepted
- Date: 2026-11-10

## Context

[kubernetes-ai-agent-sandbox](https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox) already proves a boundary for agent pods on kind: gVisor as the runtime, a ValidatingAdmissionPolicy the API server enforces, an egress allowlist with a resolver that answers for the cluster's names only, and a gate that holds an agent back until its pod's network policy has taken hold. A Coder workspace is an agent pod with a different door. The boundary should be the sandbox's own, not a copy that drifts from it, and this repository must not edit it.

Three ways to consume it at its v1.4.0 release, commit `6238e2c2a6fff18e5433c3c11df961976aac978d`: a remote kustomize base, a git submodule, or a vendored copy.

## Decision

A vendored copy, verbatim, in `vendor/kubernetes-ai-agent-sandbox/`: `kind/cluster.yaml`, `scripts/install-gvisor.sh`, `gvisor.lock`, `manifests/runtimeclass.yaml`, `manifests/admission.yaml`, `manifests/agent-dns.yaml` and the sandbox's `LICENSE`. `VENDOR.txt` records the source, the release, the commit and each file's sha256.

- `scripts/check-vendor.py`, in every Verify run: each listed file has the recorded hash, and nothing unlisted sits beside them. A planted edit to the vendored policy and a planted extra file are both caught (`tests/static/plants.tsv`).
- `scripts/check-vendor.py --upstream`, on Verify's schedule: each file fetched from GitHub at the recorded commit has the same bytes, the release tag still points at that commit, and a newer sandbox release is reported.
- The workspace namespace carries the sandbox's label, `sandbox.heyvaldemar.com/agents: "true"`, so the sandbox's own binding holds Coder workspaces to the sandbox's own policy, unchanged.

## What differs from the sandbox, and why

Measured on the first build, 2026-11-10: the sandbox's policy, verbatim, admits a Coder workspace written as `templates/agent-workspace/main.tf` writes it. No rule had to be loosened. What differs is around it:

| Here | In the sandbox | Why |
|---|---|---|
| The cluster is named `coder-workspaces` with `kind create --name` | `agent-sandbox` in `kind/cluster.yaml` | the file is used verbatim; the name is a flag |
| The resolver's ingress rule (`from-agents-only`) is copied into `manifests/network-policies.yaml` | in `manifests/network-policies.yaml` | that file also holds the policies of the sandbox's own namespaces (`agents`, `mcp`, `tools`, `corp`), which do not exist here |
| `scripts/install-coder.sh` writes the API-server egress rules for the resolver and the Coder server | `scripts/install-sandbox.sh` writes them for the resolver and the MCP server | the same rule, naming the API server's Service and endpoint addresses, for this repository's components |
| `corp` is a busybox `httpd` stand-in | podinfo and a records service behind an MCP server | only something to refuse a workspace is needed; the sandbox's second wall rule is copied as is |
| The gate is an init container in the template, the sandbox's command and busybox digest, asking for `coder.coder.svc.cluster.local` | in the agents' Job, asking for `kubernetes.default` | the name a workspace must resolve is the Coder server's |
| This repository adds one policy, `coder-workspace` (`manifests/admission.yaml`): images from the pinned workspace repository and the sandbox's busybox only | no rule on where an image comes from | a template author chooses the image; the cluster takes that choice back |
| Coder's agent token is an environment value in the pod spec | admission refuses a Secret in an agent pod's environment, and lists a pasted credential as a residual risk | Coder's templates hand the token over that way; the sandbox policy allows a plain value, which is the residual risk it already names. ADR 5 measures what the token reaches |
| The agent binary is downloaded at start into `/tmp`, an emptyDir | agents run code from their image | `coder_agent.init_script` fetches it from the Coder server, the one address a workspace reaches; the root stays read-only, as the sandbox's policy requires |

The MCP server and the sandbox's demo agents are not used: a Coder workspace's door is the Coder server (ADR 3).

## Consequences

- A change to the boundary is made in the sandbox, released there, and copied in here at the new commit with a new `VENDOR.txt`. The diff of that commit is the review.
- The release archive is self-contained: `git archive` of a tag includes the vendored files, which a submodule's would not.
- The copy cannot be edited quietly: Verify fails on a changed byte, and the upstream check fails if the pinned commit's files no longer match.

## Alternatives

- **A remote kustomize base at the commit.** No copy to keep, but every `kubectl apply -k` fetches from GitHub, and the base is the sandbox's whole `manifests/` directory, MCP server and its namespaces included.
- **A git submodule.** Dependabot could bump it, but `git archive` leaves it out, so the signed release archive would not hold the boundary it claims.

## How to explain this to a customer

The rules that contain the agent were written and tested in a separate project. This one uses them exactly as released, checks on every change that not a byte differs, and lists in plain words each place where it does something the original does not, with the reason.
