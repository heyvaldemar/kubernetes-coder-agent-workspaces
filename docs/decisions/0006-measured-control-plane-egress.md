# 6. What the control plane dials, measured from the resolver's log

- Status: accepted
- Date: 2026-11-10

## Context

A boundary around workspaces says nothing about the server that manages them. The Coder server can be told not to send telemetry or look for updates, but a flag is a claim until something shows the server stopped. Its Terraform also downloads providers whenever a template is built.

## Decision

- The cluster's resolver logs every query during the e2e (`scripts/dns-log.sh on`, CoreDNS's `log` plugin, turned on before Coder is installed). A name looked up is a name about to be dialled. `scripts/dns-log.sh names` lists the outside names the server's pods asked for in a time window, leaving out the cluster's names and the search-path expansions of a name.
- The e2e gates the reference configuration (step 9): from the server's start to the first template push, no outside name at all; during template pushes and builds, only Terraform's registry and the hosts it sends provider downloads to; none of the names Coder's defaults dial, ever.
- `.github/workflows/server-egress.yml` runs the same measurement weekly with Coder's defaults for every setting this repository turns off (`tests/egress/values-defaults.yaml`), and with the reference values, each on a fresh cluster. The defaults run starts the server with its way to the internet closed (`CODER_SERVER_INTERNET=closed`), so telemetry and the update check are seen asking and send nothing. It is what shows the measurement can see a name: a run that saw nothing would prove nothing.
- An offline template build, Terraform reading its providers from a mirror inside the cluster, was left for v1.1.0, and is in it (below).

## Consequences

- Measured on 2026-11-10 ([server-egress run 42918598713](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/runs/42918598713), e2e [run 42919422290](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/actions/runs/42919422290)), with the defaults: `telemetry.coder.com`, `api.github.com` (the update check), `stun.l.google.com` and `stun1` to `stun4`, and `checkpoint-api.hashicorp.com` (Terraform's own version check, which Coder runs at start). With `helm/values.yaml`: none of them, and no outside name at all in 130 lookups over three minutes. During template builds: `registry.terraform.io`, `releases.hashicorp.com`, `github.com` and `release-assets.githubusercontent.com`.
- Telemetry off is not silent on a deployment that once had it on: Coder records the setting in its database and, when it changes from on to off, sends one last report saying so (`ShouldReportTelemetryDisabled` in `coderd/telemetry/telemetry.go`). Seen on 2026-11-10 on a local kind cluster, its database reused from a run with the defaults, and then read in the code; not run in CI, where every install starts with telemetry off and step 9 shows the server looking up nothing on its own. Turn it off before the first start.
- DNS shows names, not connections. A dial to an address with no lookup would not appear; nothing in Coder's defaults does that, and the server's network policy refuses private and link-local addresses anyway.

## Revisited, 2026-11-11

The provider mirror is in. `scripts/provider-mirror.sh` runs `terraform providers mirror` in the pinned Terraform image on the machine that installs: it takes the versions in the templates' lock file and checks each package's signature against the registry while it downloads. `scripts/install-coder.sh` copies the mirror onto a volume through a loader pod that exists for the copy only, and writes a `terraform.rc` with a filesystem mirror and no direct installation; the server mounts the volume read-only and points `TF_CLI_CONFIG_FILE` at it. In the cluster, Terraform reports each provider "(unauthenticated)", since a filesystem mirror carries no signature, and checks every package against the lock file's hashes instead. A provider missing from the mirror is an error, never a download.

So the server's 443 rule could go (ADR 3), and step 9 now requires no outside name at all from the server's start to the end of the run, two pushes, 24 builds and a Coder Agents chat included. Measured first on a local kind cluster on 2026-11-11: a template push installed both providers from the mirror, and the server made 64 lookups, none outside the cluster.

## Alternatives

- **Capturing packets.** Exact, and needs a privileged container on the node and a parser; the names answer the question asked.
- **Closing the server's internet entirely now.** Template builds would fail without a provider mirror, which is the v1.1.0 work.

## How to explain this to a customer

We do not take the vendor's settings on trust: we record every name the Coder server looks up. With this configuration it contacts nothing on its own, and when a template is built it downloads its plug-ins from four named places. With the factory settings it also calls home, checks for updates and reaches Google's network servers, and that run is kept to show the recording works.
