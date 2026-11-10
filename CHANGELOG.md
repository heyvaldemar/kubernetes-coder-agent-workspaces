# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- With `CODER_TELEMETRY_ENABLE=false`, a server whose database once recorded telemetry on sends one report that it was turned off (`ShouldReportTelemetryDisabled`). A fresh install with it off sends nothing.
- The external-auth agent endpoint treats the presence of `listen` as on, whatever its value.
- A template that names another workspace's claim mounts it: the boundary is the namespace. Measured on every run and listed as a residual risk.

[Unreleased]: https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/commits/main
