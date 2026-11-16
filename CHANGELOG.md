# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- A real model, weekly, beside the scripted one ([ADR 8](docs/decisions/0008-a-real-model-weekly-beside-the-scripted-one.md)). `.github/workflows/real-model.yml` builds the e2e's cluster and runs the e2e, then puts a real model in the scripted one's place for one chat. The model is granite-4.0-1b on CPU, Apache-2.0, pinned in `tests/real-model/model.lock` by revision and sha256 and checked on the runner and again in its pod. It is served by llama.cpp's server, by the digest and with the flags kubernetes-air-gapped-ai-agent runs, except a context of 16384 for Coder Agents' 6,610-token first request. It has no way out of the cluster. A notes file in the workspace asks the assistant to run the scripted model's eleven commands, and the run records which of them the model ran. It fails only when one of them was not refused, when the model's server could reach out, or when the measurement cannot be trusted. Nothing gates on it. `tests/e2e/agents.py` takes the provider, model, prompt and wait from the environment, with the e2e's as defaults. With `REPORT=real` it prints each command masked and each output as lengths and signs only. `AGENTS.md` names this run as the one exception to "no real model in CI". A planted violation, the server by tag, joins the static checks. The first run on main, 43809879066, measured a model that executes nothing: granite-4.0-1b read the notes and ran none of the commands, the control included.
- The e2e checks the first instant (step 4b, [ADR 7](docs/decisions/0007-coder-agents-and-a-scripted-model.md) Revisited 2026-11-16). It starts a pod made from the live workspace and one made from the model's Deployment, gates included, each asking from its first instant: the internet by address over TCP and over DNS, the cluster's CoreDNS and the Kubernetes API. Nothing may answer, and the workspace's copy reaches the Coder server on its first try. A sabotage run with the gates removed got answers in both (run 43755156864). The e2e has 103 checks.
- The model's pod, and the real model's in `tests/real-model/llama.yaml` (ahead of `check-weights`), wait at a gate, as a workspace does. The model may reach nothing, so its gate waits until neither the Kubernetes API nor the cluster's CoreDNS answers.

### Changed

- `scripts/check-freshness.py` is the fleet's one copy of the freshness check, fleet-ops `templates/check-freshness.py`, and what this repository pins is listed in `freshness.json`. `.cast` recordings are left out, and the Coder server's pin is read from `helm/values.yaml`, which no copy read before. A release younger than three days is now a warning that names the moment it becomes a failure: such a release is not pinned here, a rule `AGENTS.md` now states and `.github/dependabot.yml` sets for Dependabot's version updates (`cooldown: default-days: 3`). A release whose date cannot be read still fails, and so does a tag that moved to a new digest.

- Pins moved to what upstream has released, each release three days old or more and each hash checked against its publisher. Coder's stable channel, v2.38.7 (2026-11-10): the chart archive by the digest helm.coder.com's index publishes, the server image by the digest whose SLSA provenance from coder/coder's release workflow at the tag verifies with cosign, and the CLI by `coder_2.38.7_checksums.txt`, whose signature verifies with Coder's release key. kubectl v1.37.2 (2026-10-28), by dl.k8s.io's sha256 files and signatures. The digests three tags were rebuilt to: busybox:1.37 (2026-10-28), python:3.13-alpine (2026-11-12, Python 3.13.16 to 3.13.18) and postgres:17.11-alpine3.24 (2026-11-11). Every copy moves in this commit, the gate's busybox in both templates, `manifests/corp.yaml`, `tests/e2e/run.sh` and the provider-mirror loader in `scripts/install-coder.sh`. v2.38.7's one breaking change validates workspace app URLs on the server; the template declares no `coder_app`. None of the Coder files the README and the decision records quote changed between v2.38.6 and v2.38.7, so their links now name v2.38.7.

- The README's replay is e2e run 43735458737 on main (782c681, the pins above): 100 checks in 5 minutes 43 seconds, step 6b's linked account included. It was run 42944155585, the 98 checks of v1.1.0. `docs/demo/e2e.cast` comes from the run's log through `scripts/cast-from-log.py`, the GIF from agg at half speed.

