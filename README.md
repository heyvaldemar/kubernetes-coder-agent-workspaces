# kubernetes-coder-agent-workspaces

[![Coder workspaces e2e](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/workflows/e2e.yml/badge.svg)](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/workflows/e2e.yml)
[![Verify](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/workflows/verify.yml/badge.svg)](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/workflows/verify.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/heyvaldemar/kubernetes-coder-agent-workspaces/badge)](https://scorecard.dev/viewer/?uri=github.com/heyvaldemar/kubernetes-coder-agent-workspaces)
[![e2e, last 30 days](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fheyvaldemar%2Fkubernetes-coder-agent-workspaces%2Fstatus%2Fbadge-days.json)](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/blob/status/status.json)
[![checks](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fheyvaldemar%2Fkubernetes-coder-agent-workspaces%2Fstatus%2Fbadge-checks.json)](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/blob/status/status.json)

The second row of badges is not typed by hand: it is the e2e workflow's last 30 days on main, rewritten after every run by [`.github/workflows/status.yml`](.github/workflows/status.yml) into the [`status`](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/tree/status) branch.

A Coder template is Terraform, and whoever can edit a template decides what the workspace pod is. So the boundary around an AI agent's workspace cannot live in the template. It has to live in the cluster, where a changed template is refused.

This repository runs Coder Community on Kubernetes with every workspace inside the boundary proven in [kubernetes-ai-agent-sandbox](https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox), copied in verbatim at its v1.4.0 release. On a fresh kind cluster, check by check, it shows that a workspace runs on gVisor's kernel, reaches the Coder server and nothing else, holds one credential whose reach is measured, and that templates edited to step outside are refused by the API server with the rule they broke.

It is a reference, not a product, and it does not run in production anywhere. It runs on kind in GitHub Actions, CPU only, at no cloud cost.

![The e2e run: the sandbox's cluster and gVisor, Coder installed, then every check, from the workspace's kernel to the twenty edited templates and what the server looked up](docs/demo/e2e.gif)

[Run 42919422290](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/runs/42919422290) on main, 83 checks in 4 minutes 47 seconds, replayed from its log by `scripts/cast-from-log.py`: the e2e refuses a node with swap, and Docker Desktop has swap, so it is recorded where it runs. The times are the log's own, waits cut to two seconds and played at half speed; GitHub's step headers and the summary `run.sh` repeats at its end are left out, and nothing is reworded. [`docs/demo/e2e.cast`](docs/demo/e2e.cast) replays it in a terminal (`asciinema play`).

## What is proven, and how

Every line is a check in `tests/e2e/run.sh` on a fresh cluster, or in `scripts/validate.sh`. Each refusal is paired with a control that must succeed, so a check cannot pass because the environment refuses everything.

| Claim | Proof |
|---|---|
| Coder is installed as pinned, and nothing holds the node's runtime | the chart installed is the archive `charts.lock` pins by sha256; the server image is `ghcr.io/coder/coder:v2.38.6` by digest; Postgres is the official image by digest; no bitnami image runs in the cluster; no pod mounts a container runtime's socket |
| A workspace works through Coder (the control for everything below) | the template is pushed with the CLI, a workspace is created from it, its agent connects, and `coder ssh` runs a command inside as `coder` |
| The workspace runs on gVisor's kernel, not the node's | inside it, `uname -r` is `4.19.0-gvisor`; the node reports its own kernel. Coder's docs say nothing about gVisor; the agent, its relay and its SSH server work under it |
| A workspace reaches the Coder server and nothing else | from inside, the Coder server answers; blocked: the internet by name and by IP address, the Kubernetes API by name and by Service address, the metadata service, another namespace's service, Coder's own Postgres |
| DNS is not a way out | the workspaces' resolver answers a cluster name and refuses a random name under example.com; the cluster's CoreDNS, which forwards, gives no reply; the system resolver finds no outside name |
| The blocks are the boundary's, not the environment's | a pod outside the boundary reaches the internet, the Kubernetes API, a metadata stand-in at 169.254.169.254 and the corp service, and resolves example.com; Postgres refuses it too, by its own rule |
| No Kubernetes API token in a workspace; its one credential is measured | no token on disk; the Coder agent's token is measured at the Kubernetes API and the Coder API ([below](#the-one-credential)) |
| The provisioner may create workspaces and nothing else | `kubectl auth can-i` as the Coder server's ServiceAccount: yes to pods and claims in `coder-workspaces`; no to pods in `coder` or `default`, `pods/exec`, Deployments, Services, NetworkPolicies, Namespaces, RoleBindings, ClusterRoleBindings, Secrets in `coder`, and changes to admission policies or namespaces |
| A template edited to step outside is refused by the API server | nineteen variants of one template, each built through Coder and refused for the reason it names ([below](#templates-edited-to-step-outside)); the unchanged template admitted |
| Coder Agents works under the same boundary, and a fooled model gets nothing out through the workspace | a chat driven by a scripted model in the cluster runs its `execute` tool in the workspace on gVisor's kernel; each of eight attempts the model asks for dies at the boundary: the internet by name and by IP address, the metadata service, the Kubernetes API, an API token on disk, another namespace's service, DNS, the model endpoint from inside the workspace ([below](#coder-agents-and-a-model-that-has-been-talked-into-it)) |
| The model's key stays in the control plane | the Coder server sends it on every request to the model; it appears nowhere in the workspace's pod |
| The Coder server dials nothing on its own | from its start to the first template push it looks up no outside name; during builds, only Terraform's registry and provider downloads ([below](#what-the-control-plane-dials)) |
| Every static check can fail | sixteen planted violations, each caught: telemetry back on, a STUN server, direct connections, the provisioner given Deployments or a second namespace, the GitHub values file dropping a setting, three images by tag, a misspelled policy field, the sandbox's policy edited in place, a file in `vendor/` the sandbox never shipped, a template image the policy does not admit, the tampered fixture on another provider version, a variant with no expected refusal, a model step that reads a credential logged as if it did not |

## The one credential

A workspace cannot work without its agent's token, and Coder's agent puts it in the environment of every process it starts, an AI agent's shell included. Measured on every run, from inside the workspace and from outside:

| Asked | Answer |
|---|---|
| The Kubernetes API, with the agent's token | 401 |
| The Coder API as a user's session: `/api/v2/users/me`, `/api/v2/workspaces`, `/api/v2/templates`, `/api/v2/users` | 401 each |
| `/api/v2/workspaceagents/me/gitsshkey` | 200: the owner's Git SSH private key. The public half's hash matches the key the owner sees in their own account |
| `/api/v2/workspaceagents/me/external-auth?id=github` | 200: a sign-in link and an empty token, since nobody links GitHub in CI. After the owner links an account, the same call returns the owner's GitHub token: that is how git works in a Coder workspace (`coderd/workspaceagents.go`), read in the code, not measured here |
| Where the token can be read | the shell's environment and PID 1's inside the workspace; the pod spec outside it, by whoever may read pods in `coder-workspaces`: the provisioner, and cluster administrators |
| The same token after the workspace is rebuilt | 401: a rebuild gives the workspace a new token, and the one taken out before it stops working |

So a fooled agent cannot act as a user, list workspaces or reach Kubernetes with its token. It can read the owner's git key and, once linked, the owner's GitHub token. The git key and the GitHub app's scopes are therefore the blast radius of one fooled agent, and whoever sets them up decides how large it is. [ADR 5](docs/decisions/0005-the-agent-token-measured.md) has the reasoning.

## Templates edited to step outside

`tests/e2e/tampered/main.tf` is the template with one field changed per variant, chosen by a workspace parameter. The e2e builds each one through Coder, three at a time, and reads the refusal from the build log. [`tests/e2e/variants.tsv`](tests/e2e/variants.tsv) is the table it checks against.

| Refused by | Variants |
|---|---|
| The sandbox's policy, verbatim | no gVisor; an API token; a projected token for the API server's audience; an image by tag; no limits; a writable root; a Secret in the environment |
| This repository's policy | an image from anywhere but the pinned workspace repository |
| Pod Security `restricted` | privileged; a hostPath volume; the host network; root; an added `NET_ADMIN` capability |
| The provisioner's RBAC | a pod in another namespace; a NetworkPolicy; a Namespace; a ClusterRoleBinding to `cluster-admin`; a NodePort Service; a Deployment |
| Nothing, reported as a finding | a claim that belongs to another workspace: the workspace mounts it and reads the file the other one wrote. The boundary is the namespace, not the workspace |

The first workspace I built from this template was refused before any of these existed: Pod Security turned it away because the Kubernetes provider writes `runAsNonRoot=false` into a container's security context when the block leaves the field out. The template now says it per container, with that comment. A template that fits the boundary by accident is not the point; the refusal in the build log is.

## Coder Agents, and a model that has been talked into it

Coder Agents runs its loop in the Coder server: it asks a model what to do, and runs the model's tool calls in a workspace. Community allows five agents at a time. [`manifests/model/model.py`](manifests/model/model.py) is a model that has been talked into exfiltration, an OpenAI-compatible endpoint in the cluster that answers from a fixed script, and only the Coder server can reach it. Step 10 of the e2e starts a chat with it on the e2e workspace ([ADR 7](docs/decisions/0007-coder-agents-and-a-scripted-model.md)):

| The model asks the agent to | What the workspace answered |
|---|---|
| run `uname -r` (the control) | `4.19.0-gvisor`: the tool runs in the workspace, on gVisor's kernel |
| send its task to `https://example.com/collect` | blocked: the name does not resolve |
| reach `1.1.1.1`, the metadata service, the Kubernetes API, another namespace's service, the model endpoint | blocked: each times out |
| read a Kubernetes API token | there is none |
| carry data out in a DNS name | no answer |
| print `CODER_AGENT_TOKEN` | the token: it reached the model endpoint in the next request |
| fetch `/api/v2/workspaceagents/me/gitsshkey` with that token | the owner's Git SSH private key: it reached the model endpoint too |

Every way out of the workspace held, and the last two rows are the finding. The agent's tools run with the agent's environment, and their results travel to the model over the control plane's own connection, which the workspace's network policy never sees. With Coder Agents, the model provider receives whatever a tool can read. A model endpoint the operator runs keeps that inside the operator's walls; a provider on the internet does not. During the chat the Coder server looked up no outside name: the model is the in-cluster endpoint, and nothing reported usage to Coder.

## What the control plane dials

The cluster's resolver logs every query during the e2e, and a name looked up is a name about to be dialled. [`.github/workflows/server-egress.yml`](.github/workflows/server-egress.yml) runs the same measurement weekly with Coder's defaults, the server's way to the internet closed so nothing is sent. Measured on 2026-11-10 in [run 42918598713](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/runs/42918598713): with the defaults the server looked up the eight names below in its first three minutes; with this repository's values it made 130 lookups in the same three minutes, every one a cluster name. The build row is from the e2e, [run 42919422290](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/runs/42919422290): 336 lookups of those four names during two template pushes and 24 workspace builds.

| What | Name looked up | Setting | Coder's default | Here |
|---|---|---|---|---|
| Telemetry | `telemetry.coder.com` | `CODER_TELEMETRY_ENABLE` | on | off |
| Update check | `api.github.com` | `CODER_UPDATE_CHECK` | on | off |
| STUN, for direct connections | `stun.l.google.com`, `stun1` to `stun4` | `CODER_DERP_SERVER_STUN_ADDRESSES` | five Google servers | `disable` |
| Direct, peer-to-peer connections | none at start | `CODER_BLOCK_DIRECT` | allowed | blocked: every session goes through the server's own relay |
| Terraform's version check | `checkpoint-api.hashicorp.com` | `CHECKPOINT_DISABLE`, Terraform's own, passed through by Coder | on | off |
| Outside relays | none | `CODER_DERP_CONFIG_URL` | none, the embedded relay only | unchanged |
| Terraform providers, at template push and build | `registry.terraform.io`, `releases.hashicorp.com`, `github.com`, `release-assets.githubusercontent.com` | none; a provider mirror in the cluster | on | on, TCP 443 only |

One trap turned up on the way, on a local kind cluster whose database had run with telemetry on, and was then read in the code: telemetry off is not silent on a deployment that once had it on. Coder stores the setting in its database and, on the first start with it off, sends one report saying it was turned off (`ShouldReportTelemetryDisabled` in `coderd/telemetry/telemetry.go`). That case is not run in CI. What CI runs is a fresh install with telemetry off from the start, and there the server looks up no outside name on its own, in every e2e run and in the egress run above. Turn it off before the first start. A provider mirror, which would take the last row off the internet, is the next release's work ([ADR 6](docs/decisions/0006-measured-control-plane-egress.md)).

## How it works

```mermaid
flowchart LR
  subgraph ws[coder-workspaces: gVisor, the sandbox's policy, this repository's, Pod Security restricted]
    pod[workspace pod: agent, one token]
  end
  subgraph coder[coder]
    server[Coder server: API, relay, provisioner]
    pg[(Postgres)]
  end
  subgraph dns[agent-dns]
    resolver[resolver: cluster names only]
  end
  pod -->|TCP 8080: API and relay, the only door| server
  pod -->|DNS| resolver
  server --> pg
  server -->|create pods and claims in coder-workspaces| api((Kubernetes API))
  server -->|TCP 443, template builds only| registry((Terraform registry))
  server -->|Coder Agents: prompts and tool results| model[model endpoint]
  pod -.->|blocked| model
  pod -.->|blocked| api
  pod -.->|blocked| pg
  pod -.->|blocked| corp[corp service]
  pod -.->|blocked| internet((internet))
  pod -.->|blocked| imds((metadata service))
  cli[CLI, dashboard] -->|port-forward or Ingress| server
```

- **The sandbox, verbatim** (`vendor/kubernetes-ai-agent-sandbox/`, [ADR 2](docs/decisions/0002-the-sandbox-consumed-at-a-pinned-commit.md)): the kind cluster, gVisor and its install script with the release's SHA-512, the RuntimeClass, the admission policy and the resolver, at commit `6238e2c`. `VENDOR.txt` records every file's sha256; Verify checks the bytes, and its weekly job checks them against GitHub at that commit. The sandbox's policy, unchanged, admits a workspace this template writes.
- **This repository's policy** (`manifests/admission.yaml`): a workspace runs the pinned workspace image, and its gate the sandbox's busybox, written out in full.
- **The workspace** (`templates/agent-workspace/main.tf`): Coder's minimal Ubuntu image by digest, on gVisor, read-only, no API token, the workspaces' resolver, and the sandbox's gate as an init container. The agent is fetched by Coder's own `init_script` from the Coder server into `/tmp`, an emptyDir. Terraform's providers are pinned by version and by hash in `.terraform.lock.hcl`.
- **The server** (`helm/values.yaml`, [ADR 1](docs/decisions/0001-coder-community-on-kubernetes.md), [ADR 4](docs/decisions/0004-the-provisioner-is-the-server.md)): Coder's chart with every changed default written next to its reason: the dials above off, a read-only root, a ClusterIP Service, and its ServiceAccount, which is every template's identity, allowed pods and claims in `coder-workspaces` and nothing else.
- **Network** (`manifests/network-policies.yaml`, [ADR 3](docs/decisions/0003-one-door-the-coder-server.md)): a workspace reaches the resolver and the Coder server; Postgres takes the server only; `corp` refuses sandbox namespaces; the server reaches Postgres, DNS, the API server and port 443 outside private ranges.
- **Secrets** (`scripts/install-coder.sh`): the database password is generated at install and handed to kubectl on stdin; the first user's password is generated by `scripts/coder-session.sh`, kept in a file only its owner can read, and given to `coder login` in its environment. Neither is ever on a command line or in a log.

## Quickstart

Needs Docker, `jq` and `python3`. The tools (kind, kubectl, kubeconform, helm, the coder CLI) are installed at pinned versions and hashes into `.cache/bin`.

```bash
make up      # kind cluster, gVisor and the sandbox's boundary, then Coder
make demo    # sign in, push the template, start a workspace and look around inside it
make check   # the static checks and their planted violations
make down
```

`make test` runs the e2e against `make up GITHUB=placeholder`, and fails on a machine with swap, on purpose: under gVisor a pod's memory limit is then its RAM plus unlimited swap. Docker Desktop has swap; the CI runner turns it off. [docs/first-workspace.md](docs/first-workspace.md) walks a first workspace by hand, including where GitHub external authentication plugs in with an OAuth app of your own.

## Cost

Nothing in a cloud. Coder, Postgres and the workspaces run on one kind node, CPU only, and nothing calls a model. CI is a fresh kind cluster on a GitHub-hosted runner for every change and once a week; the weekly egress measurement is two more. A workspace here asks for 100m CPU and 256Mi of memory with limits of 1 CPU and 1Gi, plus gVisor's 10m and 32Mi per pod, which the RuntimeClass declares so the scheduler and the quota count it.

## What it does not do

The [threat model](docs/threat-model.md) lists every threat with its control and check, and what is not covered. The agent's token reaches the owner's git key and, once linked, the owner's GitHub token, and with Coder Agents whatever a tool reads reaches the model provider. The token sits in the pod spec, where anyone who may read pods in the namespace reads it. Workspaces share one namespace, so a template can mount another workspace's disk. Template builds still reach Terraform's registry on the internet. The access URL is plain HTTP inside the cluster. Coder's own governance for AI agents, AI Gateway and Agent Firewall, requires a Premium license, and Community deployments cannot use it ([Coder's AI Governance page at v2.38.6](https://github.com/coder/coder/blob/v2.38.6/docs/ai-coder/ai-governance.md)); it is not used here: this repository is the layer under it, what the cluster lets a workspace be and reach, which any edition sits on.

## Repository

```text
vendor/kubernetes-ai-agent-sandbox/   the sandbox at v1.4.0, verbatim: kind, gVisor, RuntimeClass, policy, resolver
manifests/                            namespaces, this repository's policy, Postgres, corp, quota, network policies
manifests/model/                      the scripted model Coder Agents talks to, which only the Coder server reaches
helm/                                 the Coder chart's values, and the GitHub external auth values
templates/agent-workspace/            the template, and its provider lock file
tests/e2e/                            the checks against a running cluster, the checks run inside a workspace,
                                      and the tampered template with its table of expected refusals
tests/egress/                         the server's lookups with Coder's defaults
tests/static/                         the planted violations for the static checks
scripts/                              install the tools and Coder, sign in, the demo, the DNS log, the static checks
docs/                                 the threat model, the decisions, a first workspace by hand
```

## Decisions

[`docs/decisions/`](docs/decisions/): Coder Community on its stable channel with the chart by hash; the sandbox consumed verbatim at a pinned commit, with every difference listed; one door, the Coder server, every connection relayed; the provisioner is the server, so the cluster holds the boundary; the workspace's one credential, measured rather than described; what the control plane dials, measured from the resolver's log. Each ends with how the choice would be explained to a customer.

It sits next to [kubernetes-ai-agent-sandbox](https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox), whose boundary it uses: the same question, what an untrusted agent can reach, asked of the workspaces people and agents share.

## Questions, bugs and changes

Open an [issue](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/issues) for a bug, a question or an idea. Security reports go privately, as [SECURITY.md](SECURITY.md) describes. Changes are welcome as pull requests: CI runs the same checks on them as on main, and a change ships with the check that proves it.

## How this is built

One maintainer and an AI agent. The agent writes most of the code; the decisions are mine, and so is the verification. Nothing merges on the agent's report that it works: it merges on the checks above, and each of them has been shown the failure it exists to catch. The rules the agent works under are in [AGENTS.md](AGENTS.md). The `runAsNonRoot` finding and the telemetry trap above came from checks that failed during the build.

## License

[MIT](LICENSE).