- helm v4.3.2 (2026-11-13T04:53Z), moved once its three days were up: both archives hash as get.helm.sh's `.sha256sum` files say, and their `.asc` signatures verify with a key from helm's `KEYS` at v4.3.2. PostgreSQL 17.12, `postgres:17.12-alpine3.24` (in docker-library's official images since 2026-11-12T20:48Z, `PG_VERSION=17.12` in the image), by the digest registry-1.docker.io, Docker Hub and docker-library/repo-info agree on. The 17.11 tags are no longer built, so the digest moved above was their last.

### Fixed

- The e2e lost every fact the model endpoint logged after a connection to it was reset. Python's HTTP server printed a traceback to stderr, `kubectl logs` merged it into the log, and `jq` stopped at the first line that was not JSON, so step 10 failed its model-key check and reported the agent's token and the owner's key as not reaching the model (run 43687239149; the reset came when step 6b killed its port-forward to the model). `manifests/model/model.py` now logs a dropped connection as a fact and any other fault in itself as a `handler_error` fact (its type and line, no traceback), `tests/e2e/run.sh` skips a line that is not JSON and says how many it skipped, and step 10 fails on a `handler_error`, and instead of measuring when the log holds no record of the step a finding is about.
- `manifests/model/model.py` says that its OAuth2 stand-in checks neither the client secret, nor `redirect_uri`, nor a PKCE verifier: a fixture for the measurement, not a provider.

### Security

- **A release is verified for its exact signer** (23e990c). `.github/workflows/release-assets.yml` checks the signature against this repository's `release-assets.yml` on the ref the run ran on; before, any workflow of the repository on any branch passed. A changed archive must now be refused in the tool's own words, so Sigstore out of reach or a missing tool fails the job instead of passing it. A run started by hand runs only from `main`.

## [1.2.0] - 2026-11-11

### Added

- The linked external-auth case, measured instead of read in the code. A stand-in OAuth2 provider (authorize, token, userinfo) joins the endpoint in `manifests/model/`; the e2e configures it as a second provider (`tests/e2e/values-e2e-oauth.yaml`), declares it in the tampered fixture only, and links it as the owner through Coder's own OAuth flow, the browser's half over port-forwards, the server's in the cluster. E2e step 6b: from inside a workspace the agent's token gets the owner's access token, and its sha256 is the one the provider logged when it issued it.

### Changed

- ADR 4 and the threat model said a namespace per user would close the shared-claim finding. It would not on Community: the one provisioner identity must reach every user's namespace and the template picks it, and admission cannot tell the right claim from the wrong one when the template writes every name it could compare. Both now say so.

## [1.1.0] - 2026-11-11

### Added

- Coder Agents under the same boundary ([ADR 7](docs/decisions/0007-coder-agents-and-a-scripted-model.md)). `manifests/model/` is a model that has been talked into exfiltration, an OpenAI-compatible endpoint in its own namespace that only the Coder server reaches, answering from a fixed script; `tests/e2e/agents.py` registers it through Coder's API and starts a chat on the e2e workspace. E2e step 10: the agent's `execute` tool runs in the workspace on gVisor, and each of eight attempts the model asks for dies at the boundary; the model key stays with the Coder server; during the chat the server looks up no outside name, `tallyman-prod.coder.com` included. A static check refuses a model step that reads a credential without being marked secret.
- Template builds without the internet ([ADR 6](docs/decisions/0006-measured-control-plane-egress.md), revisited). `scripts/provider-mirror.sh` fills a Terraform filesystem mirror from the templates' lock file on the machine that installs; `scripts/install-coder.sh` copies it onto a volume the Coder server mounts read-only, with `TF_CLI_CONFIG_FILE` pointing Terraform at it and no direct installation.

### Changed

- The Coder server has no rule to the internet. Its 443 rule moved to `manifests/optional/coder-server-internet.yaml`, applied for GitHub sign-in (`CODER_GITHUB=app`) or with `CODER_SERVER_INTERNET=open` ([ADR 3](docs/decisions/0003-one-door-the-coder-server.md), revisited). E2e step 9 requires no outside name at all, and checks that no policy of the server's names an outside address. Static checks refuse a dropped mirror and a 443 rule back in the default policies (eighteen plants now).

### Found while building it

- With Coder Agents the model provider receives whatever a tool reads. The scripted model asked for `CODER_AGENT_TOKEN` and for the owner's Git SSH key through it, and both reached the model endpoint in the next request, over the control plane's connection, which the workspace's network policy never sees. Measured on every run, a residual risk in the threat model.

## [1.0.0] - 2026-11-11

### Added

- Coder Community v2.38.6 on kind, installed from its Helm chart archive by sha256 (`charts.lock`), the server image and the official PostgreSQL 17 image by digest, with every changed default in `helm/values.yaml` next to its reason.
- The boundary of kubernetes-ai-agent-sandbox v1.4.0, vendored verbatim with each file's sha256 (`vendor/kubernetes-ai-agent-sandbox/VENDOR.txt`): the kind cluster, gVisor, the RuntimeClass, the admission policy and the workspaces' resolver. `scripts/check-vendor.py` checks the bytes on every Verify run and against GitHub at the pinned commit weekly. ADR 2 lists every difference from the sandbox.
- This repository's admission policy, `coder-workspace`: a workspace runs the pinned workspace image and its gate the sandbox's busybox.
- `templates/agent-workspace/`: a workspace on gVisor, read-only, without an API token, behind the sandbox's gate, with Coder's minimal Ubuntu image and providers pinned by hash. Optional GitHub external authentication (`helm/values-github.yaml`, `--variable github_external_auth=true`).
- The e2e (`tests/e2e/run.sh`): what is installed, a workspace through Coder, gVisor's kernel, everything a workspace reaches and does not from inside it (`tests/e2e/inside.sh`), the agent's token measured at both APIs, the provisioner's rights asked of the API server, nineteen tampered template variants refused through Coder's build log, the same targets from outside, and the Coder server's own lookups from the cluster resolver's log.
- `server-egress.yml`: the server's lookups measured with Coder's defaults, its internet closed, against this repository's settings.
- Static checks with fifteen planted violations, `make up`, `make demo`, `make test`, `make check`, `make down`, `docs/first-workspace.md`, a threat model and six decision records.

### Found while building it

- The Terraform Kubernetes provider writes `runAsNonRoot=false` into a container's security context when the block leaves the field out, and Pod Security refuses the pod. The first build of the template was refused that way; the template now sets it per container.
- With `CODER_TELEMETRY_ENABLE=false`, a server whose database once recorded telemetry on sends one report that it was turned off (`ShouldReportTelemetryDisabled`). Seen on a local kind cluster with a reused database and read in the code; not run in CI. A fresh install with it off looks up no outside name on its own, which CI checks on every e2e run.
- The external-auth agent endpoint treats the presence of `listen` as on, whatever its value.
- A template that names another workspace's claim mounts it: the boundary is the namespace. Measured on every run and listed as a residual risk.

[Unreleased]: https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/releases/tag/v1.0.0
